import Foundation
import SwiftData

enum ImportConversationChangeKind: String, Codable {
    case created
    case updated
}

@Model
final class ImportConversationChange {
    #Index<ImportConversationChange>(
        [\.profileId, \.recordId]
    )

    var id: UUID = UUID()
    /// 楼层隔离
    var profileId: String = ""
    var recordId: UUID
    var conversationId: String
    var changeKindRaw: String
    var beforeConversationData: Data?
    var beforeNodesData: Data?

    var changeKind: ImportConversationChangeKind {
        get { ImportConversationChangeKind(rawValue: changeKindRaw) ?? .created }
        set { changeKindRaw = newValue.rawValue }
    }

    init(
        recordId: UUID,
        conversationId: String,
        changeKind: ImportConversationChangeKind,
        beforeConversationData: Data? = nil,
        beforeNodesData: Data? = nil,
        profileId: String = ""
    ) {
        self.recordId = recordId
        self.conversationId = conversationId
        self.changeKindRaw = changeKind.rawValue
        self.beforeConversationData = beforeConversationData
        self.beforeNodesData = beforeNodesData
        self.profileId = profileId
    }
}

struct ConversationSnapshot: Codable {
    let id: String
    let title: String
    let createTime: Date
    let updateTime: Date
    let currentNodeId: String
    let isFavorite: Bool
    let folderId: String?
    let nodeCount: Int
    let lastOpenedAt: Date?
    let isDeleted: Bool
    let deletedAt: Date?
    let provider: String
    let importBatchId: UUID?

    init(conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        createTime = conversation.createTime
        updateTime = conversation.updateTime
        currentNodeId = conversation.currentNodeId
        isFavorite = conversation.isFavorite
        folderId = conversation.folderId
        nodeCount = conversation.nodeCount
        lastOpenedAt = conversation.lastOpenedAt
        isDeleted = conversation.isTrashed
        deletedAt = conversation.deletedAt
        provider = conversation.provider
        importBatchId = conversation.importBatchId
    }

    func apply(to conversation: Conversation) {
        conversation.title = title
        conversation.createTime = createTime
        conversation.updateTime = updateTime
        conversation.currentNodeId = currentNodeId
        conversation.isFavorite = isFavorite
        conversation.folderId = folderId
        conversation.nodeCount = nodeCount
        conversation.lastOpenedAt = lastOpenedAt
        conversation.isTrashed = isDeleted
        conversation.deletedAt = deletedAt
        conversation.provider = provider
        conversation.importBatchId = importBatchId
    }

    func makeConversation(profileId: String) -> Conversation {
        let conversation = Conversation(
            id: id,
            title: title,
            createTime: createTime,
            updateTime: updateTime,
            currentNodeId: currentNodeId,
            provider: provider,
            profileId: profileId
        )
        apply(to: conversation)
        return conversation
    }
}

struct MessageNodeSnapshot: Codable {
    let id: String
    let role: String
    let content: String
    let contentType: String
    let createTime: Date?
    let parentId: String?
    let childrenIds: [String]
    let conversationId: String
    let isFavorite: Bool
    let isDeleted: Bool
    let deletedAt: Date?
    /// Claude v2 segmentsData snapshot；老数据或解码失败时为 nil，undo 走老路径即可。
    let segmentsData: Data?

    init(node: MessageNode) {
        id = node.id
        role = node.role
        content = node.content
        contentType = node.contentType
        createTime = node.createTime
        parentId = node.parentId
        childrenIds = node.childrenIds
        conversationId = node.conversationId
        isFavorite = node.isFavorite
        isDeleted = node.isTrashed
        deletedAt = node.deletedAt
        segmentsData = node.segmentsData
    }

    func apply(to node: MessageNode) {
        node.role = role
        node.content = content
        node.contentType = contentType
        node.createTime = createTime
        node.parentId = parentId
        node.childrenIds = childrenIds
        node.conversationId = conversationId
        node.isFavorite = isFavorite
        node.isTrashed = isDeleted
        node.deletedAt = deletedAt
        node.segmentsData = segmentsData
    }

    func makeNode(profileId: String) -> MessageNode {
        let node = MessageNode(
            id: id,
            role: role,
            content: content,
            contentType: contentType,
            createTime: createTime,
            parentId: parentId,
            childrenIds: childrenIds,
            conversationId: conversationId,
            profileId: profileId
        )
        apply(to: node)
        return node
    }
}
