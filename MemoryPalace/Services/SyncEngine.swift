import Foundation
import SwiftData

/// S2.5 准实时同步引擎（plan-cross-device-sync）。
/// - 导出泵：前台每 5s 跑一次指纹增量导出（无变化 = 轻量 fetch + 比较，近零成本；连续空转自动降频）
/// - 云端监听：NSMetadataQuery（iOS）+ DispatchSource 目录监听（Mac）双通道，对端文档一到货 debounce 自动导入
/// 上限被 iCloud 传输卡死（秒~几十秒），手动「立即同步」仍保留为强制档。
@MainActor
final class SyncEngine: NSObject {
    static let shared = SyncEngine()

    private var container: ModelContainer?
    private var profileId: String?
    private var exportTimer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private var importDebounce: Timer?
    private var busy = false
    private var idleCount = 0
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var dirSuspended = false

    /// 幂等：楼层切换/开关重开直接重 start
    func start(profileId: String, container: ModelContainer) {
        stop()
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard SyncStore.isEnabled(profileId: profileId) else { return }
        self.profileId = profileId
        self.container = container

        // ⚠️ 必须先预热容器：iOS 重启后 ubiquity URL 缓存是 nil，不预热 = 同步根为 nil，
        // 泵全程对空气抽（手机实测：听得见云事件、永远导不进）。Mac 预热是 no-op 秒回。
        FileLibraryStore.primeICloudContainer { [weak self] available in
            guard let self, self.profileId == profileId else { return }
            guard available else {
                SyncProbe.log("engine ABORT floor=\(profileId.prefix(12)) — iCloud 容器不可用")
                return
            }
            SyncProbe.log("engine START floor=\(profileId.prefix(12))")

            // 全量泵：导出推本地变化 + 导入拉云端变化（mtime 增量，闲时近零成本）。
            // Mac 没挂 iCloud entitlement，NSMetadataQuery 听不到——接收方向全靠这条轮询。
            self.exportTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pump(exportOnly: false) }
            }

            self.startMetadataQuery()
            // 启动先全量对一次（拉对端积压 + 推本地积压）
            self.pump(exportOnly: false)
        }
    }

    func stop() {
        exportTimer?.invalidate()
        exportTimer = nil
        importDebounce?.invalidate()
        importDebounce = nil
        if let query = metadataQuery {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        metadataQuery = nil
        if let ds = dirSource {
            if dirSuspended { ds.resume() }
            ds.cancel()
        }
        dirSource = nil
        dirSuspended = false
        profileId = nil
        container = nil
        idleCount = 0
    }

    // MARK: - 云端监听（iOS 主力）

    private func startMetadataQuery() {
        guard let profileId else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE '*.json' AND %K CONTAINS %@",
            NSMetadataItemFSNameKey, NSMetadataItemPathKey, "/sync/\(profileId)/"
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: .NSMetadataQueryDidUpdate, object: query
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        metadataQuery = query
        query.start()
    }

    @objc private func cloudChanged(_ note: Notification) {
        SyncProbe.log("cloud EVENT \(note.name == .NSMetadataQueryDidFinishGathering ? "gathered" : "update")")
        scheduleImport()
    }

    // MARK: - 目录监听（Mac 主力 — kqueue 不需要 iCloud entitlement）

    private func startDirectoryMonitor() {
    }

    // MARK: - Debounce 共用入口

    private func scheduleImport() {
        // 自己导出也会写目录触发 fs EVENT，跳过 busy 期间的事件避免回声循环
        guard !busy else { return }
        importDebounce?.invalidate()
        importDebounce = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pump(exportOnly: false, eventDriven: true) }
        }
    }

    // MARK: - 泵

    private func pump(exportOnly: Bool, eventDriven: Bool = false) {
        guard !busy, let profileId, let container else { return }
        guard SyncStore.isEnabled(profileId: profileId) else { stop(); return }
        // 空转降频：连续 6 轮无实质变化 → Timer 驱动的导入跳过。
        // 导出永远跑（本地发消息不触发任何 EVENT，全靠 Timer 捕获）。
        // EVENT 驱动（FS/cloud 事件）始终放行——有新文件到了值得查。
        let skipImport = !eventDriven && idleCount >= 6
        busy = true
        let pid = profileId
        // 导出写文件会触发 DispatchSource → 回声循环，泵期间挂起监听
        dirSource?.suspend()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let context = ModelContext(container)
            var imported = SyncStore.ImportResult()
            if !skipImport {
                imported = SyncStore.importAll(profileId: pid, context: context)
            }
            let exported = SyncStore.exportChanged(profileId: pid, context: context)
            let hadWork = exported.exported > 0
                || imported.nodesInserted > 0
                || imported.conversationsCreated > 0
                || imported.conversationsUpdated > 0
            Task { @MainActor in
                guard let self else { return }
                self.dirSource?.resume()
                self.busy = false
                if hadWork {
                    self.idleCount = 0
                    NotificationCenter.default.post(name: .syncDidImport, object: nil)
                } else {
                    self.idleCount += 1
                }
            }
        }
    }
}

extension Notification.Name {
    static let syncDidImport = Notification.Name("syncDidImport")
}
