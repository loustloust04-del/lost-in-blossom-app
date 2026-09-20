import Foundation
import SwiftData

// MARK: - Export Path Mode

enum ExportPathMode: String {
    case longest    // Auto-pick longest branch (lightweight default)
    case current    // Currently displayed path
    case mainPath   // Main path (currentNodeId → root)
    case fullTree   // All branches, non-longest wrapped in <details>
}

// MARK: - Markdown Exporter

enum MarkdownExporter {

    // MARK: - Single Export (ViewModel has data loaded)

    /// Export using pre-loaded conversation data from ViewModel
    static func export(
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]],
        rootId: String,
        mainPathIds: Set<String>,
        currentPath: [MessageNode],
        mode: ExportPathMode,
        userName: String,
        assistantName: String
    ) -> String {
        let nodes: [MessageNode]

        switch mode {
        case .longest:
            nodes = longestPath(from: rootId, nodeMap: nodeMap, effectiveChildren: effectiveChildren)
        case .current:
            nodes = currentPath
        case .mainPath:
            nodes = buildMainPath(from: rootId, nodeMap: nodeMap, effectiveChildren: effectiveChildren, mainPathIds: mainPathIds)
        case .fullTree:
            let lines = formatFullTree(
                from: rootId,
                nodeMap: nodeMap,
                effectiveChildren: effectiveChildren,
                userName: userName,
                assistantName: assistantName
            )
            return lines.joined(separator: "\n")
        }

        return formatPath(nodes, userName: userName, assistantName: assistantName)
            .joined(separator: "\n")
    }

    // MARK: - Batch Export (loads nodes from context)

    /// Export a single conversation by loading its nodes from ModelContext
    static func loadAndExport(
        conversation: Conversation,
        context: ModelContext,
        mode: ExportPathMode,
        userName: String,
        assistantName: String
    ) -> String {
        let convId = conversation.id
        let convProfileId = conversation.profileId

        // Fetch all nodes for this conversation
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.conversationId == convId && node.profileId == convProfileId
            }
        )
        guard let allNodes = try? context.fetch(descriptor) else { return "" }

        var nodeMap: [String: MessageNode] = [:]
        nodeMap.reserveCapacity(allNodes.count)
        for node in allNodes {
            nodeMap[node.id] = node
        }

        // Chase missing ancestors
        chaseMissingAncestors(nodeMap: &nodeMap, profileId: convProfileId, context: context)

        // Build effective children map
        let effectiveChildren = buildEffectiveChildrenMap(nodeMap: nodeMap)

        // Find root
        let rootId = nodeMap.values.first(where: { $0.parentId == nil })?.id
            ?? nodeMap.values.first(where: { nodeMap[$0.parentId ?? ""] == nil })?.id
        guard let rootId else { return "" }

        // Build main path IDs
        var mainPathIds = Set<String>()
        var traceId: String? = conversation.currentNodeId
        while let nid = traceId, let node = nodeMap[nid] {
            mainPathIds.insert(nid)
            traceId = node.parentId
        }

        // For batch, current path = main path (conversation may not be displayed)
        let mainPath = buildMainPath(from: rootId, nodeMap: nodeMap, effectiveChildren: effectiveChildren, mainPathIds: mainPathIds)

        // Use longest for lightweight, or the requested mode
        let effectiveMode = mode == .current ? .mainPath : mode

        return export(
            nodeMap: nodeMap,
            effectiveChildren: effectiveChildren,
            rootId: rootId,
            mainPathIds: mainPathIds,
            currentPath: mainPath,
            mode: effectiveMode,
            userName: userName,
            assistantName: assistantName
        )
    }

    // MARK: - Longest Path

    /// Find the longest path through the tree by always picking the deepest subtree
    private static func longestPath(
        from rootId: String,
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]]
    ) -> [MessageNode] {
        // Compute subtree depth iteratively (post-order) to avoid stack overflow
        var depthCache: [String: Int] = [:]
        var stack: [(nodeId: String, childIndex: Int)] = []

        for startId in nodeMap.keys where depthCache[startId] == nil {
            stack.append((startId, 0))
            while !stack.isEmpty {
                let (nid, ci) = stack.last!
                let children = effectiveChildren[nid] ?? []
                if ci < children.count {
                    stack[stack.count - 1].childIndex = ci + 1
                    let childId = children[ci]
                    if depthCache[childId] == nil {
                        stack.append((childId, 0))
                    }
                } else {
                    stack.removeLast()
                    let d = children.isEmpty ? 0 : (children.compactMap { depthCache[$0] }.max() ?? 0) + 1
                    depthCache[nid] = d
                }
            }
        }

        // Walk from root, always picking child with max depth
        var path: [MessageNode] = []
        var currentId: String? = rootId
        var visited = Set<String>()

        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)

            if isDisplayable(node) {
                path.append(node)
            }

            let children = effectiveChildren[nid] ?? []
            if children.isEmpty {
                break
            } else if children.count == 1 {
                currentId = children[0]
            } else {
                currentId = children.max(by: { (depthCache[$0] ?? 0) < (depthCache[$1] ?? 0) })
            }
        }

        return path
    }

    // MARK: - Main Path

    /// Build path following mainPathIds at branch points
    private static func buildMainPath(
        from rootId: String,
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]],
        mainPathIds: Set<String>
    ) -> [MessageNode] {
        var path: [MessageNode] = []
        var currentId: String? = rootId
        var visited = Set<String>()

        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)

            if isDisplayable(node) {
                path.append(node)
            }

            let children = effectiveChildren[nid] ?? []
            if children.isEmpty {
                break
            } else if children.count == 1 {
                currentId = children[0]
            } else {
                currentId = children.first(where: { mainPathIds.contains($0) }) ?? children[0]
            }
        }

        return path
    }

    // MARK: - Full Tree (with <details> folding)

    /// DFS the entire tree, outputting longest branch inline and others in <details>
    private static func formatFullTree(
        from rootId: String,
        nodeMap: [String: MessageNode],
        effectiveChildren: [String: [String]],
        userName: String,
        assistantName: String
    ) -> [String] {
        // Precompute subtree depths
        var depthCache: [String: Int] = [:]

        func depth(of nodeId: String) -> Int {
            if let cached = depthCache[nodeId] { return cached }
            let children = effectiveChildren[nodeId] ?? []
            let d = children.isEmpty ? 0 : (children.map { depth(of: $0) }.max() ?? 0) + 1
            depthCache[nodeId] = d
            return d
        }

        for nodeId in nodeMap.keys { _ = depth(of: nodeId) }

        var lines: [String] = []

        func walk(_ nodeId: String, visited: inout Set<String>) {
            guard let node = nodeMap[nodeId], !visited.contains(nodeId) else { return }
            visited.insert(nodeId)

            // Output this node if displayable
            if isDisplayable(node) {
                let name = node.role == "user" ? userName : assistantName
                let time = formatTime(node.createTime)
                lines.append("# \(name) · \(time)")
                lines.append("")
                let cleaned = ContentCleaner.clean(node.content, cacheKey: nil)
                lines.append(shiftHeadings(cleaned))
                lines.append("")
            }

            let children = effectiveChildren[nodeId] ?? []
            if children.count <= 1 {
                // No branching — continue straight
                if let child = children.first {
                    walk(child, visited: &visited)
                }
            } else {
                // Branch point: find longest child, output inline; others in <details>
                let sorted = children.sorted { depth(of: $0) > depth(of: $1) }
                let longestChild = sorted[0]
                let otherChildren = Array(sorted.dropFirst())

                // Longest branch continues inline
                walk(longestChild, visited: &visited)

                // Other branches in <details>
                if !otherChildren.isEmpty {
                    lines.append("<details>")
                    let count = otherChildren.count
                    lines.append("<summary>\(count == 1 ? "另外 1 条分支" : "另外 \(count) 条分支")</summary>")
                    lines.append("")

                    for (i, childId) in otherChildren.enumerated() {
                        var branchVisited = visited
                        walk(childId, visited: &branchVisited)
                        // Merge visited to prevent re-visiting shared nodes
                        visited.formUnion(branchVisited)
                        if i < otherChildren.count - 1 {
                            lines.append("---")
                            lines.append("")
                        }
                    }

                    lines.append("</details>")
                    lines.append("")
                }
            }
        }

        var visited = Set<String>()
        walk(rootId, visited: &visited)
        return lines
    }

    // MARK: - Formatting Helpers

    /// Format a linear path of nodes into markdown lines
    private static func formatPath(_ path: [MessageNode], userName: String, assistantName: String) -> [String] {
        var lines: [String] = []
        for node in path {
            let name = node.role == "user" ? userName : assistantName
            let time = formatTime(node.createTime)
            lines.append("# \(name) · \(time)")
            lines.append("")
            let cleaned = ContentCleaner.clean(node.content, cacheKey: nil)
            lines.append(shiftHeadings(cleaned))
            lines.append("")
        }
        return lines
    }

    /// Shift all markdown headings down one level (# → ##, ## → ###, etc.)
    private static func shiftHeadings(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let s = String(line)
                if s.hasPrefix("#") {
                    return "#" + s
                }
                return s
            }
            .joined(separator: "\n")
    }

    /// Format timestamp as "2026-0224-09:40"
    private static func formatTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MMdd-HH:mm"
        return formatter.string(from: date)
    }

    /// Check if a node should be included in export
    private static func isDisplayable(_ node: MessageNode) -> Bool {
        (node.role == "user" || node.role == "assistant") && !node.content.isEmpty && !node.isTrashed
    }

    // MARK: - Node Loading Helpers (for batch export)

    /// Chase missing ancestor nodes — query only the specific missing IDs
    private static func chaseMissingAncestors(nodeMap: inout [String: MessageNode], profileId: String, context: ModelContext) {
        var missingIds = Set<String>()
        for node in nodeMap.values {
            if let pid = node.parentId, !pid.isEmpty, nodeMap[pid] == nil {
                missingIds.insert(pid)
            }
        }

        guard !missingIds.isEmpty else { return }

        var toChase = missingIds
        let targetProfileId = profileId
        while !toChase.isEmpty {
            var nextChase = Set<String>()
            for mid in toChase {
                let targetId = mid
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

    /// Build effective children map (same logic as ViewModel)
    private static func buildEffectiveChildrenMap(nodeMap: [String: MessageNode]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        map.reserveCapacity(nodeMap.count)

        for (nodeId, node) in nodeMap {
            map[nodeId] = node.childrenIds.filter { nodeMap[$0] != nil }
        }

        for (nodeId, node) in nodeMap {
            if let pid = node.parentId, nodeMap[pid] != nil {
                if !(map[pid]?.contains(nodeId) ?? false) {
                    map[pid, default: []].append(nodeId)
                }
            }
        }

        return map
    }

    // MARK: - File Name Helper

    /// Sanitize conversation title for use as filename
    static func sanitizedFileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmed = String(cleaned.prefix(100))
        return trimmed.isEmpty ? "untitled" : trimmed
    }
}
