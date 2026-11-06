import Foundation

// MARK: - In-Conversation Search（10-05 对照粟粟 chat-find 九刀升级）

extension ConversationViewModel {

    /// 搜看得见的字（剥思考链 / 捎带段），多词空格分开 = 都要有；结果从**最新**那条开始
    func searchInConversation(keyword: String) {
        inConvSearchKeyword = keyword
        let words = keyword.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else {
            inConvMatches = []
            inConvMatchIndex = -1
            return
        }
        let hits = currentPath.filter { node in
            guard node.role == "user" || node.role == "assistant", !node.isTrashed else { return false }
            let text = ContentCleaner.visibleText(node.content, isUser: node.role == "user", cacheKey: node.id)
            return words.allSatisfy { text.localizedStandardContains($0) }
        }.map(\.id)
        inConvMatches = Array(hits.reversed())          // [0] = 最新的命中
        inConvMatchIndex = inConvMatches.isEmpty ? -1 : 0
        if let firstId = inConvMatches.first { jumpToMatch(firstId) }
    }

    /// direction：+1 = 往更早（↑），-1 = 往更新（↓）
    func navigateInConvMatch(direction: Int) {
        guard !inConvMatches.isEmpty else { return }
        inConvMatchIndex = (inConvMatchIndex + direction + inConvMatches.count) % inConvMatches.count
        jumpToMatch(inConvMatches[inConvMatchIndex])
    }

    /// 跳过去 + 闪一下
    func jumpToMatch(_ nodeId: String) {
        if let i = inConvMatches.firstIndex(of: nodeId) { inConvMatchIndex = i }
        scrollToNodeId = nodeId
        highlightedNodeId = nodeId
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
            if highlightedNodeId == nodeId { highlightedNodeId = nil }
        }
    }

    /// 日历跳到某天：那天的第一条（没有就之后最近的一条）
    func jumpToDay(_ day: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let n = currentPath.first(where: { ($0.createTime ?? .distantPast) >= start && ($0.role == "user" || $0.role == "assistant") }) else { return }
        scrollToNodeId = n.id
        highlightedNodeId = n.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
            if highlightedNodeId == n.id { highlightedNodeId = nil }
        }
    }

    func clearInConvSearch() {
        inConvSearchKeyword = ""
        inConvMatches = []
        inConvMatchIndex = -1
    }
}
