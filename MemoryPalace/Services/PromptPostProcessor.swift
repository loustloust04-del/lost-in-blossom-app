import Foundation

// MARK: - Post-Processing Mode

enum PostProcessingMode: String, Codable, CaseIterable {
    case none = "none"        // 不处理
    case merge = "merge"      // 合并连续同 role
    case strict = "strict"    // 合并 + user first + 中途 system 降级
}

// MARK: - Processed Prompt

struct ProcessedPrompt {
    var systemPrompt: String?
    var messages: [(role: String, content: String)]
    var transforms: [String]
}

// MARK: - Request Preview

struct RequestPreview {
    var body: [String: Any]
    var providerType: ProviderType
    var tokenEstimate: Int
}

// MARK: - Token Estimator

struct TokenEstimator {
    /// 改良粗算：英文 ~4 字符/token，中文 ~1.5 字符/token
    /// 标注 ≈ 表示估算。未来可接 API 精确计数。
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var tokens: Double = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                tokens += 0.25  // 英文 ~4 chars/token
            } else {
                tokens += 1.5   // CJK ~1.5 tokens/char
            }
        }
        // JSON overhead: role/content keys, quotes, commas
        return max(Int(tokens.rounded(.up)), 1)
    }

    /// 估算 messages 列表的总 token
    static func estimate(systemPrompt: String?, messages: [(role: String, content: String)]) -> Int {
        var total = 0
        if let sys = systemPrompt { total += estimate(sys) + 4 } // system overhead
        for msg in messages {
            total += estimate(msg.content) + 4  // per-message overhead (role, delimiters)
        }
        total += 3  // request priming
        return total
    }
}

// MARK: - Prompt Post-Processor

struct PromptPostProcessor {

    // MARK: - Main Pipeline

    /// 后处理：squash → post-processing mode → provider 适配
    static func process(
        systemPrompt: String?,
        messages: [(role: String, content: String)],
        sampling: SamplingParams,
        providerType: ProviderType
    ) -> ProcessedPrompt {
        var sys = systemPrompt
        var msgs = messages
        var transforms: [String] = []

        // 1. squash system messages
        if sampling.squashSystemMessages {
            (sys, msgs) = squashConsecutiveSystem(systemPrompt: sys, messages: msgs)
            transforms.append("squash: 合并连续 system 消息")
        }

        // 2. post-processing mode
        let mode = PostProcessingMode(rawValue: sampling.postProcessingMode) ?? .none
        switch mode {
        case .merge:
            msgs = mergeConsecutiveSameRole(msgs)
            transforms.append("merge: 合并连续同 role 消息")
        case .strict:
            (sys, msgs) = strictProcess(systemPrompt: sys, messages: msgs)
            transforms.append("strict: user first + 中途 system 降级 + 合并")
        case .none:
            break
        }

        // 3. provider 适配
        switch providerType {
        case .anthropic:
            (sys, msgs) = adaptForAnthropic(systemPrompt: sys, messages: msgs)
            transforms.append("anthropic: system 抽到顶层，user/assistant 交替")
        case .openaiCompatible:
            break // system 留在 messages 里（或已是顶层），不需要特殊处理
        case .ccBridge:
            break // CC Bridge 直接透传，无需适配
        }

        return ProcessedPrompt(systemPrompt: sys, messages: msgs, transforms: transforms)
    }

    // MARK: - Request Body Builder

    /// 构建最终 request body（用于预览，不实际发送）
    static func buildRequestPreview(
        processed: ProcessedPrompt,
        model: String,
        sampling: SamplingParams,
        providerType: ProviderType
    ) -> RequestPreview {
        var body: [String: Any]

        switch providerType {
        case .openaiCompatible:
            body = buildOpenAIBody(processed: processed, model: model, sampling: sampling)
        case .anthropic:
            body = buildAnthropicBody(processed: processed, model: model, sampling: sampling)
        case .ccBridge:
            // CC Bridge 用 OpenAI 格式作为预览占位
            body = buildOpenAIBody(processed: processed, model: model, sampling: sampling)
        }

        let tokens = TokenEstimator.estimate(
            systemPrompt: processed.systemPrompt,
            messages: processed.messages
        )

        return RequestPreview(body: body, providerType: providerType, tokenEstimate: tokens)
    }

    // MARK: - Squash

    /// 合并连续 system 消息为一条（system prompt + messages 开头的连续 system）
    private static func squashConsecutiveSystem(
        systemPrompt: String?,
        messages: [(role: String, content: String)]
    ) -> (String?, [(role: String, content: String)]) {
        var parts: [String] = []
        if let sys = systemPrompt, !sys.isEmpty { parts.append(sys) }

        var remaining: [(role: String, content: String)] = []
        var inSystemRun = true

        for msg in messages {
            if inSystemRun && msg.role == "system" {
                parts.append(msg.content)
            } else {
                inSystemRun = false
                // 后续连续 system 也合并
                if msg.role == "system" && !remaining.isEmpty && remaining.last?.role == "system" {
                    let last = remaining.removeLast()
                    remaining.append((role: "system", content: last.content + "\n\n" + msg.content))
                } else {
                    remaining.append(msg)
                }
            }
        }

        let merged = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        return (merged, remaining)
    }

    // MARK: - Merge

    /// 合并连续同 role 消息
    private static func mergeConsecutiveSameRole(
        _ messages: [(role: String, content: String)]
    ) -> [(role: String, content: String)] {
        guard !messages.isEmpty else { return [] }
        var result: [(role: String, content: String)] = [messages[0]]
        for msg in messages.dropFirst() {
            if msg.role == result.last?.role {
                let last = result.removeLast()
                result.append((role: msg.role, content: last.content + "\n\n" + msg.content))
            } else {
                result.append(msg)
            }
        }
        return result
    }

    // MARK: - Strict

    /// strict: 中途 system 降级为 user → 强制 user first → 合并连续同 role
    private static func strictProcess(
        systemPrompt: String?,
        messages: [(role: String, content: String)]
    ) -> (String?, [(role: String, content: String)]) {
        // 1. 收集开头连续 system 到 systemPrompt
        var sysParts: [String] = []
        if let sys = systemPrompt, !sys.isEmpty { sysParts.append(sys) }
        var rest: [(role: String, content: String)] = []
        var passedSystem = false

        for msg in messages {
            if !passedSystem && msg.role == "system" {
                sysParts.append(msg.content)
            } else {
                passedSystem = true
                // 中途 system → user
                if msg.role == "system" {
                    rest.append((role: "user", content: msg.content))
                } else {
                    rest.append(msg)
                }
            }
        }

        // 2. 强制 user first
        if let first = rest.first, first.role != "user" {
            rest.insert((role: "user", content: "[继续]"), at: 0)
        }

        // 3. 合并连续同 role
        rest = mergeConsecutiveSameRole(rest)

        let sys = sysParts.isEmpty ? nil : sysParts.joined(separator: "\n\n")
        return (sys, rest)
    }

    // MARK: - Anthropic Adapter

    /// Anthropic 适配：开头连续 system 移到 systemPrompt，中途 system 改 user，相邻同 role 合并
    private static func adaptForAnthropic(
        systemPrompt: String?,
        messages: [(role: String, content: String)]
    ) -> (String?, [(role: String, content: String)]) {
        var sysParts: [String] = []
        if let sys = systemPrompt, !sys.isEmpty { sysParts.append(sys) }

        var adapted: [(role: String, content: String)] = []
        var passedSystem = false

        for msg in messages {
            if !passedSystem && msg.role == "system" {
                sysParts.append(msg.content)
            } else {
                passedSystem = true
                if msg.role == "system" {
                    adapted.append((role: "user", content: msg.content))
                } else {
                    adapted.append(msg)
                }
            }
        }

        // Anthropic 要求 user/assistant 交替，合并相邻同 role
        adapted = mergeConsecutiveSameRole(adapted)

        // Anthropic 要求第一条是 user
        if let first = adapted.first, first.role != "user" {
            adapted.insert((role: "user", content: "[开始对话]"), at: 0)
        }

        // 空消息兜底
        if adapted.isEmpty {
            adapted.append((role: "user", content: "[开始对话]"))
        }

        let sys = sysParts.isEmpty ? nil : sysParts.joined(separator: "\n\n")
        return (sys, adapted)
    }

    // MARK: - Request Body Builders

    private static func buildOpenAIBody(
        processed: ProcessedPrompt,
        model: String,
        sampling: SamplingParams
    ) -> [String: Any] {
        var apiMessages: [[String: String]] = []
        if let sys = processed.systemPrompt, !sys.isEmpty {
            apiMessages.append(["role": "system", "content": sys])
        }
        for msg in processed.messages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": sampling.streaming,
        ]
        if sampling.temperature != 1.0 { body["temperature"] = sampling.temperature }
        if sampling.topP != 1.0 { body["top_p"] = sampling.topP }
        if sampling.maxTokens != 4096 { body["max_tokens"] = sampling.maxTokens }
        if sampling.frequencyPenalty != 0 { body["frequency_penalty"] = sampling.frequencyPenalty }
        if sampling.presencePenalty != 0 { body["presence_penalty"] = sampling.presencePenalty }
        if sampling.seed >= 0 { body["seed"] = sampling.seed }
        if sampling.reasoningEffort != "auto" { body["reasoning_effort"] = sampling.reasoningEffort }

        return body
    }

    private static func buildAnthropicBody(
        processed: ProcessedPrompt,
        model: String,
        sampling: SamplingParams
    ) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        for msg in processed.messages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": sampling.maxTokens,
            "stream": sampling.streaming,
        ]
        if let sys = processed.systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        if sampling.temperature != 1.0 { body["temperature"] = sampling.temperature }
        if sampling.topP != 1.0 { body["top_p"] = sampling.topP }
        if sampling.topK > 0 { body["top_k"] = sampling.topK }

        return body
    }

    // MARK: - JSON Formatting

    /// dict → 格式化 JSON 字符串
    static func prettyJSON(_ dict: [String: Any]) -> String {
        // 手动构建有序 JSON，因为 JSONSerialization 的 key 顺序不可控
        var lines: [String] = ["{"]

        // 按语义顺序输出 key
        let orderedKeys: [String] = [
            "model", "system", "messages",
            "max_tokens", "temperature", "top_p", "top_k",
            "frequency_penalty", "presence_penalty", "seed",
            "stream", "stop", "stop_sequences"
        ]

        let allKeys = orderedKeys.filter { dict[$0] != nil }
            + dict.keys.filter { !orderedKeys.contains($0) }.sorted()

        for (i, key) in allKeys.enumerated() {
            guard let value = dict[key] else { continue }
            let comma = i < allKeys.count - 1 ? "," : ""
            let valueStr = formatJSONValue(value, indent: 2)
            lines.append("  \"\(key)\": \(valueStr)\(comma)")
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func formatJSONValue(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let innerPad = String(repeating: " ", count: indent + 2)

        if let arr = value as? [[String: Any]] {
            // messages array
            if arr.isEmpty { return "[]" }
            var lines = ["["]
            for (i, item) in arr.enumerated() {
                let comma = i < arr.count - 1 ? "," : ""
                // Compact single-line for simple messages
                if let role = item["role"] as? String, let content = item["content"] as? String {
                    let escaped = content
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    let truncated = escaped.count > 80
                        ? String(escaped.prefix(77)) + "..."
                        : escaped
                    lines.append("\(innerPad){\"role\": \"\(role)\", \"content\": \"\(truncated)\"}\(comma)")
                } else {
                    // Fallback: JSONSerialization
                    if let data = try? JSONSerialization.data(withJSONObject: item, options: .fragmentsAllowed),
                       let str = String(data: data, encoding: .utf8) {
                        lines.append("\(innerPad)\(str)\(comma)")
                    }
                }
            }
            lines.append("\(pad)]")
            return lines.joined(separator: "\n")
        } else if let arr = value as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: .fragmentsAllowed),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"
        } else if let str = value as? String {
            let escaped = str
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let truncated = escaped.count > 200
                ? String(escaped.prefix(197)) + "..."
                : escaped
            return "\"\(truncated)\""
        } else if let num = value as? Double {
            if num == num.rounded() && num < 1_000_000 {
                return String(Int(num))
            }
            return String(num)
        } else if let num = value as? Int {
            return String(num)
        } else if let bool = value as? Bool {
            return bool ? "true" : "false"
        } else {
            return "\(value)"
        }
    }
}
