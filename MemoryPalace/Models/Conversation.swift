import Foundation
import SwiftData

@Model
final class Conversation {
    #Index<Conversation>(
        [\.profileId],
        [\.profileId, \.lastOpenedAt],
        [\.profileId, \.isTrashed, \.lastOpenedAt]
    )

    @Attribute(.unique) var id: String
    /// 楼层隔离。路线 B 单 ModelContainer 下所有 fetch 必须带 profileId predicate。
    /// 新建时必填；迁移老数据时补填。默认 "" 只为 SwiftData lightweight migration。
    var profileId: String = ""
    var title: String
    var createTime: Date
    var updateTime: Date
    var currentNodeId: String
    var isFavorite: Bool = false
    var folderId: String?

    var nodeCount: Int = 0
    var lastOpenedAt: Date?

    var isTrashed: Bool = false
    var deletedAt: Date?

    /// "chatgpt", "claude", "api", "sillytavern"
    var provider: String = "chatgpt"

    /// Links to ImportRecord.id for batch undo
    var importBatchId: UUID?

    /// nil = native (App内新建), "claude" = Claude导入, "chatgpt" = ChatGPT导入
    var source: String?

    /// 记忆参与开关（默认 true）
    /// false = 此对话不贡献记忆到楼层池，也不接收记忆注入
    var memoryEnabled: Bool = true
    /// Stub: upstream sync dependency
    var selectedModelId: String = ""
    var pinnedAt: Date? = nil

    /// 所属项目 ID（nil = 不属于任何项目）
    var projectId: String?

    /// CC Bridge session 绑定（nil = 用默认 mp-cc 会话）
    var ccBridgeSessionName: String? = nil

    /// 写作风格 ID（空 = 不启用）
    var currentStyleId: String = ""

    /// B41 输入框草稿：每键直写 + 显式 save（不依赖 autosave，杀进程会丢）。
    /// 切走对话 / 杀进程再回来，输入一半的字都还在。
    var draftText: String = ""

    /// 群聊 V2："single" = 单聊（默认），"group" = 多角色群聊。
    var kind: String = "single"
    /// 群聊参与者（JSON 编码的 [GroupParticipant]）。单聊为 nil。
    @Attribute(.externalStorage) var participantsData: Data? = nil

    /// 解码/编码参与者（计算属性，不持久化）。
    var participants: [GroupParticipant] {
        get {
            guard let data = participantsData else { return [] }
            return (try? JSONDecoder().decode([GroupParticipant].self, from: data)) ?? []
        }
        set { participantsData = try? JSONEncoder().encode(newValue) }
    }

    init(id: String, title: String, createTime: Date, updateTime: Date, currentNodeId: String, provider: String = "chatgpt", profileId: String = "") {
        self.id = id
        self.title = title
        self.createTime = createTime
        self.updateTime = updateTime
        self.currentNodeId = currentNodeId
        self.provider = provider
        self.profileId = profileId
    }
}

@Model
final class MessageNode {
    #Index<MessageNode>(
        [\.profileId],
        [\.profileId, \.conversationId],
        [\.profileId, \.conversationId, \.isTrashed]
    )

    @Attribute(.unique) var id: String
    /// 楼层隔离。Migration 会给老数据补填。注：MessageNode 用 parentId: String? 做树
    /// 关系，不是 @Relationship —— migration 时 1-pass copy 即可，无需 2-pass。
    var profileId: String = ""
    var role: String            // user, assistant, system, tool
    var content: String
    var contentType: String     // text, code, multimodal_text, segmented 等
    var createTime: Date?
    var parentId: String?
    var childrenIds: [String] = []
    var conversationId: String

    var isFavorite: Bool = false
    var isPinned: Bool = false
    var pinnedAt: Date? = nil
    var isTrashed: Bool = false
    var deletedAt: Date?

    /// 结构化分段（Claude importer v2 写入）。JSON 编码的 [MessageSegment]。
    /// 为 nil 时消息按旧路径渲染（基于 content 字符串 + extractThinking）。
    @Attribute(.externalStorage) var segmentsData: Data?

    /// 群聊 V2：发言者身份（单聊为 nil）。senderName 用于渲染名字标签 + 镜像 prompt 前缀。
    var senderId: String? = nil
    var senderName: String? = nil
    /// 读书问 AI：user 消息关联的书+章（"safeName#chapterN"）。共读真身回填 aiBubble 用。
    var bookRef: String? = nil

    /// Stubs: upstream sync dependencies
    var ccMessageId: String? = nil
    var replyToId: String? = nil
    var ccEdited: Bool = false
    var ccThinking: String? = nil
    @Attribute(.externalStorage) var imageDescsData: Data? = nil

    /// PR(usage): 每条 AI 回复的 token 用量快照（气泡 footer 显示）。
    /// 可选字段，旧数据自动 nil，SwiftData 不需要 migration。
    var usageInputTokens: Int? = nil
    var usageCacheReadTokens: Int? = nil
    var usageCacheCreationTokens: Int? = nil
    var usageOutputTokens: Int? = nil

    /// 发送时的写作风格快照（保真：不随 currentStyleId 切换变）
    var styleIdSnapshot: String? = nil

    // Computed: has branches (more than 1 child)
    var hasBranches: Bool {
        childrenIds.count > 1
    }

    var branchCount: Int {
        childrenIds.count
    }

    /// 解码 segmentsData。nil 表示这是旧数据 / 非 Claude v2 导入的节点。
    var segments: [MessageSegment]? {
        guard let data = segmentsData else { return nil }
        return try? JSONDecoder().decode([MessageSegment].self, from: data)
    }

    /// Claude importer v2 用：一次写入分段数组。
    func setSegments(_ segs: [MessageSegment]) {
        self.segmentsData = try? JSONEncoder().encode(segs)
    }

    init(id: String, role: String, content: String, contentType: String,
         createTime: Date?, parentId: String?, childrenIds: [String], conversationId: String,
         profileId: String = "") {
        self.id = id
        self.role = role
        self.content = content
        self.contentType = contentType
        self.createTime = createTime
        self.parentId = parentId
        self.childrenIds = childrenIds
        self.conversationId = conversationId
        self.profileId = profileId
    }
}

@Model
final class UserCard {
    #Index<UserCard>(
        [\.profileId],
        [\.profileId, \.attachedToNodeId]
    )

    var id: UUID = UUID()
    /// 楼层隔离。新建角色卡必填。
    var profileId: String = ""
    var content: String = ""
    var imageData: Data?
    var attachedToNodeId: String?
    var positionX: Double = 0
    var positionY: Double = 0
    var createTime: Date = Date()

    init(content: String = "", attachedToNodeId: String? = nil, profileId: String = "") {
        self.content = content
        self.attachedToNodeId = attachedToNodeId
        self.profileId = profileId
    }
}


// 粟粟接口对齐（2026-08-30 气泡整套搬运）：她的 usage footer 用 prompt/completion/cost 命名，
// 我们既有 PR(usage) 是 input/cacheRead/cacheCreation/output 四字段。计算属性桥接，不入库。
extension MessageNode {
    var usagePromptTokens: Int? { usageInputTokens }
    var usageCompletionTokens: Int? { usageOutputTokens }
    /// 我们暂不记每轮费用；她的 footer 对 nil/0 自动不显示费用段
    var usageCostUSD: Double? { nil }
}
