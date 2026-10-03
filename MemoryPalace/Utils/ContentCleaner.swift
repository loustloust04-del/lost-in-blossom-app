import Foundation

/// Cleans ChatGPT's internal annotation markers from message content.
/// ChatGPT uses Unicode Private Use Area characters (U+E200–U+E206) as delimiters
/// for inline citations, entity annotations, navigation lists, etc.
enum ContentCleaner {

    /// Cache cleaned results to avoid repeated regex work on re-renders
    private static let cache = NSCache<NSString, NSString>()

    /// Clean all ChatGPT annotation artifacts from text
    /// - Parameter cached: false = 不读不写缓存（索引回填一次扫几万条，别把缓存冲掉）——粟粟 S5
    static func clean(_ text: String, cacheKey: String? = nil, cached useCache: Bool = true) -> String {
        // Check cache first
        let key = (cacheKey ?? String(text.hashValue)) as NSString
        if useCache, let cached = cache.object(forKey: key) {
            return cached as String
        }

        // Fast path: skip cleaning if no PUA characters or annotation markers present
        let hasPUA = text.unicodeScalars.contains(where: { $0.value >= 0xE200 && $0.value <= 0xE206 })
        let hasDagger = text.contains("†")
        let hasTurnRef = text.contains("【turn")
        let hasReaction = text.contains("[回应]")
        let hasQuote = text.hasPrefix("[引用]") || text.contains("[/回应]\n[引用]")
        if !hasPUA && !hasDagger && !hasTurnRef && !hasReaction && !hasQuote {
            if useCache { cache.setObject(text as NSString, forKey: key) }
            return text
        }

        var result = text

        // 1. Entity annotations → extract just the name
        if hasPUA {
            result = replaceEntities(in: result)
            result = stripPUABlocks(in: result)
            // Clean stray PUA characters
            for scalar in ["\u{E200}", "\u{E201}", "\u{E202}", "\u{E203}", "\u{E204}", "\u{E205}", "\u{E206}"] {
                result = result.replacingOccurrences(of: scalar, with: "")
            }
        }

        // 1.5 表情回应捎带段（10-03）：只给模型看，气泡/搜索/复制都不显示
        if hasReaction {
            result = result.replacingOccurrences(of: "\\[回应\\][\\s\\S]*?\\[/回应\\]\\n?", with: "", options: .regularExpression)
        }

        // 1.6 引用前缀（10-03 引用回复）：气泡顶上单独画引用条，正文里不显示
        if hasQuote {
            result = result.replacingOccurrences(of: "^\\[引用\\][\\s\\S]*?\\[/引用\\]\\n?", with: "", options: .regularExpression)
        }

        // 2. Remove dagger file-line references: 【23†L216-L220】
        if hasDagger {
            result = result.replacingOccurrences(
                of: "【\\d+†[^】]*】",
                with: "",
                options: .regularExpression
            )
        }

        // 3. Remove fullwidth-bracket turn references: 【turn0finance2】
        if hasTurnRef {
            result = result.replacingOccurrences(
                of: "【turn\\d+\\w+\\d+】",
                with: "",
                options: .regularExpression
            )
        }

        if useCache { cache.setObject(result as NSString, forKey: key) }
        return result
    }

    // MARK: - Entity Handling

    /// \u{E200}entity\u{E202}["category","Name","desc"]\u{E201} → Name
    private static func replaceEntities(in text: String) -> String {
        let open = "\u{E200}"
        let close = "\u{E201}"
        let sep = "\u{E202}"
        let prefix = "\(open)entity\(sep)"

        var result = text
        while let startRange = result.range(of: prefix) {
            guard let endRange = result.range(of: close, range: startRange.upperBound..<result.endIndex) else {
                break
            }
            let payload = String(result[startRange.upperBound..<endRange.lowerBound])
            let name = extractEntityName(from: payload)
            result.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: name)
        }
        return result
    }

    /// Parse ["category","Name","disambiguation"] → "Name"
    private static func extractEntityName(from payload: String) -> String {
        if let data = payload.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
           arr.count >= 2, let name = arr[1] as? String {
            return name
        }
        if let data = "[\(payload)]".data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
           arr.count >= 2, let name = arr[1] as? String {
            return name
        }
        return payload.replacingOccurrences(of: "\"", with: "")
    }

    // MARK: - Thinking Block Extraction

    struct ThinkingResult {
        let content: String    // Main content with thinking blocks removed
        let thinking: String?  // Extracted thinking text (nil if none)
    }

    /// Extract [thinking]...[/thinking] or <thinking>...</thinking> blocks from Claude responses
    static func extractThinking(from text: String) -> ThinkingResult {
        // Match [thinking]…[/thinking] 和 <Thinking>…</Thinking>（大小写不敏感，跨行）
        let pattern = "(?:\\[thinking\\]|<thinking>)([\\s\\S]*?)(?:\\[/thinking\\]|</thinking>)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ThinkingResult(content: text, thinking: nil)
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else {
            // 没有配对块，但可能残留孤立标签（只打开 / 只打闭 / 被截断）→ 也清掉
            return ThinkingResult(content: stripStrayThinkingTags(text), thinking: nil)
        }

        // Collect all thinking blocks
        var thinkingParts: [String] = []
        for match in matches {
            if match.numberOfRanges >= 2 {
                let thinkRange = match.range(at: 1)
                thinkingParts.append(nsText.substring(with: thinkRange).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // Remove thinking blocks from main content
        var cleaned = text
        for match in matches.reversed() {
            let range = Range(match.range, in: cleaned)!
            cleaned.removeSubrange(range)
        }
        // 残留的孤立 thinking 标签（模型多打一个闭标签是常见现象）也要清掉
        cleaned = stripStrayThinkingTags(cleaned)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let thinking = thinkingParts.joined(separator: "\n\n")
        return ThinkingResult(content: cleaned, thinking: thinking.isEmpty ? nil : thinking)
    }

    /// 去掉正文里残留的孤立 thinking 标签（配对块已提取后仍可能有多余的开/闭标签）。
    private static func stripStrayThinkingTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\[/?thinking\\]|</?thinking>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: - PUA Block Removal

    /// Remove all PUA-wrapped blocks: \u{E200}...\u{E201}
    private static func stripPUABlocks(in text: String) -> String {
        let open = "\u{E200}"
        let close = "\u{E201}"

        var result = text
        while let startRange = result.range(of: open) {
            guard let endRange = result.range(of: close, range: startRange.upperBound..<result.endIndex) else {
                result.removeSubrange(startRange)
                break
            }
            result.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
        }
        return result
    }

    /// 看得见的文字：清洗后，非 user 再剥思考链。对话内查找与全文索引同一口径（粟粟 S5）
    static func visibleText(_ content: String, isUser: Bool, cacheKey: String? = nil, cached: Bool = true) -> String {
        let cleaned = clean(content, cacheKey: cacheKey, cached: cached)
        return isUser ? cleaned : extractThinking(from: cleaned).content
    }
}
