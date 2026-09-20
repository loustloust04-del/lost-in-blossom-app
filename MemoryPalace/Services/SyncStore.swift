import Foundation
import SwiftData

/// 跨设备同步 · 文件态同步层（research-cross-device-sync 方案 C）。
/// 对话导出成 JSON 文档放 iCloud 容器，对端增量导入合并。数据库零动刀：
/// 合并只插缺失节点、childrenIds 取并集、元数据 LWW——同步层故障最多是"没同步"，弄不脏本机库。
enum SyncStore {

    static let schemaVersion = 1
    static let enabledProfilesKey = "syncEnabledProfiles"

    // MARK: - 开关（单楼层试点：按楼层启用）

    static func isEnabled(profileId: String) -> Bool {
        guard !LocalMode.isOn else { return false }
        return enabledProfiles().contains(profileId)
    }

    static func setEnabled(_ enabled: Bool, profileId: String) {
        var set = enabledProfiles()
        if enabled { set.insert(profileId) } else { set.remove(profileId) }
        UserDefaults.standard.set(Array(set), forKey: enabledProfilesKey)
    }

    private static func enabledProfiles() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledProfilesKey) ?? [])
    }

    // MARK: - 同步根（测试可注入）

    /// 测试注入用；nil = 用 iCloud 容器
    static var overrideRoot: URL?

    static func syncRoot(profileId: String) -> URL? {
        let base: URL?
        if let overrideRoot {
            base = overrideRoot
        } else {
            base = FileLibraryStore.iCloudDocumentsRoot()?.appendingPathComponent("sync", isDirectory: true)
        }
        guard let base else { return nil }
        let dir = base.appendingPathComponent(profileId, isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 墓碑目录 sync/{pid}/tombstones（与 conversations 同级）
    static func tombstoneRoot(profileId: String) -> URL? {
        guard let conv = syncRoot(profileId: profileId) else { return nil }
        let dir = conv.deletingLastPathComponent().appendingPathComponent("tombstones", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 楼层身份（跨设备接入：同步按 profileId 走，对端必须先拥有同 id 楼层）

    struct FloorInfo: Codable {
        var profileId: String
        var name: String
        var emoji: String
        var updatedAt: Date
    }

    /// 把本楼层名片写到 sync/{pid}/floor.json（开关打开与每次同步时刷新）
    static func publishFloorInfo(profileId: String, name: String, emoji: String) {
        guard let root = syncRoot(profileId: profileId) else { return }
        let info = FloorInfo(profileId: profileId, name: name, emoji: emoji, updatedAt: Date())
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: root.deletingLastPathComponent().appendingPathComponent("floor.json"), options: .atomic)
    }

    /// 扫描 sync/ 下所有楼层名片（调用方自行过滤掉本机已有的）
    static func discoverRemoteFloors() -> [FloorInfo] {
        let base: URL?
        if let overrideRoot {
            base = overrideRoot
        } else {
            base = FileLibraryStore.iCloudDocumentsRoot()?.appendingPathComponent("sync", isDirectory: true)
        }
        guard let base,
              let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [FloorInfo] = []
        for dir in dirs {
            let infoURL = dir.appendingPathComponent("floor.json")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? decoder.decode(FloorInfo.self, from: data) else { continue }
            out.append(info)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 文档模型

    struct ConversationDocument: Codable {
        var schemaVersion: Int
        var conversationId: String
        var profileId: String
        var title: String
        var createTime: Date
        var updateTime: Date
        var currentNodeId: String
        var provider: String
        var isFavorite: Bool
        var folderId: String?
        var pinnedAt: Date?
        var memoryEnabled: Bool
        var selectedModelId: String
        var nodes: [NodeDocument]
        // S4 软删除状态（optional：今早之前的老文档无此 key，decode 为 nil，读取处 ?? false）
        var isDeleted: Bool?
        var deletedAt: Date?
    }

    /// 永久删除墓碑：对话彻底删时写一份，对端扫到无条件永久删本地副本（永久删赢）。
    /// 90 天缓冲后清理——保证慢同步设备也能收到，又不无限堆积。
    struct TombstoneDocument: Codable {
        var schemaVersion: Int
        var conversationId: String
        var profileId: String
        var deletedAt: Date
    }

    struct NodeDocument: Codable {
        var id: String
        var role: String
        var content: String
        var contentType: String
        var createTime: Date?
        var parentId: String?
        var childrenIds: [String]
        var isFavorite: Bool
        var isPinned: Bool
        var pinnedAt: Date?
        var segmentsData: Data?
        var ccMessageId: String?
        var replyToId: String?
        var ccEdited: Bool
        var ccThinking: String?
        var imageDescsData: Data?
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        // .secondsSince1970（Double）保亚秒精度：ISO8601 截整秒会让指纹回读变"旧"→ 永远重复导出
        //（测试 testExportFingerprintSkipsUnchanged 抓出），LWW 比较同理
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    // MARK: - 导出（指纹增量）

    struct ExportResult {
        var scanned = 0
        var exported = 0
    }

    /// ⚠️ 指纹表是**设备私有**的，必须放本机（App Support）——
    /// 曾放进共享 sync 目录，两台设备经 iCloud 互相覆盖对方账本：A 导出的指纹把 B 的导入
    /// 记录涂掉，B 永远"已读过"新文档（双机实测抓出的事故）。
    private static func localStateDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace/sync-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stateURL(profileId: String) -> URL? {
        localStateDir().appendingPathComponent("\(profileId).export.json")
    }

    private static func importStateURL(profileId: String) -> URL? {
        localStateDir().appendingPathComponent("\(profileId).import.json")
    }

    /// 一次性卫生：把误放进共享目录的旧账本清掉（不再让它们继续同步乱飞）
    private static func cleanupLegacySharedState(profileId: String) {
        guard let dir = syncRoot(profileId: profileId)?.deletingLastPathComponent() else { return }
        for name in [".export-state.json", ".import-state.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 已导入文档的 mtime 表（文件名 → 修改时间）：15s 轮询时跳过没变的文档，避免反复全量解码
    private static func loadImportState(profileId: String) -> [String: Date] {
        guard let url = importStateURL(profileId: profileId),
              let data = try? Data(contentsOf: url),
              let state = try? decoder.decode([String: Date].self, from: data) else { return [:] }
        return state
    }

    private static func saveImportState(_ state: [String: Date], profileId: String) {
        guard let url = importStateURL(profileId: profileId),
              let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 本机导出指纹（convId → 已导出 updateTime）。设备本机文件，不参与同步语义。
    private static func loadExportState(profileId: String) -> [String: Date] {
        guard let url = stateURL(profileId: profileId),
              let data = try? Data(contentsOf: url),
              let state = try? decoder.decode([String: Date].self, from: data) else { return [:] }
        return state
    }

    private static func saveExportState(_ state: [String: Date], profileId: String) {
        guard let url = stateURL(profileId: profileId),
              let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 导出该楼层有变化的对话（updateTime > 已导出指纹）。
    /// S4：含软删对话（带 isTrashed=true）——回收站状态也要传播，对端跟着进回收站。
    /// ⚠️ 必须在后台 context 上跑：大楼层初次全量导出会卡死主线程（Mac 实测事故）。
    static func exportChanged(profileId: String, context: ModelContext, progress: ((String) -> Void)? = nil) -> ExportResult {
        var result = ExportResult()
        guard let root = syncRoot(profileId: profileId) else { return result }
        var state = loadExportState(profileId: profileId)

        let pid = profileId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid }
        )
        let conversations = (try? context.fetch(descriptor)) ?? []

        for conversation in conversations {
            result.scanned += 1
            if result.scanned % 50 == 0 { progress?("导出中 \(result.scanned)/\(conversations.count)…") }
            if let exported = state[conversation.id], exported >= conversation.updateTime { continue }

            let convId = conversation.id
            let nodeDescriptor = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
            )
            let nodes = (try? context.fetch(nodeDescriptor)) ?? []

            let document = ConversationDocument(
                schemaVersion: schemaVersion,
                conversationId: conversation.id,
                profileId: profileId,
                title: conversation.title,
                createTime: conversation.createTime,
                updateTime: conversation.updateTime,
                currentNodeId: conversation.currentNodeId,
                provider: conversation.provider,
                isFavorite: conversation.isFavorite,
                folderId: conversation.folderId,
                pinnedAt: conversation.pinnedAt,
                memoryEnabled: conversation.memoryEnabled,
                selectedModelId: conversation.selectedModelId,
                nodes: nodes.map { node in
                    NodeDocument(
                        id: node.id, role: node.role, content: node.content, contentType: node.contentType,
                        createTime: node.createTime, parentId: node.parentId, childrenIds: node.childrenIds,
                        isFavorite: node.isFavorite, isPinned: node.isPinned, pinnedAt: node.pinnedAt,
                        segmentsData: node.segmentsData, ccMessageId: node.ccMessageId,
                        replyToId: node.replyToId, ccEdited: node.ccEdited, ccThinking: node.ccThinking,
                        imageDescsData: node.imageDescsData
                    )
                },
                isDeleted: conversation.isTrashed,
                deletedAt: conversation.deletedAt
            )

            guard let data = try? encoder.encode(document) else { continue }
            let fileURL = root.appendingPathComponent("\(conversation.id).json")
            // 内容级去重：编码 nodes 数组单独比较——updateTime/lastOpenedAt 这类
            // 浏览态字段不放进 nodes 不参与比较。注意必须包含 content（流式回复时
            // nodes.count 不变但 content 逐 token 更新——只比 count 会漏掉中间帧）。
            if let existingData = try? Data(contentsOf: fileURL),
               let existingDoc = try? decoder.decode(ConversationDocument.self, from: existingData),
               existingDoc.title == document.title,
               existingDoc.currentNodeId == document.currentNodeId,
               (existingDoc.isDeleted ?? false) == (document.isDeleted ?? false),
               existingDoc.nodes.count == document.nodes.count,
               let existingNodes = try? encoder.encode(existingDoc.nodes),
               let newNodes = try? encoder.encode(document.nodes),
               existingNodes == newNodes {
                state[conversation.id] = conversation.updateTime
                continue
            }
            do {
                try data.write(to: fileURL, options: .atomic)
                state[conversation.id] = conversation.updateTime
                result.exported += 1
                SyncProbe.log("EXPORT conv=\(conversation.id.prefix(8)) nodes=\(nodes.count) bytes=\(data.count)")
            } catch {
                #if DEBUG
                print("[SyncStore] export failed \(conversation.id): \(error)")
                #endif
            }
        }

        saveExportState(state, profileId: profileId)
        return result
    }

    // MARK: - 导入合并

    struct ImportResult {
        var documentsScanned = 0
        var conversationsCreated = 0
        var conversationsUpdated = 0
        var nodesInserted = 0
        /// 还在 iCloud 下载路上的文档数（>0 = 这轮没拉全，稍后再同步）
        var documentsDownloading = 0
    }

    /// iOS 不自动下载 iCloud 文档（Mac 会）：未下载的占位项触发下载并短暂等待。
    /// 返回（就绪的 json 文件，仍在下载的数量）。
    /// ⚠️ Mac 用裸路径 ~/Library/Mobile Documents/，文件永远在本地，跳过 startDownloadingUbiquitousItem——
    /// 否则 iCloud daemon 反复"重新下载"已有文件改 mtime，引发死循环（探针实测抓出）。
    private static func materializeDocuments(in root: URL) -> (ready: [URL], downloading: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return ([], 0) }

        #if os(iOS)
        var pending: [URL] = []
        for item in items {
            if item.lastPathComponent.hasSuffix(".icloud") || isNotDownloaded(item) {
                try? fm.startDownloadingUbiquitousItem(at: item)
                pending.append(item)
            }
        }
        if !pending.isEmpty { SyncProbe.log("DOWNLOAD triggered n=\(pending.count)") }

        var waited = 0
        while !pending.isEmpty, waited < 12 {
            Thread.sleep(forTimeInterval: 0.5)
            waited += 1
            pending = pending.filter { isNotDownloaded($0) || $0.lastPathComponent.hasSuffix(".icloud") && fm.fileExists(atPath: $0.path) }
        }
        #endif

        let ready = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let stillDownloading = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".icloud") }
            .count
        return (ready, stillDownloading)
    }

    private static func isNotDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// 墓碑缓冲期（秒）：90 天后清理墓碑文件，慢同步设备此前必能收到。
    private static let tombstoneTTL: TimeInterval = 90 * 24 * 60 * 60

    /// S4 导入第一步：扫墓碑无条件永久删本地副本（永久删赢），顺手清 90 天过期墓碑。
    private static func processTombstones(profileId: String, context: ModelContext) {
        guard let tombDir = tombstoneRoot(profileId: profileId) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: tombDir, includingPropertiesForKeys: nil) else { return }
        let pid = profileId
        var exp = loadExportState(profileId: profileId)
        var imp = loadImportState(profileId: profileId)
        var stateDirty = false

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let tomb = try? decoder.decode(TombstoneDocument.self, from: data),
                  tomb.profileId == profileId else { continue }

            // 90 天过期 → 清墓碑文件，不再触发删除
            if Date().timeIntervalSince(tomb.deletedAt) > tombstoneTTL {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let convId = tomb.conversationId
            let convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.id == convId && $0.profileId == pid }
            )
            guard let conv = (try? context.fetch(convDesc))?.first else { continue }

            // 无条件永久删（即使本地 updateTime 比墓碑新 = 对端恢复过，墓碑仍赢）
            let nodeDesc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
            )
            if let nodes = try? context.fetch(nodeDesc) { for n in nodes { context.delete(n) } }
            let favDesc = FetchDescriptor<FavoriteItem>(
                predicate: #Predicate<FavoriteItem> { $0.conversationId == convId && $0.profileId == pid }
            )
            if let items = try? context.fetch(favDesc) { for i in items { context.delete(i) } }
            AttachmentStore.deleteConversationAttachments(conversationId: convId, profileId: profileId)
            context.delete(conv)
            try? context.save()

            // 清指纹 + 删可能残留的云文档（对端误重导出的副本）
            exp[convId] = nil
            imp["\(convId).json"] = nil
            stateDirty = true
            if let root = syncRoot(profileId: profileId) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("\(convId).json"))
            }
            SyncProbe.log("TOMBSTONE delete conv=\(convId.prefix(8))")
        }

        if stateDirty {
            saveExportState(exp, profileId: profileId)
            saveImportState(imp, profileId: profileId)
        }
    }

    /// 扫描同步目录全部文档（含 iCloud 冲突副本——并集合并天然幂等，越合越全）。
    /// 合并规则见 plan：元数据 LWW / 只插缺失节点 / childrenIds 并集。后台 context 上跑。
    static func importAll(profileId: String, context: ModelContext) -> ImportResult {
        processTombstones(profileId: profileId, context: context)
        var result = ImportResult()
        guard let root = syncRoot(profileId: profileId) else { return result }
        let (allFiles, downloading) = materializeDocuments(in: root)
        result.documentsDownloading = downloading
        var state = loadExportState(profileId: profileId)
        var importState = loadImportState(profileId: profileId)
        var dirty = false

        // mtime 增量：只解码有变化的文档
        let files = allFiles.filter { url in
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let seen = importState[url.lastPathComponent], seen >= mtime { return false }
            importState[url.lastPathComponent] = mtime
            return true
        }
        if !files.isEmpty { SyncProbe.log("IMPORT changed-files=\(files.map { String($0.lastPathComponent.prefix(8)) }.joined(separator: ","))") }

        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL),
                  let document = try? decoder.decode(ConversationDocument.self, from: data),
                  document.schemaVersion <= schemaVersion,
                  document.profileId == profileId else { continue }
            result.documentsScanned += 1

            let convId = document.conversationId
            let pid = profileId
            let convDescriptor = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.id == convId && $0.profileId == pid }
            )
            let existing = (try? context.fetch(convDescriptor))?.first

            let conversation: Conversation
            if let existing {
                conversation = existing
                if document.updateTime > existing.updateTime {
                    existing.title = document.title
                    existing.updateTime = document.updateTime
                    existing.currentNodeId = document.currentNodeId
                    existing.isFavorite = document.isFavorite
                    existing.folderId = document.folderId
                    existing.pinnedAt = document.pinnedAt
                    existing.memoryEnabled = document.memoryEnabled
                    existing.selectedModelId = document.selectedModelId
                    // S4：软删状态走 LWW（对端删→本地进回收站，对端恢复→本地恢复）
                    existing.isTrashed = document.isDeleted ?? false
                    existing.deletedAt = document.deletedAt
                    result.conversationsUpdated += 1
                    dirty = true
                }
            } else {
                let created = Conversation(
                    id: document.conversationId, title: document.title,
                    createTime: document.createTime, updateTime: document.updateTime,
                    currentNodeId: document.currentNodeId, provider: document.provider,
                    profileId: profileId
                )
                created.isFavorite = document.isFavorite
                created.folderId = document.folderId
                created.pinnedAt = document.pinnedAt
                created.memoryEnabled = document.memoryEnabled
                created.selectedModelId = document.selectedModelId
                // S4：对端软删的对话首次到货 → 直接建成回收站状态
                created.isTrashed = document.isDeleted ?? false
                created.deletedAt = document.deletedAt
                context.insert(created)
                conversation = created
                result.conversationsCreated += 1
                dirty = true
            }

            // 本地已有节点 id 集（绝不重插：unique=upsert 会改写本地状态）
            let nodeDescriptor = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
            )
            let localNodes = (try? context.fetch(nodeDescriptor)) ?? []
            var localById: [String: MessageNode] = [:]
            for node in localNodes { localById[node.id] = node }

            for nodeDoc in document.nodes {
                if let local = localById[nodeDoc.id] {
                    // childrenIds 并集（两端各自长出的分支共存）
                    let merged = local.childrenIds + nodeDoc.childrenIds.filter { !local.childrenIds.contains($0) }
                    if merged.count != local.childrenIds.count {
                        local.childrenIds = merged
                        dirty = true
                    }
                    continue
                }
                let node = MessageNode(
                    id: nodeDoc.id, role: nodeDoc.role, content: nodeDoc.content,
                    contentType: nodeDoc.contentType, createTime: nodeDoc.createTime,
                    parentId: nodeDoc.parentId, childrenIds: nodeDoc.childrenIds,
                    conversationId: convId, profileId: profileId
                )
                node.isFavorite = nodeDoc.isFavorite
                node.isPinned = nodeDoc.isPinned
                node.pinnedAt = nodeDoc.pinnedAt
                node.segmentsData = nodeDoc.segmentsData
                node.ccMessageId = nodeDoc.ccMessageId
                node.replyToId = nodeDoc.replyToId
                node.ccEdited = nodeDoc.ccEdited
                node.ccThinking = nodeDoc.ccThinking
                node.imageDescsData = nodeDoc.imageDescsData
                context.insert(node)
                localById[nodeDoc.id] = node
                result.nodesInserted += 1
                dirty = true
            }

            conversation.nodeCount = max(conversation.nodeCount, document.nodes.count)
            // 回环抑制：导入版指纹直接记为已导出，避免回声导出
            if (state[convId] ?? .distantPast) < document.updateTime {
                state[convId] = document.updateTime
            }
        }

        if dirty { try? context.save() }
        saveExportState(state, profileId: profileId)
        saveImportState(importState, profileId: profileId)
        if result.nodesInserted > 0 || result.conversationsCreated > 0 || result.documentsDownloading > 0 {
            SyncProbe.log("IMPORT done +conv=\(result.conversationsCreated) +nodes=\(result.nodesInserted) downloading=\(result.documentsDownloading)")
        }
        return result
    }

    /// 立即同步 = 先导入后导出。后台 context 上跑。
    static func syncNow(profileId: String, context: ModelContext, progress: ((String) -> Void)? = nil) -> (imported: ImportResult, exported: ExportResult) {
        cleanupLegacySharedState(profileId: profileId)
        progress?("正在导入…")
        let imported = importAll(profileId: profileId, context: context)
        let exported = exportChanged(profileId: profileId, context: context, progress: progress)
        return (imported, exported)
    }
}
