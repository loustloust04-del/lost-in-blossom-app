import Foundation
import SwiftData

struct ImportedNodePayload {
    let id: String
    let role: String
    let content: String
    let contentType: String
    let createTime: Date?
    let parentId: String?
    let childrenIds: [String]
    /// Claude v2 导入：JSON 编码的 [MessageSegment]。非 Claude 或 fallback 场景为 nil。
    var segmentsData: Data? = nil
}

struct ImportedConversationPayload {
    let id: String
    let title: String
    let createTime: Date
    let updateTime: Date
    let currentNodeId: String
    let provider: String
    let nodes: [ImportedNodePayload]
}

func fetchConversationNodes(conversationId: String, profileId: String, in context: ModelContext) throws -> [MessageNode] {
    let targetConvId = conversationId
    let targetProfileId = profileId
    let descriptor = FetchDescriptor<MessageNode>(
        predicate: #Predicate<MessageNode> {
            $0.conversationId == targetConvId && $0.profileId == targetProfileId
        }
    )
    return try context.fetch(descriptor)
}

func countDisplayableNodes(_ nodes: [ImportedNodePayload]) -> Int {
    nodes.reduce(into: 0) { count, node in
        if isDisplayableNode(role: node.role, content: node.content) {
            count += 1
        }
    }
}

func countDisplayableNodes(_ nodes: [MessageNode]) -> Int {
    nodes.reduce(into: 0) { count, node in
        if isDisplayableNode(role: node.role, content: node.content) {
            count += 1
        }
    }
}

func isDisplayableNode(role: String, content: String) -> Bool {
    (role == "user" || role == "assistant") && !content.isEmpty
}

func mergedChildrenIds(incoming: [String], existing: [String]) -> [String] {
    var seen = Set<String>()
    var merged: [String] = []

    for childId in incoming + existing {
        if seen.insert(childId).inserted {
            merged.append(childId)
        }
    }

    return merged
}

func importedNodeDiffers(from existing: MessageNode, incoming: ImportedNodePayload) -> Bool {
    let existingChildren = Set(existing.childrenIds)
    let incomingChildren = Set(incoming.childrenIds)

    return existing.role != incoming.role ||
    existing.content != incoming.content ||
    existing.contentType != incoming.contentType ||
    existing.createTime != incoming.createTime ||
    existing.parentId != incoming.parentId ||
    !incomingChildren.isSubset(of: existingChildren) ||
    existing.segmentsData != incoming.segmentsData
}

func importedConversationMetadataDiffers(from existing: Conversation, incoming: ImportedConversationPayload) -> Bool {
    existing.title != incoming.title ||
    existing.createTime != incoming.createTime ||
    existing.updateTime != incoming.updateTime ||
    existing.currentNodeId != incoming.currentNodeId ||
    existing.provider != incoming.provider
}

func shouldMergeConversation(
    existing: Conversation,
    existingNodes: [MessageNode],
    incoming: ImportedConversationPayload
) -> Bool {
    let existingNodeMap = Dictionary(uniqueKeysWithValues: existingNodes.map { ($0.id, $0) })
    let existingNodeIds = Set(existingNodeMap.keys)
    let incomingNodeIds = Set(incoming.nodes.map(\.id))

    if !incomingNodeIds.isSubset(of: existingNodeIds) {
        return true
    }

    if importedConversationMetadataDiffers(from: existing, incoming: incoming),
       incoming.updateTime >= existing.updateTime {
        return true
    }

    for incomingNode in incoming.nodes {
        guard let existingNode = existingNodeMap[incomingNode.id] else { continue }
        if importedNodeDiffers(from: existingNode, incoming: incomingNode),
           incoming.updateTime >= existing.updateTime {
            return true
        }
    }

    return false
}

func applyImportedConversationMetadata(
    _ incoming: ImportedConversationPayload,
    to conversation: Conversation,
    nodeCount: Int
) {
    conversation.title = incoming.title
    conversation.createTime = incoming.createTime
    conversation.updateTime = incoming.updateTime
    conversation.currentNodeId = incoming.currentNodeId
    conversation.provider = incoming.provider
    conversation.nodeCount = nodeCount
}

@discardableResult
func applyImportedNode(_ incoming: ImportedNodePayload, to node: MessageNode) -> Bool {
    let changed = importedNodeDiffers(from: node, incoming: incoming)

    node.role = incoming.role
    node.content = incoming.content
    node.contentType = incoming.contentType
    node.createTime = incoming.createTime
    node.parentId = incoming.parentId
    node.childrenIds = mergedChildrenIds(incoming: incoming.childrenIds, existing: node.childrenIds)
    node.segmentsData = incoming.segmentsData

    return changed
}

func makeImportedNode(_ incoming: ImportedNodePayload, conversationId: String, profileId: String) -> MessageNode {
    let node = MessageNode(
        id: incoming.id,
        role: incoming.role,
        content: incoming.content,
        contentType: incoming.contentType,
        createTime: incoming.createTime,
        parentId: incoming.parentId,
        childrenIds: incoming.childrenIds,
        conversationId: conversationId,
        profileId: profileId
    )
    node.segmentsData = incoming.segmentsData
    return node
}

func encodeSnapshots(
    conversation: Conversation,
    nodes: [MessageNode]
) throws -> (conversationData: Data, nodesData: Data) {
    let encoder = JSONEncoder()
    let conversationSnapshot = ConversationSnapshot(conversation: conversation)
    let nodeSnapshots = nodes.map(MessageNodeSnapshot.init(node:))
    let conversationData = try encoder.encode(conversationSnapshot)
    let nodesData = try encoder.encode(nodeSnapshots)
    return (conversationData, nodesData)
}

func decodeConversationSnapshot(from data: Data?) throws -> ConversationSnapshot? {
    guard let data else { return nil }
    return try JSONDecoder().decode(ConversationSnapshot.self, from: data)
}

func decodeNodeSnapshots(from data: Data?) throws -> [MessageNodeSnapshot] {
    guard let data else { return [] }
    return try JSONDecoder().decode([MessageNodeSnapshot].self, from: data)
}

func cleanupNodeArtifacts(
    in context: ModelContext,
    conversationId: String,
    profileId: String,
    removedNodeIds: Set<String>
) throws {
    guard !removedNodeIds.isEmpty else { return }

    let targetConvId = conversationId
    let targetProfileId = profileId
    let favoriteDescriptor = FetchDescriptor<FavoriteItem>(
        predicate: #Predicate<FavoriteItem> {
            $0.conversationId == targetConvId && $0.profileId == targetProfileId
        }
    )
    let favorites = try context.fetch(favoriteDescriptor)
    for favorite in favorites {
        if let nodeId = favorite.nodeId, removedNodeIds.contains(nodeId) {
            context.delete(favorite)
        }
    }

    let userCardDescriptor = FetchDescriptor<UserCard>(
        predicate: #Predicate<UserCard> { $0.profileId == targetProfileId }
    )
    let userCards = try context.fetch(userCardDescriptor)
    for card in userCards {
        if let nodeId = card.attachedToNodeId, removedNodeIds.contains(nodeId) {
            context.delete(card)
        }
    }
}

func deleteConversationArtifacts(
    conversationId: String,
    profileId: String,
    in context: ModelContext
) throws {
    let nodes = try fetchConversationNodes(conversationId: conversationId, profileId: profileId, in: context)
    let nodeIds = Set(nodes.map(\.id))

    try cleanupNodeArtifacts(in: context, conversationId: conversationId, profileId: profileId, removedNodeIds: nodeIds)

    for node in nodes {
        context.delete(node)
    }

    let targetConvId = conversationId
    let targetProfileId = profileId
    let favoriteDescriptor = FetchDescriptor<FavoriteItem>(
        predicate: #Predicate<FavoriteItem> {
            $0.conversationId == targetConvId && $0.profileId == targetProfileId
        }
    )
    let conversationFavorites = try context.fetch(favoriteDescriptor)
    for favorite in conversationFavorites {
        context.delete(favorite)
    }

    let conversationDescriptor = FetchDescriptor<Conversation>(
        predicate: #Predicate<Conversation> {
            $0.id == targetConvId && $0.profileId == targetProfileId
        }
    )
    if let conversation = try context.fetch(conversationDescriptor).first {
        context.delete(conversation)
    }
}

// MARK: - P0-1 跨楼层冲突防护

private let crossProfileQueryBatchSize = 500

func findCrossProfileConversationConflicts(
    candidateIds: [String],
    currentProfileId: String,
    in context: ModelContext
) throws -> Set<String> {
    var conflicts = Set<String>()
    guard !candidateIds.isEmpty else { return conflicts }
    // 只查还活着的楼层（已删楼层的残留数据不应阻止导入）
    let aliveProfileIds = Set(ProfileManager.loadProfiles().map(\.id))
    for start in stride(from: 0, to: candidateIds.count, by: crossProfileQueryBatchSize) {
        let chunk = Array(candidateIds[start..<min(start + crossProfileQueryBatchSize, candidateIds.count)])
        let pid = currentProfileId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId != pid }
        )
        for hit in try context.fetch(descriptor) {
            // 跳过已删楼层的残留数据
            if aliveProfileIds.contains(hit.profileId) {
                conflicts.insert(hit.id)
            }
        }
    }
    return conflicts
}

func findCrossProfileNodeConflicts(
    candidateIds: [String],
    currentProfileId: String,
    in context: ModelContext
) throws -> Set<String> {
    var conflicts = Set<String>()
    guard !candidateIds.isEmpty else { return conflicts }
    // 只查还活着的楼层
    let aliveProfileIds = Set(ProfileManager.loadProfiles().map(\.id))
    for start in stride(from: 0, to: candidateIds.count, by: crossProfileQueryBatchSize) {
        let chunk = Array(candidateIds[start..<min(start + crossProfileQueryBatchSize, candidateIds.count)])
        let pid = currentProfileId
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { chunk.contains($0.id) && $0.profileId != pid }
        )
        for hit in try context.fetch(descriptor) {
            if aliveProfileIds.contains(hit.profileId) {
                conflicts.insert(hit.id)
            }
        }
    }
    return conflicts
}

func crossProfileConflictedConversationIds(
    payloads: [ImportedConversationPayload],
    currentProfileId: String,
    in context: ModelContext
) throws -> Set<String> {
    guard !payloads.isEmpty else { return [] }
    var conflicted = try findCrossProfileConversationConflicts(
        candidateIds: payloads.map(\.id),
        currentProfileId: currentProfileId,
        in: context
    )
    let nodeConflicts = try findCrossProfileNodeConflicts(
        candidateIds: payloads.flatMap { $0.nodes.map(\.id) },
        currentProfileId: currentProfileId,
        in: context
    )
    if !nodeConflicts.isEmpty {
        for payload in payloads where payload.nodes.contains(where: { nodeConflicts.contains($0.id) }) {
            conflicted.insert(payload.id)
        }
    }
    return conflicted
}

func crossProfileConflictSuffix(_ count: Int) -> String {
    count > 0 ? "；⚠️ \(count) 条对话已存在于其他楼层，已跳过" : ""
}

func restoreConversationChange(
    _ change: ImportConversationChange,
    in context: ModelContext
) throws {
    // change 自带 profileId（ImportConversationChange @Model 已加字段）
    let profileId = change.profileId
    switch change.changeKind {
    case .created:
        try deleteConversationArtifacts(conversationId: change.conversationId, profileId: profileId, in: context)
    case .updated:
        guard let conversationSnapshot = try decodeConversationSnapshot(from: change.beforeConversationData) else {
            return
        }
        let nodeSnapshots = try decodeNodeSnapshots(from: change.beforeNodesData)
        let targetId = change.conversationId
        let targetProfileId = profileId

        let conversationDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> {
                $0.id == targetId && $0.profileId == targetProfileId
            }
        )
        let existingConversation = try context.fetch(conversationDescriptor).first
        let conversation = existingConversation ?? conversationSnapshot.makeConversation(profileId: profileId)
        if existingConversation == nil {
            context.insert(conversation)
        }
        conversationSnapshot.apply(to: conversation)

        let currentNodes = try fetchConversationNodes(conversationId: change.conversationId, profileId: profileId, in: context)
        let currentNodeMap = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.id, $0) })
        let snapshotNodeIds = Set(nodeSnapshots.map(\.id))
        let currentNodeIds = Set(currentNodes.map(\.id))
        let removedNodeIds = currentNodeIds.subtracting(snapshotNodeIds)

        try cleanupNodeArtifacts(in: context, conversationId: change.conversationId, profileId: profileId, removedNodeIds: removedNodeIds)

        for node in currentNodes where removedNodeIds.contains(node.id) {
            context.delete(node)
        }

        for snapshot in nodeSnapshots {
            if let existingNode = currentNodeMap[snapshot.id] {
                snapshot.apply(to: existingNode)
            } else {
                context.insert(snapshot.makeNode(profileId: profileId))
            }
        }
    }
}
