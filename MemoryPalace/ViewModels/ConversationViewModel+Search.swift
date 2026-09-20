import Foundation

// MARK: - In-Conversation Search

extension ConversationViewModel {

    func searchInConversation(keyword: String) {
        inConvSearchKeyword = keyword
        guard !keyword.isEmpty else {
            inConvMatches = []
            inConvMatchIndex = -1
            return
        }
        inConvMatches = currentPath.filter { node in
            (node.role == "user" || node.role == "assistant") &&
            node.content.localizedStandardContains(keyword)
        }.map(\.id)
        inConvMatchIndex = inConvMatches.isEmpty ? -1 : 0
        if let firstId = inConvMatches.first {
            scrollToNodeId = firstId
            highlightedNodeId = firstId
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                if highlightedNodeId == firstId { highlightedNodeId = nil }
            }
        }
    }

    func navigateInConvMatch(direction: Int) {
        guard !inConvMatches.isEmpty else { return }
        inConvMatchIndex = (inConvMatchIndex + direction + inConvMatches.count) % inConvMatches.count
        let nodeId = inConvMatches[inConvMatchIndex]
        scrollToNodeId = nodeId
        highlightedNodeId = nodeId
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if highlightedNodeId == nodeId { highlightedNodeId = nil }
        }
    }

    func clearInConvSearch() {
        inConvSearchKeyword = ""
        inConvMatches = []
        inConvMatchIndex = -1
    }
}
