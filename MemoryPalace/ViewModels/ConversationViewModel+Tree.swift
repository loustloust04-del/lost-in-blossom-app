import Foundation
import SwiftData

// MARK: - Tree Data Types

extension ConversationViewModel {

    /// BranchMap v6 用：拍一份只读快照（root + nodeMap + childrenMap + currentPath ids）
    /// 让 sheet view 不直接碰 private 状态。
    struct BranchMapSnapshot {
        let rootId: String
        let nodeMap: [String: MessageNode]
        let childrenMap: [String: [String]]
        let currentPathIds: Set<String>
        let mainPathIds: Set<String>   // v10: conversation 永久主路径（切 currentPath 不变）
    }

    /// 一条分支的完整描述（含嵌套）。给 BranchMapSheet v2 用。
    /// branchInfoMap 只覆盖当前 currentPath 上的 anchor，看不到嵌套二级分支；
    /// 这个函数 DFS 整棵 effectiveChildrenMap 树，收集所有有 ≥2 displayable
    /// children 的 anchor 的所有非"主选 child"，包括分支之中的子分支。
    /// depth=0 表示 anchor 在主线上；depth>0 表示 anchor 自己也是别人的分支。
    struct AllBranchEntry: Identifiable {
        let id: String                  // anchor + childIndex 唯一
        let anchorNodeId: String        // 实际 branching node id（≥2 children）
        let childIndex: Int             // 该分支是 anchor 的第几个 child
        let childPreviewNode: MessageNode  // 分支起点的第一条 displayable
        let depth: Int                  // 0 = 主线分支；>0 = 分支的分支
        let parentAnchorOnMain: String?  // 一路追溯到主线 anchor 的 nodeId（用于按主线位置排序）
        let parentBranchEntryId: String?  // v5 outline tree：嵌套分支指向直接父 entry id（一级 = nil）
        let length: Int                 // 分支长度（displayable node 数）
        let location: Int               // 在主线 currentPath 第几条；嵌套分支 = parent 的 location
    }
}

// MARK: - Load Conversation

extension ConversationViewModel {

    /// Background-computed tree data (pure value types, safe to cross threads)
    private struct TreeData {
        let effectiveChildrenMap: [String: [String]]
        let rootId: String?
        let mainPathIds: Set<String>
        let pathNodeIds: [String]
        let bubbledBranches: [String: String]
        let displayableCount: Int
        let allNodeIds: Set<String>
    }

    func branchMapSnapshot() -> BranchMapSnapshot? {
        guard let root = cachedRootId, nodeMap[root] != nil else { return nil }
        return BranchMapSnapshot(
            rootId: root,
            nodeMap: nodeMap,
            childrenMap: effectiveChildrenMap,
            currentPathIds: Set(currentPath.map { $0.id }),
            mainPathIds: mainPathIds
        )
    }

    /// BranchMap v6 用：单击节点 = 快切 currentPath。
    /// 不走 loadConversation（那是异步全量 buildTree，200ms+）；
    /// 沿 nodeId 的 parent 链回 root，对每个 multi-child anchor 设 branchChoices = next-child idx，
    /// 然后 rebuildPath() 主线程同步重算 currentPath。流畅秒切。
    func navigateToNodeFast(nodeId: String) {
        guard nodeMap[nodeId] != nil else { return }

        var current: String? = nodeId
        var lastVisited: String? = nil
        var visited = Set<String>()
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            let kids = effectiveChildrenMap[id] ?? []
            if kids.count > 1, let next = lastVisited, let idx = kids.firstIndex(of: next) {
                branchChoices[id] = idx
            }
            lastVisited = id
            current = nodeMap[id]?.parentId
        }

        rebuildPath()
        highlightedNodeId = nodeId
        pendingScrollNodeId = nodeId
    }

    /// 旧入口保留：搜索结果 / 外部跳转 用全量 reload（含 fetch）。
    func navigateToNode(nodeId: String, conversation: Conversation, context: ModelContext) {
        pendingScrollNodeId = nodeId
        loadConversation(conversation, context: context, scrollTargetNodeId: nodeId)
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }

    /// 搜索结果点击的统一入口（B20 part 2）。
    /// - 300ms 同 nodeId 去抖，吃掉用户连点
    /// - 主线 node：path 不切（保持 conversation.currentNodeId 主线）+ 仅 scroll
    /// - 分支 node：切 branch（loadConversation scrollTargetNodeId）+ 弹"已切换到分支"
    /// - 不论主/分支：都发 conversationNavigationRequested 通知让 ContentView 切 page 0→1
    func navigateToSearchResult(nodeId: String, conversation: Conversation, context: ModelContext) {
        // 去抖
        let now = Date()
        if let last = lastNavigateAt, lastNavigateNodeId == nodeId,
           now.timeIntervalSince(last) < 0.3 {
            return
        }
        lastNavigateNodeId = nodeId
        lastNavigateAt = now

        // 判断是否在主线
        let cid = conversation.id
        let pid = conversation.profileId
        let nodesDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid }
        )
        let allNodes = (try? context.fetch(nodesDesc)) ?? []
        let mainPathSet = Self.computeMainPathSet(nodes: allNodes, currentNodeId: conversation.currentNodeId)
        let isOnMainPath = mainPathSet.contains(nodeId)

        pendingScrollNodeId = nodeId

        if isOnMainPath {
            // 主线 node：用默认 currentNodeId 重建 path（path 维持原样），仅 scroll
            loadConversation(conversation, context: context)
        } else {
            // 分支 node：切到那条 branch + toast 提示
            loadConversation(conversation, context: context, scrollTargetNodeId: nodeId)
            transientNotice = TransientNotice("已切换到分支")
        }

        // 触发 page 0→1（同 conv 时 selectedConversation?.id 不变 onChange 不响应）
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }

    /// Build path for selected conversation (fetch + tree computation on background thread)
    /// - scrollTargetNodeId: if set, build path through this node instead of conversation.currentNodeId
    func loadConversation(_ conversation: Conversation, context: ModelContext, scrollTargetNodeId: String? = nil) {
        #if DEBUG
        let loadT0 = CFAbsoluteTimeGetCurrent()
        print(String(format: "[PERF] loadConversation start convId=%@ t=%.3f", conversation.id, loadT0))
        #endif

        // 会话巩固：切换对话时刷新旧会话的记忆衰减
        let profileId = UserDefaults.standard.string(forKey: "lastProfileId") ?? ""
        consolidateSessionMemories(profileId: profileId, context: context)
        #if DEBUG
        let tConsolidate = CFAbsoluteTimeGetCurrent()
        print(String(format: "[PERF] loadConversation consolidate=%.0fms", (tConsolidate - loadT0) * 1000))
        #endif

        // Task H：切换对话时记录上一个对话的轻量摘要（标题 + 最后一条 user 片段）
        if let prev = selectedConversation, prev.id != conversation.id {
            let lastUser = currentPath.last(where: { $0.role == "user" })?.content ?? ""
            CrossWindowMemory.record(conversationId: prev.id, title: prev.title, fragment: lastUser)
        }
        selectedConversation = conversation
        // 设置页「查看当前摘要」用：记下当前对话 id
        UserDefaults.standard.set(conversation.id, forKey: "currentConversationId")
        // CC Bridge：随对话加载（重新）注册兜底 handler，让 CC 主动/连发的消息
        // 在没有 in-flight 请求时也能落进对话树（不依赖先 sendMessage 一次）。
        installCCFollowUpHandler(context: context)
        // 点击对话本身不影响排序（旧逻辑 lastOpenedAt = Date() + sidebarRefreshTrigger++
        // 会让对话立刻跳到列表顶部，粟粟的新语义是"纯浏览不打乱列表"）。
        // 真正的内容改动（发消息/rename/贴纸）走 markConversationDirty() 的 3s debounce。
        isLoading = true
        currentPath = []
        branchChoices.removeAll()
        bubbledBranches.removeAll()
        nodeMap.removeAll()
        cachedRootId = nil
        effectiveChildrenMap.removeAll()
        branchInfoMap.removeAll()

        let convId = conversation.id
        let convProfileId = conversation.profileId
        let currentNodeId = scrollTargetNodeId ?? conversation.currentNodeId
        let container = context.container

        DispatchQueue.global(qos: .userInitiated).async {
            #if DEBUG
            let bgT0 = CFAbsoluteTimeGetCurrent()
            #endif
            let treeData = Self.buildTreeInBackground(convId: convId, profileId: convProfileId, currentNodeId: currentNodeId, container: container)
            #if DEBUG
            let bgT1 = CFAbsoluteTimeGetCurrent()
            print(String(format: "[PERF] buildTreeInBackground=%.0fms nodes=%d", (bgT1 - bgT0) * 1000, treeData.allNodeIds.count))
            #endif

            DispatchQueue.main.async { [self] in
                guard selectedConversation?.id == convId else { return }
                #if DEBUG
                let applyT0 = CFAbsoluteTimeGetCurrent()
                #endif
                applyTreeData(treeData, conversation: conversation, context: context)
                #if DEBUG
                let applyT1 = CFAbsoluteTimeGetCurrent()
                print(String(format: "[PERF] applyTreeData=%.0fms loadTotal=%.0fms", (applyT1 - applyT0) * 1000, (applyT1 - loadT0) * 1000))
                #endif
                // 发送排队：本对话若有排队消息（在别的对话切走时没发出去的），
                // 树就绪后补发。turn in-flight 时 drain 内部自己跳过。
                drainPendingSends()
            }
        }
    }

    /// Compute the main-path nodeId set for a given conversation snapshot.
    /// 给定 nodes 和 currentNodeId，按 buildTreeInBackground 同套算法
    /// （反向 trace mainPath + 正向走选 child）算出主线 nodeId Set。
    /// 用于搜索过滤、UI 高亮等不需要全套 TreeData 的场景。
    /// 算法跟 buildTreeInBackground 必须一致（搜索结果不能跟 chat 显示打架）。
    static func computeMainPathSet(nodes: [MessageNode], currentNodeId: String) -> Set<String> {
        struct NI {
            let role: String
            let hasContent: Bool
            let isTrashed: Bool
            let parentId: String?
            let childrenIds: [String]
        }
        var infoMap: [String: NI] = [:]
        infoMap.reserveCapacity(nodes.count)
        for n in nodes {
            infoMap[n.id] = NI(role: n.role, hasContent: !n.content.isEmpty, isTrashed: n.isTrashed, parentId: n.parentId, childrenIds: n.childrenIds)
        }

        // 反向 trace mainPathIds + 找 rootId
        var mainPathIds = Set<String>()
        var rootId: String? = nil
        var traceId: String? = currentNodeId
        while let nid = traceId, let info = infoMap[nid] {
            mainPathIds.insert(nid)
            if info.parentId == nil || infoMap[info.parentId ?? ""] == nil {
                rootId = nid
            }
            traceId = info.parentId
        }
        if rootId == nil {
            let candidates = infoMap.compactMap { (k, v) -> String? in
                (v.parentId == nil || infoMap[v.parentId ?? ""] == nil) ? k : nil
            }
            rootId = candidates.min()
        }

        // effective children（过滤掉 fetch 不到的孩子）
        var effectiveChildren: [String: [String]] = [:]
        effectiveChildren.reserveCapacity(infoMap.count)
        for (nid, info) in infoMap {
            effectiveChildren[nid] = info.childrenIds.filter { infoMap[$0] != nil }
        }
        for (nid, info) in infoMap {
            if let pid = info.parentId, infoMap[pid] != nil {
                if !(effectiveChildren[pid]?.contains(nid) ?? false) {
                    effectiveChildren[pid, default: []].append(nid)
                }
            }
        }

        // 正向走主线，分叉时选 mainPathIds 里的 child
        var pathNodeIds = Set<String>()
        if let rootId = rootId {
            var visited = Set<String>()
            var currentId: String? = rootId
            while let nid = currentId, let info = infoMap[nid], !visited.contains(nid) {
                visited.insert(nid)
                let isDisplayable = (info.role == "user" || info.role == "assistant") && info.hasContent && !info.isTrashed
                let children = effectiveChildren[nid] ?? []
                if isDisplayable {
                    pathNodeIds.insert(nid)
                }
                if children.isEmpty {
                    break
                } else if children.count == 1 {
                    currentId = children[0]
                } else {
                    let mainChild = children.first(where: { mainPathIds.contains($0) })
                    currentId = mainChild ?? children[0]
                }
            }
        }
        return pathNodeIds
    }

    /// Heavy lifting on background thread: fetch nodes, build tree, compute path (all with pure IDs)
    private static func buildTreeInBackground(convId: String, profileId: String, currentNodeId: String, container: ModelContainer) -> TreeData {
        let bgContext = ModelContext(container)

        // Fetch all nodes for this conversation
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in node.conversationId == convId && node.profileId == profileId }
        )
        let nodes = (try? bgContext.fetch(descriptor)) ?? []

        // Lightweight node data for pure computation
        struct NodeInfo {
            let id: String
            let role: String
            let hasContent: Bool
            let isTrashed: Bool
            let parentId: String?
            let childrenIds: [String]
        }

        var infoMap: [String: NodeInfo] = [:]
        infoMap.reserveCapacity(nodes.count)
        for node in nodes {
            infoMap[node.id] = NodeInfo(id: node.id, role: node.role, hasContent: !node.content.isEmpty, isTrashed: node.isTrashed, parentId: node.parentId, childrenIds: node.childrenIds)
        }

        // Chase missing ancestors on background context
        var missingIds = Set<String>()
        for info in infoMap.values {
            if let pid = info.parentId, !pid.isEmpty, infoMap[pid] == nil {
                missingIds.insert(pid)
            }
        }
        var toChase = missingIds
        while !toChase.isEmpty {
            var nextChase = Set<String>()
            for mid in toChase {
                let targetId = mid
                let targetProfileId = profileId
                let desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { node in node.id == targetId && node.profileId == targetProfileId }
                )
                if let found = try? bgContext.fetch(desc).first {
                    infoMap[found.id] = NodeInfo(id: found.id, role: found.role, hasContent: !found.content.isEmpty, isTrashed: found.isTrashed, parentId: found.parentId, childrenIds: found.childrenIds)
                    if let pid = found.parentId, !pid.isEmpty, infoMap[pid] == nil {
                        nextChase.insert(pid)
                    }
                }
            }
            toChase = nextChase
        }

        // Build effective children map
        var effectiveChildren: [String: [String]] = [:]
        effectiveChildren.reserveCapacity(infoMap.count)
        for (nodeId, info) in infoMap {
            effectiveChildren[nodeId] = info.childrenIds.filter { infoMap[$0] != nil }
        }
        for (nodeId, info) in infoMap {
            if let pid = info.parentId, infoMap[pid] != nil {
                if !(effectiveChildren[pid]?.contains(nodeId) ?? false) {
                    effectiveChildren[pid, default: []].append(nodeId)
                }
            }
        }

        // Trace main path from currentNodeId to root — 一次循环既建 mainPathIds 又确定 rootId
        //
        // 之前用 `infoMap.values.first(where:)` 选 root 是 bug：Swift dict 迭代顺序
        // 非确定性，多个 parentId==nil 候选（真 root + 孤立 system/tool 节点等）时每次
        // 可能选到不同节点，导致同一对话 pathNodeIds 随机返回 0 或 N（"抽盲盒"式空白）。
        // 详见 docs/research-conversation-blank-bug.md。
        var mainPathIds = Set<String>()
        var rootId: String? = nil
        var traceId: String? = currentNodeId
        while let nid = traceId, let info = infoMap[nid] {
            mainPathIds.insert(nid)
            if info.parentId == nil || infoMap[info.parentId ?? ""] == nil {
                rootId = nid   // 最顶层的可达祖先
            }
            traceId = info.parentId
        }

        // Fallback：currentNodeId 不在 infoMap（脏数据/stale currentNodeId）时，
        // 按 id 字典序选 parentId==nil 的最小者 — 至少保证确定性
        if rootId == nil {
            let candidates = infoMap.values.filter { $0.parentId == nil || infoMap[$0.parentId ?? ""] == nil }
            rootId = candidates.map(\.id).min()
        }

        // Build display path (collect node IDs + bubbled branches)
        var pathNodeIds: [String] = []
        var bubbledBranches: [String: String] = [:]

        if let rootId = rootId {
            var visited = Set<String>()
            var currentId: String? = rootId
            var lastDisplayedId: String? = nil

            while let nid = currentId, let info = infoMap[nid], !visited.contains(nid) {
                visited.insert(nid)
                let isDisplayable = (info.role == "user" || info.role == "assistant") && info.hasContent && !info.isTrashed
                let children = effectiveChildren[nid] ?? []

                if isDisplayable {
                    pathNodeIds.append(nid)
                    lastDisplayedId = nid
                }
                if children.count > 1 && !isDisplayable {
                    if let lastId = lastDisplayedId {
                        bubbledBranches[lastId] = nid
                    }
                }
                if children.isEmpty {
                    break
                } else if children.count == 1 {
                    currentId = children[0]
                } else {
                    let mainChild = children.first(where: { mainPathIds.contains($0) })
                    currentId = mainChild ?? children[0]
                }
            }
        }

        let displayableCount = infoMap.values.filter {
            ($0.role == "user" || $0.role == "assistant") && $0.hasContent && !$0.isTrashed
        }.count

        return TreeData(
            effectiveChildrenMap: effectiveChildren,
            rootId: rootId,
            mainPathIds: mainPathIds,
            pathNodeIds: pathNodeIds,
            bubbledBranches: bubbledBranches,
            displayableCount: displayableCount,
            allNodeIds: Set(infoMap.keys)
        )
    }

    /// Apply background results on main thread (re-fetch managed objects for UI)
    private func applyTreeData(_ data: TreeData, conversation: Conversation, context: ModelContext) {
        let convId = conversation.id
        let convProfileId = conversation.profileId

        // Re-fetch on main context (fast — SQLite page cache hit)
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in node.conversationId == convId && node.profileId == convProfileId }
        )
        if let nodes = try? context.fetch(descriptor) {
            nodeMap.reserveCapacity(nodes.count)
            for node in nodes { nodeMap[node.id] = node }
        }

        // Fetch ancestor nodes not in this conversation
        for nodeId in data.allNodeIds where nodeMap[nodeId] == nil {
            let nid = nodeId
            let nidProfileId = convProfileId
            let desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in node.id == nid && node.profileId == nidProfileId }
            )
            if let node = try? context.fetch(desc).first {
                nodeMap[node.id] = node
            }
        }

        // Apply pre-computed structures
        effectiveChildrenMap = data.effectiveChildrenMap
        cachedRootId = data.rootId
        mainPathIds = data.mainPathIds
        bubbledBranches = data.bubbledBranches
        let prevCount = currentPath.count
        currentPath = data.pathNodeIds.compactMap { nodeMap[$0] }
        // 换了一条对话（长度骤变）就收回渲染窗口；同一对话追加消息时保持窗口，免得视野跳。
        // 起点越界（新路径比旧起点还短）也收，否则 visiblePath 退化成整条全画
        if abs(currentPath.count - prevCount) > 5 || renderStart >= currentPath.count { resetRenderWindow() }

        // Build branchInfoMap (needs actual MessageNode objects)
        branchInfoMap.removeAll()
        for node in currentPath {
            if let bid = branchNodeId(for: node.id) {
                branchInfoMap[node.id] = BranchInfo(
                    displayedNodeId: node.id,
                    branchNodeId: bid,
                    branchCount: childrenIds(for: bid).count,
                    branchChildren: branchChildren(for: node.id)
                )
            }
        }

        conversation.nodeCount = data.displayableCount
        isLoading = false

        // 路径已就绪 → 把等着的 CC 消息补插进来（它们当时因为拿不到 parent 而排队，
        // 见 appendCCMessage 的 guard；不排队的话会造新根把历史绕过去）
        if !pendingCCMessages.isEmpty {
            let queued = pendingCCMessages
            pendingCCMessages.removeAll()
            for item in queued where item.chatId == conversation.id {
                appendCCMessage(chatId: item.chatId, content: item.content, contentType: item.contentType, context: context)
            }
        }
        refreshBranchOffMainCount()

        // Fire pending scroll after tree is loaded — must be next runloop turn
        // so ScrollView exists before onChange sees the value change
        if let pending = pendingScrollNodeId {
            pendingScrollNodeId = nil
            DispatchQueue.main.async { [self] in
                scrollToNodeId = pending
                highlightedNodeId = pending
                // Clear highlight after 3s
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                    if highlightedNodeId == pending { highlightedNodeId = nil }
                }
            }
        }
    }

    /// Fetch ancestor nodes missing from nodeMap — query only the missing IDs
    private func chaseMissingAncestors(context: ModelContext) {
        var missingIds = Set<String>()
        for node in nodeMap.values {
            if let pid = node.parentId, !pid.isEmpty, nodeMap[pid] == nil {
                missingIds.insert(pid)
            }
        }

        guard !missingIds.isEmpty else { return }
        let profileId = selectedConversation?.profileId ?? ""

        // Chase ancestors by querying only the specific missing IDs
        var toChase = missingIds
        while !toChase.isEmpty {
            var nextChase = Set<String>()
            for mid in toChase {
                let targetId = mid
                let targetProfileId = profileId
                let desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { node in node.id == targetId && node.profileId == targetProfileId }
                )
                if let found = try? context.fetch(desc).first {
                    nodeMap[found.id] = found
                    if let pid = found.parentId, !pid.isEmpty, nodeMap[pid] == nil {
                        nextChase.insert(pid)
                    }
                }
            }
            toChase = nextChase
        }
    }

    /// Build effective children map from actual parent→child relationships
    func buildEffectiveChildrenMap() {
        effectiveChildrenMap.removeAll()
        effectiveChildrenMap.reserveCapacity(nodeMap.count)

        // Start with original childrenIds filtered to existing nodes
        for (nodeId, node) in nodeMap {
            effectiveChildrenMap[nodeId] = node.childrenIds.filter { nodeMap[$0] != nil }
        }

        // Add children discovered via parentId (fixes branch conversations)
        for (nodeId, node) in nodeMap {
            if let pid = node.parentId, nodeMap[pid] != nil {
                if !(effectiveChildrenMap[pid]?.contains(nodeId) ?? false) {
                    effectiveChildrenMap[pid, default: []].append(nodeId)
                }
            }
        }
    }

    /// Get children IDs for a node
    private func childrenIds(for nodeId: String) -> [String] {
        effectiveChildrenMap[nodeId] ?? []
    }

    /// 确定性：按 id 字典序选 parentId==nil（或 parent 不在 nodeMap）的最小者
    /// 避免 dict 迭代顺序非确定性导致 export 时选错 root
    func findRootId() -> String? {
        let candidates = nodeMap.values.filter { $0.parentId == nil || nodeMap[$0.parentId ?? ""] == nil }
        return candidates.map(\.id).min()
    }
}

// MARK: - Path Building

extension ConversationViewModel {

    func rebuildPath() {
        currentPath.removeAll()
        bubbledBranches.removeAll()

        guard let rootId = cachedRootId ?? findRootId() else { return }

        var visited = Set<String>()
        var currentId: String? = rootId
        var lastDisplayedNodeId: String? = nil

        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)

            let isDisplayable = (node.role == "user" || node.role == "assistant") && !node.content.isEmpty && !node.isTrashed
            let children = effectiveChildrenMap[nid] ?? []

            if isDisplayable {
                currentPath.append(node)
                lastDisplayedNodeId = nid
            }

            if children.count > 1 && !isDisplayable {
                if let lastId = lastDisplayedNodeId {
                    bubbledBranches[lastId] = nid
                }
            }

            if children.isEmpty {
                break
            } else if children.count == 1 {
                currentId = children[0]
            } else {
                if let chosenIndex = branchChoices[nid], chosenIndex < children.count {
                    currentId = children[chosenIndex]
                } else {
                    let mainChild = children.first(where: { mainPathIds.contains($0) })
                    currentId = mainChild ?? children[0]
                }
            }
        }

        // Precompute branch info to avoid redundant lookups during rendering
        branchInfoMap.removeAll()
        for node in currentPath {
            if let bid = branchNodeId(for: node.id) {
                branchInfoMap[node.id] = BranchInfo(
                    displayedNodeId: node.id,
                    branchNodeId: bid,
                    branchCount: effectiveChildrenMap[bid]?.count ?? 0,
                    branchChildren: branchChildren(for: node.id)
                )
            }
        }
        refreshBranchOffMainCount()
    }
}

// MARK: - Branch Navigation

extension ConversationViewModel {

    func switchBranch(at nodeId: String, to childIndex: Int) {
        branchChoices[nodeId] = childIndex
        rebuildPath()
    }

    func branchNodeId(for displayedNodeId: String) -> String? {
        if (effectiveChildrenMap[displayedNodeId]?.count ?? 0) > 1 {
            return displayedNodeId
        }
        return bubbledBranches[displayedNodeId]
    }

    func hasBranches(for displayedNodeId: String) -> Bool {
        return branchNodeId(for: displayedNodeId) != nil
    }

    func branchCount(for displayedNodeId: String) -> Int {
        guard let bid = branchNodeId(for: displayedNodeId) else { return 0 }
        return effectiveChildrenMap[bid]?.count ?? 0
    }

    /// "你在哪"位置 hint — 给 BranchMapSheet v2 mini-map 标当前位置用。
    /// 直接读 highlightedNodeId（最近交互过的 node：搜索点击 / pin 跳转 / branch 切换都会设）。
    /// 3s 后会被清空，sheet 打开时如果是 nil 就不画位置 marker（视觉降级，不出 false 信息）。
    /// 详见 docs/plan-branch-map-v2-minimap.md Q1。
    var currentPositionHint: String? { highlightedNodeId }

    /// 给定 child nodeId（某条 branch 的入口），顺向走到 leaf 数 displayable node 数。
    /// 分叉时优先选 mainPathIds 里的 child，跟 buildTreeInBackground 一致。
    /// 用于分支地图显示"分支 N 共 X 条"。B20 part 2 A3 反馈。
    func branchLength(fromChildId childId: String) -> Int {
        var count = 0
        var visited = Set<String>()
        var currentId: String? = childId
        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)
            let isDisplayable = (node.role == "user" || node.role == "assistant") && !node.content.isEmpty && !node.isTrashed
            if isDisplayable { count += 1 }
            let children = effectiveChildrenMap[nid] ?? []
            if children.isEmpty {
                break
            } else if children.count == 1 {
                currentId = children[0]
            } else {
                let mainChild = children.first(where: { mainPathIds.contains($0) })
                currentId = mainChild ?? children[0]
            }
        }
        return count
    }

    /// 给 collectAllBranches 用：找 anchor 在主线上能定位的"显示位置"。
    /// anchor 可能是 invisible system/tool 节点（在 mainPathIds 但不在 currentPath），
    /// 此时 currentPath.firstIndex 返回 nil。改沿 parent 链回溯，找最近的
    /// displayable + 在 currentPath 的 ancestor，取它的 index。
    private func nearestDisplayedIndexInPath(of nodeId: String) -> Int? {
        var current: String? = nodeId
        var visited = Set<String>()
        while let nid = current, !visited.contains(nid), let node = nodeMap[nid] {
            visited.insert(nid)
            if let idx = currentPath.firstIndex(where: { $0.id == nid }) {
                return idx
            }
            current = node.parentId
        }
        return nil
    }

    func collectAllBranches() -> [AllBranchEntry] {
        guard let rootId = cachedRootId, nodeMap[rootId] != nil else { return [] }

        var out: [AllBranchEntry] = []
        // DFS：(nodeId, depth, mainAnchorAncestor, mainAnchorLocation, parentBranchEntryId)
        // parentBranchEntryId：进入分支 child 后，该 child 下游所有嵌套 entry 的父
        var stack: [(String, Int, String?, Int, String?)] = [(rootId, 0, nil, -1, nil)]
        var visited = Set<String>()

        while let (nid, depth, mainAnchor, mainLoc, parentEntryId) = stack.popLast() {
            if visited.contains(nid) { continue }
            visited.insert(nid)
            let children = effectiveChildrenMap[nid] ?? []

            if children.count >= 2 {
                // anchor — 选 mainPathIds 里的 child（主选），其余都是分支
                let chosenChild = children.first(where: { mainPathIds.contains($0) }) ?? children[0]
                let anchorOnMain = mainPathIds.contains(nid)
                let anchorLocation: Int = {
                    if anchorOnMain {
                        // invisible branch（system 节点 anchor）不在 currentPath
                        // → 往 parent 链找最近的 displayed ancestor 的位置
                        return nearestDisplayedIndexInPath(of: nid) ?? mainLoc
                    }
                    return mainLoc
                }()
                let nextMainAnchor: String? = anchorOnMain ? nid : mainAnchor

                for (idx, childId) in children.enumerated() {
                    if childId == chosenChild {
                        // 主选 child 继续往下走找深层分支；parentEntryId 不变（仍属于上层 branch lane）
                        stack.append((childId, depth, nextMainAnchor, anchorLocation, parentEntryId))
                        continue
                    }
                    // 分支 child：记录一条分支 entry
                    guard let preview = firstDisplayableDescendant(from: childId) else {
                        // 无 displayable 后代，跳过；下游嵌套不会有合法 preview，但还是要透传 parent
                        stack.append((childId, depth + 1, nextMainAnchor, anchorLocation, parentEntryId))
                        continue
                    }
                    let entryId = "\(nid):\(idx)"
                    out.append(AllBranchEntry(
                        id: entryId,
                        anchorNodeId: nid,
                        childIndex: idx,
                        childPreviewNode: preview,
                        depth: anchorOnMain ? 0 : depth,
                        parentAnchorOnMain: nextMainAnchor,
                        parentBranchEntryId: parentEntryId,
                        length: branchLength(fromChildId: childId),
                        location: anchorLocation
                    ))
                    // 进入这条分支继续找子分支：下游嵌套的父 = 本 entry
                    stack.append((childId, depth + 1, nextMainAnchor, anchorLocation, entryId))
                }
            } else {
                for childId in children {
                    stack.append((childId, depth, mainAnchor, mainLoc, parentEntryId))
                }
            }
        }

        // 按主线位置排序；同位置按 depth 升序（一级在嵌套之前）
        out.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.depth < rhs.depth
        }
        return out
    }

    func branchChildren(for nodeId: String) -> [(index: Int, node: MessageNode, isMainPath: Bool)] {
        let actualId = bubbledBranches[nodeId] ?? nodeId
        let children = effectiveChildrenMap[actualId] ?? []
        return children.enumerated().compactMap { (idx, childId) in
            let previewNode = firstDisplayableDescendant(from: childId)
            guard let preview = previewNode else { return nil }
            return (index: idx, node: preview, isMainPath: mainPathIds.contains(childId))
        }
    }

    private func firstDisplayableDescendant(from nodeId: String) -> MessageNode? {
        var visited = Set<String>()
        var current: String? = nodeId
        while let nid = current, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)
            if (node.role == "user" || node.role == "assistant") && !node.content.isEmpty && !node.isTrashed {
                return node
            }
            current = (effectiveChildrenMap[nid] ?? []).first
        }
        return nil
    }
}
