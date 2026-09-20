import Foundation
import SwiftData

/// 健康数据双向同步：本地 SwiftData ↔ Gateway 药品柜（/api/meds）
///
/// 两边不是重复而是互补：
/// - 本地 SwiftData 管「服药计划」（几点吃、提醒、依从率统计）
/// - Gateway 药品柜管「库存」（还剩几片、补货），也是 Caelum meds_* 工具的入口
///
/// 同步策略：
/// - 上行：本地新建的药（gatewayId == nil）推给 Gateway，拿回 id 绑定
/// - 下行：拉 Gateway 列表，按 gatewayId 匹配更新库存；Caelum 新加的药落地成本地 Medication
/// - 打卡：本地打卡时推 Gateway；Gateway 的 intake 拉回本地补 MedicationLog（60s 去重）
/// - 冲突：库存以 Gateway 为准（Caelum 管补货），时刻计划以本地为准（用户设的）
enum HealthSyncService {

    private static let lastSyncKey = "healthSync.lastRun"
    private static let throttleSeconds: TimeInterval = 60

    /// 全量同步：先推本地未绑定的，再拉远端合并。
    @MainActor
    static func sync(context: ModelContext, profileId: String, force: Bool = false) async {
        guard !profileId.isEmpty else { return }
        if !force {
            let last = UserDefaults.standard.double(forKey: lastSyncKey)
            guard Date().timeIntervalSince1970 - last > throttleSeconds else { return }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncKey)

        await pushLocal(context: context, profileId: profileId)
        await pullRemote(context: context, profileId: profileId)
    }

    // MARK: - 上行

    /// 本地新建（gatewayId == nil）的药推给 Gateway，拿 id 回绑。
    @MainActor
    private static func pushLocal(context: ModelContext, profileId: String) async {
        let pid = profileId
        let desc = FetchDescriptor<Medication>(
            predicate: #Predicate<Medication> { $0.profileId == pid && !$0.isArchived }
        )
        let locals = (try? context.fetch(desc)) ?? []

        // 新药：建到 Gateway
        for med in locals where med.gatewayId == nil {
            if let remoteId = await MedsClient.addReturningId(
                name: med.name,
                count: med.remaining,
                unit: med.unit,
                perDose: med.perDose,
                note: med.note
            ) {
                med.gatewayId = remoteId
                med.lastSyncedAt = Date()
                med.localEditedAt = nil
            }
        }

        // 本地改过数量的：推上去覆盖服务器（原来只推新药，她改的数量根本不推，
        // 下一轮 pullRemote 又把旧值冲回来——这就是「改完过一会儿又变回去」）
        for med in locals where med.gatewayId != nil {
            guard let edited = med.localEditedAt,
                  edited > (med.lastSyncedAt ?? .distantPast) else { continue }
            if await MedsClient.setRemaining(id: med.gatewayId!, count: med.remaining) {
                med.lastSyncedAt = Date()
                med.localEditedAt = nil
            }
        }

        // 归档的：从 Gateway 删掉，否则 pullRemote 会把它当「Caelum 新加的药」又拉回来
        let archivedDesc = FetchDescriptor<Medication>(
            predicate: #Predicate<Medication> { $0.profileId == pid && $0.isArchived }
        )
        for med in ((try? context.fetch(archivedDesc)) ?? []) where med.gatewayId != nil {
            if await MedsClient.remove(id: med.gatewayId!) {
                med.gatewayId = nil
                med.lastSyncedAt = Date()
            }
        }
        context.saveOrReport("药物同步", notifyUser: false)
    }

    // MARK: - 下行

    /// 拉 Gateway 药品柜合并进本地：更新库存 / 认领同名 / 落地 Caelum 新加的药 / 补打卡。
    @MainActor
    private static func pullRemote(context: ModelContext, profileId: String) async {
        guard let snap = await MedsClient.fetch() else { return }
        let pid = profileId
        let desc = FetchDescriptor<Medication>(predicate: #Predicate<Medication> { $0.profileId == pid })
        var locals = (try? context.fetch(desc)) ?? []

        for remote in snap.meds {
            if let local = locals.first(where: { $0.gatewayId == remote.id }) {
                // 已绑定：库存以 Gateway 为准（Caelum 可能 restock 过），
                // 但本地有未推送的手动改动时以本地为准——否则她刚改的数字会被冲掉
                if let edited = local.localEditedAt, edited > (local.lastSyncedAt ?? .distantPast) {
                    continue
                }
                local.remaining = remote.remaining
                local.unit = remote.unit
                local.perDose = remote.perDose
                local.lastSyncedAt = Date()
            } else if let byName = locals.first(where: { $0.name == remote.name && $0.gatewayId == nil }) {
                // 同名未绑定：认领
                byName.gatewayId = remote.id
                byName.remaining = remote.remaining
                byName.unit = remote.unit
                byName.perDose = remote.perDose
                byName.lastSyncedAt = Date()
            } else {
                // Caelum 新加的药 → 落地成本地 Medication（无时刻计划，用户可后补）
                let m = Medication(
                    profileId: profileId,
                    name: remote.name,
                    dosage: "\(MedsClient.numText(remote.perDose))\(remote.unit)",
                    timesOfDay: []
                )
                m.remaining = remote.remaining
                m.unit = remote.unit
                m.perDose = remote.perDose
                m.gatewayId = remote.id
                m.lastSyncedAt = Date()
                m.note = remote.note ?? ""
                context.insert(m)
                locals.append(m)
            }
        }

        // 今日打卡回灌：Gateway intake → 本地 MedicationLog（同药 60s 内视为同一条）
        let logDesc = FetchDescriptor<MedicationLog>(predicate: #Predicate<MedicationLog> { $0.profileId == pid })
        let existingLogs = (try? context.fetch(logDesc)) ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for intake in snap.today {
            guard let local = locals.first(where: { $0.gatewayId == intake.medId }) else { continue }
            let ts = iso.date(from: intake.ts) ?? ISO8601DateFormatter().date(from: intake.ts) ?? Date()
            let dup = existingLogs.contains {
                $0.medicationId == local.id && abs($0.takenAt.timeIntervalSince(ts)) < 60
            }
            guard !dup else { continue }
            let log = MedicationLog(
                profileId: profileId,
                medicationId: local.id,
                scheduledAt: nearestSlot(for: local, at: ts),
                takenAt: ts
            )
            context.insert(log)
        }

        context.saveOrReport("药物同步", notifyUser: false)
    }

    // MARK: - 工具

    /// 把 Gateway 的打卡时间对齐到最近的计划时刻（±90 分钟内），否则记为计划外补服。
    private static func nearestSlot(for med: Medication, at ts: Date) -> Date? {
        guard !med.timesOfDay.isEmpty else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: ts)
        let minute = (cal.component(.hour, from: ts)) * 60 + cal.component(.minute, from: ts)
        guard let closest = med.timesOfDay.min(by: { abs($0 - minute) < abs($1 - minute) }),
              abs(closest - minute) <= 90 else { return nil }
        return cal.date(byAdding: .minute, value: closest, to: day)
    }
}
