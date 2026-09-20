import Foundation
import SwiftData

/// recall 工具（SC-B1）：模型翻自己的历史——L0 对话原文检索，返回原话窗口（命中 ±1 主线邻居）。
/// 纯检索不写库；access 计数由调用方（CV 分发分支）用返回值记。
/// 设计：docs/research-recall-tool.md / docs/plan-recall-tool.md
enum RecallTool {
    static let toolName = "recall"

    /// 开关 = 设置页「记忆内容」的"对话历史搜索"行（灰占位点亮，key 沿用）。
    /// 默认开（已批）；关 = 不下发工具，行为回纯现状
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_content_convhistory") as? Bool) ?? true
    }

    // 防刷屏（research 决策 5：地板/上限/截断，宁缺勿滥）
    static let maxWindowsPerConversation = 2
    static let maxL0Windows = 4
    static let maxL1Hits = 4
    static let snippetLimit = 300
    static let totalTextLimit = 4000
    /// 单 turn 调用熔断（粟粟实测：宽查询连环翻页 5+ 次爆上下文），CV 分发处计数
    static let maxCallsPerTurn = 3

    // MARK: - 工具定义（双格式，FileLibraryTools 同款模式）

    // 检索契约（obelisk Retrieval Contract 浓缩，2026-06-13）：窄定位优先/证据先行/记忆非权威/结论提议存档
    private static let toolDescription = """
    回忆对话历史（我们说过的话），逐字搜索并返回原话片段及上下文。找文件库笔记请用 fs_search。\
    一次查清：用最可能命中的关键词查询，不要翻页式反复调用（每轮最多 \(maxCallsPerTurn) 次）。\
    查询范围太宽（如"昨天说的话"）时不要穷举——先和用户确认具体主题再查。\
    结果带 conv id，可用 conversation_id 在单场对话里继续深挖；已知 conv id 时直接限定它查，别再全库广搜。\
    引用回忆要带出处（日期/原话），别凭印象转述；【记忆】段是先前的笔记不是最终事实，关键处以【对话原文】为准。\
    查到值得长期记住的结论时，先问用户要不要存进记忆树，同意了再写。
    """

    private static let properties: [String: Any] = [
        "query": ["type": "string", "description": "要回忆的关键词或原话片段"],
        "exact": ["type": "boolean", "description": "true=只逐字找对话原文"],
        "after": ["type": "string", "description": "只看这天之后，YYYY-MM-DD"],
        "before": ["type": "string", "description": "只看这天之前，YYYY-MM-DD"],
        "conversation_id": ["type": "string", "description": "只在这场对话里找（用之前结果里的 conv id 全量或前缀均可）"],
    ]
    private static let required = ["query"]

    static func openAITool() -> [String: Any] {
        ["type": "function", "function": [
            "name": toolName, "description": toolDescription,
            "parameters": ["type": "object", "properties": properties, "required": required]
        ]]
    }

    static func anthropicTool() -> [String: Any] {
        ["name": toolName, "description": toolDescription,
         "input_schema": ["type": "object", "properties": properties, "required": required]]
    }

    // MARK: - 执行

    struct ExecResult {
        let text: String
        let isError: Bool
        let hitMemoryIds: [UUID]
    }

    static func execute(
        inputJSON: String,
        profileId: String,
        userName: String,
        assistantName: String,
        container: ModelContainer
    ) async -> ExecResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ExecResult(text: "recall 缺少 query 参数", isError: true, hitMemoryIds: [])
        }
        let exact = args["exact"] as? Bool ?? false
        let after = parseDay(args["after"] as? String)
        let beforeExclusive = parseDay(args["before"] as? String, endOfDay: true)
        let convIdArg = (args["conversation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let convId = (convIdArg?.isEmpty == false) ? convIdArg : nil

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                context.autosaveEnabled = false

                // 越层防护：conversation_id 必须属于当前楼层（支持结果里给的前 8 位前缀）
                var resolvedConvId: String? = nil
                if let convId {
                    guard let resolved = resolveConversation(idOrPrefix: convId, profileId: profileId, context: context) else {
                        continuation.resume(returning: ExecResult(
                            text: "没有找到这场对话（id 不存在或不属于当前楼层）。", isError: true, hitMemoryIds: []))
                        return
                    }
                    resolvedConvId = resolved
                }

                let windows = searchL0(
                    query: query, profileId: profileId, convId: resolvedConvId,
                    after: after, beforeExclusive: beforeExclusive,
                    userName: userName, assistantName: assistantName, context: context
                )

                // L1 记忆并查：exact=只找原话时跳过；mem_master 关 = 只砍记忆半边，历史照查（已批边界）
                var memoryLines: [String] = []
                var hitIds: [UUID] = []
                if !exact && MemoryFlags.masterEnabled {
                    (memoryLines, hitIds) = searchL1(
                        query: query, profileId: profileId,
                        after: after, beforeExclusive: beforeExclusive, context: context
                    )
                }

                let text = composeResult(memoryLines: memoryLines, windows: windows, totalLimit: totalTextLimit)
                continuation.resume(returning: ExecResult(text: text, isError: false, hitMemoryIds: hitIds))
            }
        }
    }

    // MARK: - L0 原文检索

    /// 关键词在 predicate 层缩集（20 万 node 红线）；时间过滤在 Swift 层
    /// （红线：optional createTime 与 contains 同进 predicate 会静默返回空，SearchService:150 同款教训）。
    private static func fetchHits(query: String, profileId: String, convId: String?, context: ModelContext) -> [MessageNode] {
        let pid = profileId
        let search = query
        let desc: FetchDescriptor<MessageNode>
        if let cid = convId {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid && node.conversationId == cid &&
                    node.isTrashed == false &&
                    (node.role == "user" || node.role == "assistant") &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false &&
                    (node.role == "user" || node.role == "assistant") &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        }
        return (try? context.fetch(desc)) ?? []
    }

    /// conversation_id 解析：全量 id 或结果行里的前 8 位前缀；楼层归属校验
    private static func resolveConversation(idOrPrefix: String, profileId: String, context: ModelContext) -> String? {
        let pid = profileId
        let exact = idOrPrefix
        let exactDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.id == exact && $0.profileId == pid && $0.isTrashed == false }
        )
        if let conv = try? context.fetch(exactDesc).first { return conv.id }
        guard idOrPrefix.count >= 8 else { return nil }
        // 前缀匹配：#Predicate 无 hasPrefix，楼层内未删对话量级小，内存过滤可接受
        let allDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid && $0.isTrashed == false }
        )
        let matches = ((try? context.fetch(allDesc)) ?? []).filter { $0.id.hasPrefix(idOrPrefix) }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func searchL0(
        query: String, profileId: String, convId: String?,
        after: Date?, beforeExclusive: Date?,
        userName: String, assistantName: String, context: ModelContext
    ) -> [String] {
        var hits = fetchHits(query: query, profileId: profileId, convId: convId, context: context)
        if after != nil || beforeExclusive != nil {
            hits = hits.filter { inRange($0.createTime, after: after, beforeExclusive: beforeExclusive) }
        }
        guard !hits.isEmpty else { return [] }

        let pid = profileId
        // 每对话的主线路径缓存（最多 maxL0Windows 个 conv 会真的 fetch）
        var pathCache: [String: (title: String, path: [RecallMessage], indexById: [String: Int])] = [:]
        var deadConvs = Set<String>()
        var perConvCount: [String: Int] = [:]
        var usedNodeIds = Set<String>()
        var windows: [String] = []

        for hit in hits {
            if windows.count >= maxL0Windows { break }
            let cid = hit.conversationId
            if deadConvs.contains(cid) { continue }
            if (perConvCount[cid] ?? 0) >= maxWindowsPerConversation { continue }
            if usedNodeIds.contains(hit.id) { continue }   // 已作为邻居出现过，免重叠窗

            if pathCache[cid] == nil {
                let convDesc = FetchDescriptor<Conversation>(
                    predicate: #Predicate<Conversation> { $0.id == cid && $0.profileId == pid && $0.isTrashed == false }
                )
                guard let conv = try? context.fetch(convDesc).first else { deadConvs.insert(cid); continue }
                let nodesDesc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid && $0.isTrashed == false }
                )
                let allNodes = (try? context.fetch(nodesDesc)) ?? []
                let mainSet = ConversationViewModel.computeMainPathSet(nodes: allNodes, currentNodeId: conv.currentNodeId)
                let ordered = allNodes
                    .filter { mainSet.contains($0.id) && ($0.role == "user" || $0.role == "assistant") }
                    .sorted { ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast) }
                    .map { RecallMessage(id: $0.id, role: $0.role, content: ContentCleaner.clean($0.content, cacheKey: $0.id), date: $0.createTime) }
                var index: [String: Int] = [:]
                for (i, m) in ordered.enumerated() { index[m.id] = i }
                pathCache[cid] = (title: conv.title, path: ordered, indexById: index)
            }
            guard let entry = pathCache[cid], let idx = entry.indexById[hit.id] else { continue }   // 非主线命中跳过

            let header = "[\(dayString(hit.createTime)) · \(entry.title) conv:\(String(cid.prefix(8)))]"
            let text = windowText(
                path: entry.path, hitIndex: idx, header: header, query: query,
                userName: userName, assistantName: assistantName, snippetLimit: snippetLimit
            )
            guard !text.isEmpty else { continue }
            windows.append(text)
            perConvCount[cid, default: 0] += 1
            for i in max(0, idx - 1)...min(entry.path.count - 1, idx + 1) { usedNodeIds.insert(entry.path[i].id) }
        }
        return windows
    }

    // MARK: - L1 记忆并查

    /// M2 双路检索器直调（绕过注入灰开关——recall 是显式调用永远双路），RRF 融合取 top。
    private static func searchL1(
        query: String, profileId: String,
        after: Date?, beforeExclusive: Date?, context: ModelContext
    ) -> (lines: [String], ids: [UUID]) {
        let store = SwiftDataMemoryStore()
        let candidates = store.listHotAndWarm(profileId: profileId, context: context)
        guard !candidates.isEmpty else { return ([], []) }
        let kw = KeywordRetriever().retrieve(candidates, recent: [query])
        let vec = VectorRetriever().retrieve(candidates, recent: [query])
        var fused: [Memory]
        if kw.isEmpty { fused = vec.map(\.memory) }
        else if vec.isEmpty { fused = kw.map(\.memory) }
        else { fused = MemoryInjector.rrfFuse([kw, vec]) }
        if after != nil || beforeExclusive != nil {
            fused = fused.filter { inRange($0.createdAt, after: after, beforeExclusive: beforeExclusive) }
        }
        let top = Array(fused.prefix(maxL1Hits))
        let lines = top.map { m in
            var line = "- [\(dayString(m.createdAt)) · 记忆·\(categoryLabel(m.category))] \(String(m.content.prefix(snippetLimit)))"
            // SC-B2 出处：有 quote 锚的记忆带上原话证据
            if let quote = m.sourceQuote {
                line += "（出处:「\(String(quote.prefix(40)))」）"
            }
            return line
        }
        return (lines, top.map(\.id))
    }

    private static func categoryLabel(_ c: String) -> String {
        ["preference": "偏好", "fact": "事实", "relationship": "关系", "goal": "目标", "context": "情境"][c] ?? c
    }

    // MARK: - 纯函数层（XCTest 直测，不碰 SwiftData）

    struct RecallMessage {
        let id: String
        let role: String      // "user" / "assistant"
        let content: String   // 已 ContentCleaner.clean
        let date: Date?
    }

    /// 命中 ±1 主线邻居拼窗。空内容行跳过；全空返回空串
    static func windowText(
        path: [RecallMessage], hitIndex: Int, header: String, query: String,
        userName: String, assistantName: String, snippetLimit: Int
    ) -> String {
        guard path.indices.contains(hitIndex) else { return "" }
        var lines: [String] = []
        for i in max(0, hitIndex - 1)...min(path.count - 1, hitIndex + 1) {
            let m = path[i]
            let snippet = i == hitIndex
                ? centeredSnippet(m.content, keyword: query, limit: snippetLimit)
                : String(m.content.prefix(snippetLimit)) + (m.content.count > snippetLimit ? "…" : "")
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let speaker = m.role == "user" ? userName : assistantName
            lines.append("\(speaker): \(trimmed)")
        }
        guard !lines.isEmpty else { return "" }
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// 以关键词首次命中处为中心截 limit 字；未命中退化为前缀截断
    static func centeredSnippet(_ text: String, keyword: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let lower = text.lowercased()
        guard let range = lower.range(of: keyword.lowercased()) else {
            return String(text.prefix(limit)) + "…"
        }
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let contextStart = max(0, min(matchStart - limit / 3, text.count - limit))
        let start = text.index(text.startIndex, offsetBy: contextStart)
        let end = text.index(start, offsetBy: min(limit, text.distance(from: start, to: text.endIndex)))
        var snippet = String(text[start..<end])
        if contextStart > 0 { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    /// 结果拼装：头部统计行 + 记忆段 + 原文段；总长截断；全空给"没找到"
    static func composeResult(memoryLines: [String], windows: [String], totalLimit: Int) -> String {
        if memoryLines.isEmpty && windows.isEmpty {
            return "没有找到相关记录。可以换个关键词，或去掉日期限制再试。"
        }
        var parts: [String] = ["（原文 \(windows.count) 窗 · 记忆 \(memoryLines.count) 条）"]
        if !memoryLines.isEmpty {
            parts.append("【相关记忆】\n" + memoryLines.joined(separator: "\n"))
        }
        if !windows.isEmpty {
            parts.append("【对话原文】\n" + windows.joined(separator: "\n\n"))
        }
        let text = parts.joined(separator: "\n\n")
        guard text.count > totalLimit else { return text }
        return String(text.prefix(totalLimit)) + "\n…（结果过长已截断）"
    }

    /// YYYY-MM-DD → Date。endOfDay=true 返回次日零点（exclusive 上界）。
    /// 格式预校验：DateFormatter 对分隔符宽容（"2026/06/12" 也能过），正则先把关
    static func parseDay(_ s: String?, endOfDay: Bool = false) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let day = formatter.date(from: s) else { return nil }
        return endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: day) : day
    }

    static func inRange(_ date: Date?, after: Date?, beforeExclusive: Date?) -> Bool {
        guard let date else { return false }
        if let after, date < after { return false }
        if let beforeExclusive, date >= beforeExclusive { return false }
        return true
    }

    private static func dayString(_ date: Date?) -> String {
        guard let date else { return "????-??-??" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
