import Foundation
import SwiftData

// MARK: - 健康模块数据操作 + 注入摘要
// 无状态：UI 用 @Query 驱动，这里只放变更入口和纯函数（可测，预览/实发同源）。

enum WeightUnit: String, CaseIterable {
    case kg, lb

    static let storageKey = "health.unit.weight"

    static var current: WeightUnit {
        WeightUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .kg
    }

    var label: String { self == .kg ? "公斤" : "磅" }

    func fromKg(_ kg: Double) -> Double { self == .kg ? kg : kg * 2.20462 }
    func toKg(_ value: Double) -> Double { self == .kg ? value : value / 2.20462 }
}

/// 单个计划时刻的服药状态（漏服推导不落库）。
enum MedTimeState: Equatable {
    case taken(Date)   // 已打卡（实际时间）
    case pending       // 未到点，或到点未超缓冲
    case missed        // 过点超缓冲无打卡
}

// 无 actor 隔离：全部是「传入 context 的同步操作/纯函数」，CVM 组装路径（非隔离）也要调。
enum HealthLogStore {

    /// 漏服判定缓冲：计划时刻过后这么久没打卡算漏服。
    static let missedGrace: TimeInterval = 2 * 3600

    // MARK: - AI 可见闸（体重/吃药默认开，粟粟拍板；后置类默认关）

    static let weightGateKey = "health.inject.weight"
    static let medsGateKey = "health.inject.meds"
    static let cycleGateKey = "health.inject.cycle"
    static let intimacyGateKey = "health.inject.intimacy"
    static let intimacyShowKey = "health.show.intimacy"

    static var weightGateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: weightGateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: weightGateKey) }
    }

    static var medsGateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: medsGateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: medsGateKey) }
    }

    /// 月经闸**默认关**（脑爆拍板：敏感类默认关）。
    static var cycleGateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: cycleGateKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: cycleGateKey) }
    }

    /// 亲密闸**默认关**（同敏感类）。
    static var intimacyGateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: intimacyGateKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: intimacyGateKey) }
    }

    /// 面板亲密卡可见性**默认关**——关 = 卡整个不渲染，数据/协议照常。
    /// 与 AI 闸是独立两轴：可以卡隐身但 AI 可见，也可以卡显示但 AI 不可见。
    static var showIntimacyCard: Bool {
        get { UserDefaults.standard.object(forKey: intimacyShowKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: intimacyShowKey) }
    }

    // MARK: - 体重

    /// 同日重录 = 覆盖更新（手写 upsert：fetch→改→save，不靠 unique 约束）。
    static func upsertWeight(context: ModelContext, profileId: String, date: Date, weightKg: Double) {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<WeightEntry>(
            predicate: #Predicate { $0.profileId == profileId && $0.date == day }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.weightKg = weightKg
        } else {
            context.insert(WeightEntry(profileId: profileId, date: day, weightKg: weightKg))
        }
        try? context.save()
        LivelineReporter.report(.weight, "兔兔记了体重 · \(String(format: "%.1f", weightKg)) kg")
    }

    static func deleteWeight(context: ModelContext, entry: WeightEntry) {
        context.delete(entry)
        try? context.save()
    }

    // MARK: - 服药打卡

    /// 计划时刻的确定性 Date（当天 startOfDay + 分钟数）——打卡与状态推导共用同一构造。
    static func scheduledDate(minuteOfDay: Int, on day: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(minuteOfDay * 60))
    }

    static func logIntake(context: ModelContext, profileId: String, medication: Medication, minuteOfDay: Int, now: Date = Date()) {
        let scheduled = scheduledDate(minuteOfDay: minuteOfDay, on: now)
        context.insert(MedicationLog(profileId: profileId, medicationId: medication.id, scheduledAt: scheduled, takenAt: now))
        // 本地库存也扣一次（Gateway 侧由 take 接口扣）
        if medication.remaining > 0 {
            medication.remaining = max(0, medication.remaining - medication.perDose)
        }
        try? context.save()
        // 同步给 Gateway：Caelum 问「今天吃药了吗」能答上
        if let gid = medication.gatewayId {
            let dose = medication.perDose
            Task { await MedsClient.take(id: gid, amount: dose) }
        }
        LivelineReporter.report(.meds, "兔兔吃药了 · \(medication.name) \(medication.dosage)")
    }

    /// 撤销打卡 = 删对应计划时刻的当日 log。
    static func undoIntake(context: ModelContext, todayLogs: [MedicationLog], medication: Medication, minuteOfDay: Int, now: Date = Date()) {
        let scheduled = scheduledDate(minuteOfDay: minuteOfDay, on: now)
        for log in todayLogs where log.medicationId == medication.id && log.scheduledAt == scheduled {
            context.delete(log)
        }
        try? context.save()
    }

    // MARK: - 亲密（plan-health-intimacy：一天一条，日历/流水不露）

    /// note 传 nil = 不动已有备注；非 nil = 覆盖。
    static func upsertIntimacy(context: ModelContext, profileId: String, date: Date, note: String? = nil) {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<IntimacyEntry>(
            predicate: #Predicate { $0.profileId == profileId && $0.date == day }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            if let note { existing.note = note }
        } else {
            context.insert(IntimacyEntry(profileId: profileId, date: day, note: note ?? ""))
        }
        try? context.save()
        if let note { IntimacySyncService.push(date: day, note: note) }
    }

    /// 心形点按语义：今天有=取消，没有=记。返回操作后今天是否有记录。
    @discardableResult
    static func toggleIntimacyToday(context: ModelContext, profileId: String, now: Date = Date()) -> Bool {
        if let existing = fetchIntimacy(context: context, profileId: profileId, date: now) {
            context.delete(existing)
            try? context.save()
            IntimacySyncService.push(date: now, note: "", deleted: true)
            return false
        }
        upsertIntimacy(context: context, profileId: profileId, date: now)
        // 私密口径同注入：只报「发生了」，note 一个字不带
        LivelineReporter.report(.intimacy, "兔兔在亲密卡上点了今天。")
        return true
    }

    static func fetchIntimacy(context: ModelContext, profileId: String, date: Date) -> IntimacyEntry? {
        let day = Calendar.current.startOfDay(for: date)
        var descriptor = FetchDescriptor<IntimacyEntry>(
            predicate: #Predicate { $0.profileId == profileId && $0.date == day }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - 状态推导（纯函数）

    /// 一种药某计划时刻的当日状态。
    static func medState(medication: Medication, minuteOfDay: Int, todayLogs: [MedicationLog], now: Date, calendar: Calendar = .current) -> MedTimeState {
        let scheduled = scheduledDate(minuteOfDay: minuteOfDay, on: now, calendar: calendar)
        if let log = todayLogs.first(where: { $0.medicationId == medication.id && $0.scheduledAt == scheduled }) {
            return .taken(log.takenAt)
        }
        return now.timeIntervalSince(scheduled) > missedGrace ? .missed : .pending
    }

    // MARK: - 注入摘要（纯函数，预览/实发同源）

    /// 体重段。weights 按 date 降序传入。
    static func weightSummary(weights: [WeightEntry], now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let latest = weights.first else { return "" }
        let kgText = String(format: "%.1f", latest.weightKg)
        var line: String
        if calendar.isDate(latest.date, inSameDayAs: now) {
            line = "今天体重 \(kgText) 公斤"
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M 月 d 日"
            line = "最近一次体重 \(kgText) 公斤（\(f.string(from: latest.date))）"
        }
        // 30 天变化：窗口内最老的一条 vs 最新，仅一条不报
        if let windowStart = calendar.date(byAdding: .day, value: -30, to: now) {
            let inWindow = weights.filter { $0.date >= calendar.startOfDay(for: windowStart) }
            if let oldest = inWindow.last, oldest.id != latest.id {
                let delta = latest.weightKg - oldest.weightKg
                if abs(delta) >= 0.05 {
                    line += String(format: "（30 天 %+.1f）", delta)
                }
            }
        }
        return line + "。"
    }

    /// 吃药段。meds 只传未归档的。
    static func medsSummary(meds: [Medication], todayLogs: [MedicationLog], now: Date = Date(), calendar: Calendar = .current) -> String {
        let active = meds.filter { !$0.isArchived && !$0.timesOfDay.isEmpty }
        guard !active.isEmpty else { return "" }
        var parts: [String] = []
        for med in active {
            for minute in med.timesOfDay.sorted() {
                let timeText = Self.timeText(minute)
                switch medState(medication: med, minuteOfDay: minute, todayLogs: todayLogs, now: now, calendar: calendar) {
                case .taken(let at):
                    let f = DateFormatter()
                    f.dateFormat = "H:mm"
                    parts.append("\(med.name) \(f.string(from: at)) 已服")
                case .pending:
                    let scheduled = scheduledDate(minuteOfDay: minute, on: now, calendar: calendar)
                    parts.append(now >= scheduled
                        ? "\(med.name) \(timeText) 该吃了还没打卡"
                        : "\(med.name) \(timeText) 未到点")
                case .missed:
                    parts.append("\(med.name) \(timeText) 那次还没打卡")
                }
            }
        }
        return "今天的药：" + parts.joined(separator: "；") + "。"
    }

    static func timeText(_ minuteOfDay: Int) -> String {
        String(format: "%d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// `{{health}}` 的完整展开：苹果健康段（闸不动）+ 体重段 + 吃药段。全空 = ""（插槽自动跳过）。
    static func composedHealthSummary(context: ModelContext, profileId: String, now: Date = Date()) -> String {
        var parts: [String] = []
        let hk: String? = nil  // TODO: 接入 HealthKitService
        if let hk, !hk.isEmpty { parts.append(hk) }

        if weightGateEnabled {
            let seg = weightSummary(weights: fetchRecentWeights(context: context, profileId: profileId), now: now)
            if !seg.isEmpty { parts.append(seg) }
        }
        if medsGateEnabled {
            let seg = medsSummary(
                meds: fetchActiveMeds(context: context, profileId: profileId),
                todayLogs: fetchTodayLogs(context: context, profileId: profileId, now: now),
                now: now
            )
            if !seg.isEmpty { parts.append(seg) }
        }
        if cycleGateEnabled {
            let periods = HealthCycleStore.periods(days: HealthCycleStore.fetchDays(context: context, profileId: profileId))
            let todayFlow = HealthCycleStore.fetchDay(context: context, profileId: profileId, date: now)
                .flatMap { CycleFlow(rawValue: $0.flow) }
            let seg = HealthCycleStore.injectionLine(todayFlow: todayFlow, periods: periods, now: now)
            if !seg.isEmpty { parts.append(seg) }
        }
        // 亲密口径：只报当天，不带历史/频率/距离。
        // note 原为「一字不注」，兔兔 2026-08-02 拍板改为带上——备注她和 Caelum 共用一个框，她要他看得到。
        if intimacyGateEnabled, let e = fetchIntimacy(context: context, profileId: profileId, date: now) {
            let n = e.note.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(n.isEmpty ? "今天有亲密记录。" : "今天有亲密记录，备注：\(n)")
        }
        return parts.joined(separator: "")
    }

    /// 聊天内帮记 hint（教 AI 输出 ```health-log 块，plan-health-chat-entry 协议）。
    /// 全闸关/无可教内容 = ""，一字不注。{{user}} 由 PromptAssembler 宏替换展开。
    static func chatEntryHint(context: ModelContext, profileId: String) -> String {
        let weightOn = weightGateEnabled
            && !fetchRecentWeights(context: context, profileId: profileId, limit: 1).isEmpty
        let meds = medsGateEnabled ? fetchActiveMeds(context: context, profileId: profileId) : []
        // cycle/intimacy 只看闸不看域：敏感闸手动开 = 明确要用，教 AI 记第一笔有价值
        let cycleOn = cycleGateEnabled
        let intimacyOn = intimacyGateEnabled
        guard weightOn || !meds.isEmpty || cycleOn || intimacyOn else { return "" }

        let example = weightOn
            ? "{\"type\": \"weight\", \"kg\": 52.3}"
            : (!meds.isEmpty
                ? "{\"type\": \"med\", \"name\": \"药名\", \"time\": \"8:00\"}"
                : (cycleOn
                    ? "{\"type\": \"cycle\", \"flow\": \"medium\"}"
                    : "{\"type\": \"intimacy\"}"))
        var lines = """
        \n{{user}} 在用健康手账。她口头告诉你健康记录时（"我吃药了""今天 52.3"），在回复中输出代码块帮她记下，一块一条 JSON，可多块：
        ```health-log
        \(example)
        ```
        """
        if weightOn, !meds.isEmpty {
            lines += "\n吃药打卡用 {\"type\": \"med\", \"name\": \"药名\", \"time\": \"8:00\"}（time 可省略=就近计划时刻）。"
        }
        if !meds.isEmpty {
            let list = meds.map { med in
                "\(med.name)（\(med.timesOfDay.sorted().map(HealthLogStore.timeText).joined(separator: "/"))）"
            }.joined(separator: "、")
            lines += "\n当前的药：\(list)。"
        }
        if cycleOn {
            lines += "\n月经打点用 {\"type\": \"cycle\", \"flow\": \"medium\"}（flow: spotting/light/medium/heavy，date 可补记）。"
        }
        if intimacyOn {
            lines += "\n亲密记录用 {\"type\": \"intimacy\"}（date/note 可选）。"
        }
        lines += "\n系统会真实落库并把块变成结果行。"
        return lines
    }

    // MARK: - Fetch helpers（全带 profileId predicate，量级：条目个位数~几十）

    static func fetchRecentWeights(context: ModelContext, profileId: String, limit: Int = 60) -> [WeightEntry] {
        var descriptor = FetchDescriptor<WeightEntry>(
            predicate: #Predicate { $0.profileId == profileId },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    static func fetchActiveMeds(context: ModelContext, profileId: String) -> [Medication] {
        let descriptor = FetchDescriptor<Medication>(
            predicate: #Predicate { $0.profileId == profileId && !$0.isArchived },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func fetchTodayLogs(context: ModelContext, profileId: String, now: Date = Date()) -> [MedicationLog] {
        let dayStart = Calendar.current.startOfDay(for: now)
        let descriptor = FetchDescriptor<MedicationLog>(
            predicate: #Predicate { $0.profileId == profileId && $0.takenAt >= dayStart }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
