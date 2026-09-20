import Foundation
import SwiftData

// MARK: - Actions

extension ConversationViewModel {

    func toggleFavorite(_ node: MessageNode) {
        node.isFavorite.toggle()
    }

    func togglePin(_ node: MessageNode) {
        if node.isPinned {
            node.isPinned = false
            node.pinnedAt = nil
        } else {
            node.isPinned = true
            node.pinnedAt = Date()
        }
    }

    func unpinAll() {
        for node in currentPath where node.isPinned {
            node.isPinned = false
            node.pinnedAt = nil
        }
    }

    /// 当前对话 pin 的节点，按 pinnedAt 降序（新 → 旧），过滤软删除
    var pinnedNodes: [MessageNode] {
        currentPath
            .filter { $0.isPinned && !$0.isTrashed }
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    /// 便宜的存在性判断——短路，不做 filter + sort 分配。ContentView.iOSChatTopBar 每次
    /// body 都要判断 PinBar 显隐，用它替代 `!pinnedNodes.isEmpty`（后者每帧全量 filter+sort）。
    var hasPinnedNodes: Bool {
        currentPath.contains { $0.isPinned && !$0.isTrashed }
    }

    func softDelete(_ node: MessageNode) {
        // 删除案终审（09-02，五案连环后结案）：isDeleted 是 SwiftData PersistentModel
        // 保留属性，自声明同名字段从不入库——已整仓改名 isTrashed（e6fdb81d，粟粟同坑
        // 同修 8c37870a）。同步置标 + 显式落盘是前两刀留下的真修，保留。
        let deletedId = node.id
        node.isTrashed = true
        node.deletedAt = Date()
        try? node.modelContext?.save()
        currentPath.removeAll { $0.id == deletedId }

        // 2) Defer sidebar bookkeeping so UI updates first
        let conv = selectedConversation
        DispatchQueue.main.async { [self] in
            // 软删除是"内容改动"，同步更新对话的 updateTime + nodeCount + 走 3s
            // debounce 重排（之前漏了，导致 sidebar 行里 nodeCount 不减、位置不变）
            if let conv {
                conv.updateTime = Date()
                conv.nodeCount = currentPath.filter {
                    ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty
                }.count
                markConversationDirty()
            }
        }
    }

    func restore(_ node: MessageNode) {
        node.isTrashed = false
        node.deletedAt = nil
        try? node.modelContext?.save()
        if selectedConversation != nil {
            nodeMap[node.id] = node
            buildEffectiveChildrenMap()
            rebuildPath()
        }
    }
}

// MARK: - Conversation Delete / Restore

extension ConversationViewModel {

    func softDeleteConversation(_ conversation: Conversation) {
        conversation.isTrashed = true
        conversation.deletedAt = Date()
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
            currentPath = []
        }
    }

    func restoreConversation(_ conversation: Conversation) {
        conversation.isTrashed = false
        conversation.deletedAt = nil
    }

    func permanentlyDeleteConversation(_ conversation: Conversation, context: ModelContext) {
        let convId = conversation.id
        let convProfileId = conversation.profileId

        // 清理上下文摘要
        ContextSummarizer.clear(conversationId: convId)

        // Delete all MessageNodes belonging to this conversation
        let nodeDescriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.conversationId == convId && node.profileId == convProfileId
            }
        )
        if let nodes = try? context.fetch(nodeDescriptor) {
            for node in nodes { context.delete(node) }
        }

        // Delete all FavoriteItems referencing this conversation
        let favDescriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { item in
                item.conversationId == convId && item.profileId == convProfileId
            }
        )
        if let items = try? context.fetch(favDescriptor) {
            for item in items { context.delete(item) }
        }

        // Clear selection if needed
        if selectedConversation?.id == convId {
            selectedConversation = nil
            currentPath = []
        }

        context.delete(conversation)
    }

    func permanentlyDeleteNode(_ node: MessageNode, context: ModelContext) {
        let nodeId = node.id
        let nodeProfileId = node.profileId

        // Delete FavoriteItems referencing this node
        let favDescriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { item in
                item.nodeId == nodeId && item.profileId == nodeProfileId
            }
        )
        if let items = try? context.fetch(favDescriptor) {
            for item in items { context.delete(item) }
        }

        context.delete(node)
    }
}

// MARK: - Export

extension ConversationViewModel {

    /// Export the currently loaded conversation as Markdown
    func exportMarkdown(mode: ExportPathMode, userName: String, assistantName: String) -> String {
        guard let rootId = cachedRootId ?? findRootId() else { return "" }
        return MarkdownExporter.export(
            nodeMap: nodeMap,
            effectiveChildren: effectiveChildrenMap,
            rootId: rootId,
            mainPathIds: mainPathIds,
            currentPath: currentPath,
            mode: mode,
            userName: userName,
            assistantName: assistantName
        )
    }
}
