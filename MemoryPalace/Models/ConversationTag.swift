import Foundation
import SwiftData

/// 对话标签 — 用户可自定义，多对多关联到 Conversation（通过 FavoriteItem join）
@Model
final class ConversationTag {
    #Index<ConversationTag>(
        [\.profileId],
        [\.profileId, \.order]
    )

    @Attribute(.unique) var id: String = UUID().uuidString
    /// 楼层隔离
    var profileId: String = ""
    var name: String
    var emoji: String = "🏷"
    var order: Int = 0
    var createTime: Date = Date()

    init(name: String, emoji: String = "🏷", order: Int = 0, profileId: String = "") {
        self.id = UUID().uuidString
        self.name = name
        self.emoji = emoji
        self.order = order
        self.profileId = profileId
    }
}

/// Conversation ↔ ConversationTag 的 join item，也兼容收藏单条 bubble
@Model
final class FavoriteItem {
    #Index<FavoriteItem>(
        [\.profileId],
        [\.profileId, \.conversationId]
    )

    @Attribute(.unique) var id: String = UUID().uuidString
    /// 楼层隔离
    var profileId: String = ""
    var nodeId: String?                    // if favoriting a single bubble
    var conversationId: String = ""        // always set (默认值用于 lightweight migration)
    var tagId: String = ""                 // which tag it belongs to (新字段，T0 refactor 时 folderId→tagId)
    var contentPreview: String = ""        // first ~100 chars for display
    var createTime: Date = Date()

    init(nodeId: String? = nil, conversationId: String, tagId: String, contentPreview: String, profileId: String) {
        self.id = UUID().uuidString
        self.nodeId = nodeId
        self.conversationId = conversationId
        self.tagId = tagId
        self.contentPreview = contentPreview
        self.profileId = profileId
    }
}
