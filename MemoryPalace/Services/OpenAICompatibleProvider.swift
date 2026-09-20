import Foundation
import UIKit

// MARK: - OpenAI Compatible Provider

final class OpenAICompatibleProvider: BaseChatProvider {
    /// DeepSeek reasoning_content 流式 buffer（其他模型为空）
    private var streamingThinking: String = ""
    private var pendingTagBuffer = ""
    /// Gateway [thinking]...[/thinking] 标记追踪（Claude thinking via OpenAI format）
    private var isInGatewayThinking = false
    /// 流式结束时若有 thinking 内容则调用（构造 MessageSegment 列表）
    var onSegmentsCallback: (([MessageSegment]) -> Void)?
    /// 实时发送每个 reasoning_content chunk（逐字显示思考链用）
    var onThinkingToken: ((String) -> Void)?

    // MARK: - PR-3 客户端 function calling 循环（bridge 工具）
    var bridgeTools: [MCPToolDescriptor] = []
    private var toolRound = 0
    private var finishReason: String?
    private var pendingToolCalls: [Int: [String: Any]] = [:]   // index → {id,name,arguments(累积)}
    private var loopBody: [String: Any] = [:]
    private var loopURL: URL?
    private var loopApiKey = ""
    private var loopHeaders: [String: String] = [:]
    private var accumulatedToolSegments: [MessageSegment] = []
    /// [search-ui] streamingContent 已经切入 segments 的前缀长度。
    /// 轮间把本轮新增文本按时间顺序插进 segments（文字→卡片→文字→卡片），
    /// 最终 [DONE] 只补尾巴，不再整段重复。
    private var segmentedContentLength = 0
    /// OpenRouter 上的 Claude 系模型：cacheFriendly 时显式 per-block 挂 cache_control（system + 末 assistant），
    /// 动态段（[动态上下文] 伪 user）留在断点外。其他上游自动缓存，不需要它。
    /// 模型认不认图片。黑名单式：只挡确定的纯文本模型，未知一律放行——
    /// 误挡会让能看图的模型平白瞎掉，误放最多是模型自己报错（和现状持平）。
    static func supportsVision(model: String) -> Bool {
        let m = model.lowercased()
        // 确定不认图的纯文本模型
        let textOnly = [
            "deepseek-chat", "deepseek-reasoner", "deepseek-coder", "deepseek-v3", "deepseek-r1",
            "gpt-3.5", "text-davinci", "moonshot-v1-8k", "qwen-turbo",
            "llama-3.1-8b", "llama-3.1-70b", "llama-3.3-70b",
            "mistral-7b", "mixtral", "command-r", "yi-34b-chat",
        ]
        if textOnly.contains(where: { m.contains($0) }) { return false }
        // o1-mini / o1-preview 早期推理模型不收图（o1 正式版收）
        if m.contains("o1-mini") || m.contains("o1-preview") { return false }
        return true
    }

    static func wantsORCacheControl(baseURL: String, model: String, samplingParams: SamplingParams?) -> Bool {
        guard samplingParams?.cacheFriendly == true else { return false }
        let m = model.lowercased()
        return baseURL.lowercased().contains("openrouter")
            && (m.hasPrefix("anthropic/") || m.contains("claude"))
    }

    /// cacheFriendly 时给 OR 指定上游 provider 优先（缓存支持最好的官方上游）。只映射已知系列。
    static func orPreferredProviderOrder(baseURL: String, model: String, samplingParams: SamplingParams?) -> [String]? {
        guard samplingParams?.cacheFriendly == true, baseURL.lowercased().contains("openrouter") else { return nil }
        let m = model.lowercased()
        if m.hasPrefix("deepseek/") { return ["DeepSeek"] }
        if m.hasPrefix("anthropic/") || m.contains("claude") { return ["Anthropic"] }
        return nil
    }

    override func sendStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        systemLayers: SystemPromptLayers? = nil,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String],
        samplingParams: SamplingParams? = nil,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        resetState(onToken: onToken, onComplete: onComplete, onError: onError)
        streamingThinking = ""
        isInGatewayThinking = false

        var apiMessages: [[String: Any]] = []
        var systemText = systemPrompt ?? ""
        // 联网搜索：非 Anthropic 走 client function，需在 system 里教模型先搜后读（常量串，缓存稳定）
        if WebSearchSettings.isSearchEnabledFlag {
            let asst = UserDefaults.standard.string(forKey: "assistantName") ?? "Caelum"
            let sp = WebSearchToolService.systemPrompt(assistantName: asst)
            systemText = systemText.isEmpty ? sp : systemText + "\n\n" + sp
        }
        if !systemText.isEmpty {
            apiMessages.append(["role": "system", "content": systemText])
        }
        for msg in messages {
            // Detect multimodal content and convert to OpenAI vision format
            if msg.role == "user", msg.content.hasPrefix("[{"),
               let data = msg.content.data(using: .utf8),
               let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                var visionContent: [[String: Any]] = []
                let modelSeesImages = Self.supportsVision(model: model)
                for block in blocks {
                    let type = block["type"] as? String ?? ""
                    if type == "image", let source = block["source"] as? [String: Any],
                       let b64 = source["data"] as? String,
                       let mediaType = source["media_type"] as? String {
                        // 纯文本模型收到 image block 会整轮报错、对话卡死；降级成文字说明（同 document 分支的处理法）
                        guard modelSeesImages else {
                            visionContent.append(["type": "text", "text": "[图片 — 当前模型看不了图片，换成 Claude 或其它视觉模型可以看]"])
                            continue
                        }
                        visionContent.append(["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(b64)"]])
                    } else if type == "text" {
                        visionContent.append(["type": "text", "text": block["text"] as? String ?? ""])
                    } else if type == "document" {
                        let title = block["title"] as? String ?? "document"
                        visionContent.append(["type": "text", "text": "[附件: \(title) — 此模型不支持文件，请用 Claude 查看]"])
                    }
                }
                apiMessages.append(["role": msg.role, "content": visionContent])
            } else {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            // 让流式响应最后一个 chunk 带上 usage 字段（保险闸回填用）
            "stream_options": ["include_usage": true],
        ]
        if let p = samplingParams {
            if p.temperature != 1.0 { body["temperature"] = p.temperature }
            if p.topP != 1.0 { body["top_p"] = p.topP }
            if p.maxTokens != 4096 { body["max_tokens"] = p.maxTokens }
            if p.frequencyPenalty != 0 { body["frequency_penalty"] = p.frequencyPenalty }
            if p.presencePenalty != 0 { body["presence_penalty"] = p.presencePenalty }
            if p.seed >= 0 { body["seed"] = p.seed }
            if p.reasoningEffort != "auto" { body["reasoning_effort"] = p.reasoningEffort }
            body["stream"] = p.streaming
        }

        // ── cacheFriendly：OpenRouter + Claude 显式 per-block 挂 cache_control + 钉官方上游 ──
        if Self.wantsORCacheControl(baseURL: baseURL, model: model, samplingParams: samplingParams) {
            let mark: [String: Any] = ["type": "ephemeral"]
            // system 块挂标（缓存前缀）
            if let idx = apiMessages.firstIndex(where: { ($0["role"] as? String) == "system" }),
               let sys = apiMessages[idx]["content"] as? String {
                apiMessages[idx]["content"] = [["type": "text", "text": sys, "cache_control": mark] as [String: Any]]
            }
            // 末条 assistant 块挂标（滚动断点），不挂 [动态上下文] 伪 user 段
            if let idx = apiMessages.lastIndex(where: { ($0["role"] as? String) == "assistant" }),
               let text = apiMessages[idx]["content"] as? String {
                apiMessages[idx]["content"] = [["type": "text", "text": text, "cache_control": mark] as [String: Any]]
            }
            body["messages"] = apiMessages
        }
        if let order = Self.orPreferredProviderOrder(baseURL: baseURL, model: model, samplingParams: samplingParams) {
            body["provider"] = ["order": order, "allow_fallbacks": true]
        }

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            onError("无效的 API 地址: \(baseURL)")
            isStreaming = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // PR-3: bridge 工具（OpenAI function 格式）。工具定义写死保证缓存稳定。
        var oaiTools: [[String: Any]] = bridgeTools.isEmpty ? [] : ToolCallLoop.openAITools(bridgeTools)
        // Toolbase P0: 内建工具（search_web + browse_url）从注册表取，双家 schema
        // 由 ToolSchemaRenderer 统一渲染。顺序不变：MCP 之后，保证缓存前缀稳定。
        oaiTools += ToolSchemaRenderer.render(
            ToolRegistry.enabledDefinitions(ToolGateContext(family: .openAI)),
            family: .openAI
        )
        if !oaiTools.isEmpty {
            body["tools"] = oaiTools
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // PR-3: 存循环上下文
        loopBody = body
        loopURL = url
        loopApiKey = apiKey
        loopHeaders = extraHeaders
        toolRound = 0
        finishReason = nil
        pendingToolCalls = [:]
        accumulatedToolSegments = []
        segmentedContentLength = 0
        startRequest(request)
    }

    /// PR-3: 用当前 loopBody（已追加 assistant tool_calls + tool 结果消息）重发一轮。
    private func fireOpenAIRound() {
        buffer = ""
        receivedDone = false
        streamingThinking = ""
        isInGatewayThinking = false
        finishReason = nil
        pendingToolCalls = [:]
        guard let url = loopURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(loopApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in loopHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: loopBody)
        isStreaming = true
        startRequest(request)
    }

    /// PR-3: 执行本轮工具调用并发起下一轮。
    private func runOpenAIToolRound(_ calls: [ToolCallLoop.ToolCall]) {
        // [search-ui] 本轮文本先入 segments，保持"文字→卡片→文字→卡片"的时间顺序
        //（此前轮间文本不进 segments，最终全部堆在所有卡片下面）
        let roundText = String(streamingContent.dropFirst(segmentedContentLength))
        if !roundText.isEmpty {
            accumulatedToolSegments.append(.text(roundText))
            segmentedContentLength = streamingContent.count
        }
        var assistantToolCalls: [[String: Any]] = []
        for c in calls {
            assistantToolCalls.append(["id": c.id, "type": "function",
                                       "function": ["name": c.name, "arguments": c.argumentsJSON]])
            accumulatedToolSegments.append(.toolUse(id: c.id, name: c.name,
                                                    inputJSON: c.argumentsJSON, integrationName: nil, iconName: nil))
        }
        let assistantText = streamingContent
        toolRound += 1
        // [search-ui] 实时推送（结果未回）：气泡立刻长出"搜索中/阅读中"pending 卡片，
        // 不等整轮结束。processData 跑在 URLSession delegate 线程，推送必须回 main。
        let pendingSnapshot = accumulatedToolSegments
        DispatchQueue.main.async { [weak self] in
            self?.onSegmentsCallback?(pendingSnapshot)
        }
        Task { [weak self] in
            guard let self else { return }
            let outcomes = await ToolCallLoop.execute(calls, bridgeTools: self.bridgeTools, metaToolCatalog: self.metaToolCatalog)
            await MainActor.run {
                var msgs = (self.loopBody["messages"] as? [[String: Any]]) ?? []
                var assistantMsg: [String: Any] = ["role": "assistant", "tool_calls": assistantToolCalls]
                if !assistantText.isEmpty { assistantMsg["content"] = assistantText }
                msgs.append(assistantMsg)
                for o in outcomes {
                    msgs.append(["role": "tool", "tool_call_id": o.id, "content": o.text])
                    self.accumulatedToolSegments.append(.toolResult(toolUseId: o.id, text: o.text, isError: o.isError, integrationName: nil))
                }
                self.loopBody["messages"] = msgs
                // [search-ui] 实时推送（结果已回）：pending 卡片翻成来源列表
                self.onSegmentsCallback?(self.accumulatedToolSegments)
                self.fireOpenAIRound()
            }
        }
    }

    override func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String]
    ) async throws -> (String, TokenUsage?) {
        var apiMessages: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            apiMessages.append(["role": "system", "content": sys])
        }
        for msg in messages {
            // 多模态 JSON（旧图转述后台调用会带图块）→ 与流式路径同一 vision 转换
            if msg.role == "user", msg.content.hasPrefix("[{"),
               let data = msg.content.data(using: .utf8),
               let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
               Self.supportsVision(model: model) {
                var vision: [[String: Any]] = []
                for block in blocks {
                    let type = block["type"] as? String ?? ""
                    if type == "image", let source = block["source"] as? [String: Any],
                       let b64 = source["data"] as? String, let mt = source["media_type"] as? String {
                        vision.append(["type": "image_url", "image_url": ["url": "data:\(mt);base64,\(b64)"]])
                    } else if type == "text" {
                        vision.append(["type": "text", "text": block["text"] as? String ?? ""])
                    }
                }
                apiMessages.append(["role": msg.role, "content": vision])
            } else {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": false,
        ]

        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw NSError(domain: "ChatService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard statusCode == 200 else {
            throw NSError(domain: "ChatService", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: Self.extractError(from: data, statusCode: statusCode)])
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "ChatService", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])
        }

        var usage: TokenUsage? = nil
        if let u = obj["usage"] as? [String: Any],
           let pt = u["prompt_tokens"] as? Int,
           let ct = u["completion_tokens"] as? Int {
            // OpenRouter/DeepSeek 缓存 token 解析
            // Anthropic 透传：cache_read_input_tokens / cache_creation_input_tokens
            // OAI 系：prompt_tokens_details.cached_tokens
            let cacheRead = (u["cache_read_input_tokens"] as? Int)
                ?? ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                ?? 0
            let cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
            usage = TokenUsage(inputTokens: pt, outputTokens: ct,
                              cacheReadInputTokens: cacheRead,
                              cacheCreationInputTokens: cacheWrite)
        }

        return (content, usage)
    }

    override func processData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        if httpStatusCode != 0 && httpStatusCode != 200 {
            errorBody += text
            return
        }

        buffer += text

        while let lineEnd = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<lineEnd])
            buffer = String(buffer[buffer.index(after: lineEnd)...])

            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    receivedDone = true
                    // PR-3: function calling 多轮 —— 本轮要求调工具则客户端执行后再发一轮
                    let calls = pendingToolCalls.sorted { $0.key < $1.key }.compactMap { (_, v) -> ToolCallLoop.ToolCall? in
                        let name = v["name"] as? String ?? ""
                        guard !name.isEmpty,
                              bridgeTools.contains(where: { $0.name == name })
                                  || name == WebSearchToolService.toolName
                                  || name == BrowseURLTool.toolName
                        else { return nil }
                        return ToolCallLoop.ToolCall(id: v["id"] as? String ?? "",
                                                     name: name,
                                                     argumentsJSON: (v["arguments"] as? String).flatMap { $0.isEmpty ? "{}" : $0 } ?? "{}")
                    }
                    if finishReason == "tool_calls", !calls.isEmpty, toolRound < ToolCallLoop.maxRounds {
                        runOpenAIToolRound(calls)
                        return
                    }
                    DispatchQueue.main.async { [self] in
                        isStreaming = false
                        // flush 任何滞留的标签缓冲，避免结尾被吞字
                        if !pendingTagBuffer.isEmpty {
                            let held = pendingTagBuffer
                            pendingTagBuffer = ""
                            if isInGatewayThinking {
                                streamingThinking += held
                                onThinkingToken?(held)
                            } else {
                                streamingContent += held
                                onToken?(held)
                            }
                        }
                        var finalContent = streamingContent
                        if !streamingThinking.isEmpty {
                            finalContent = "[thinking]\(streamingThinking)[/thinking]\n\(streamingContent)"
                        }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        if !accumulatedToolSegments.isEmpty {
                            // [search-ui] 轮间文本已入 segments，这里只补最终轮的尾巴
                            let finalTail = String(streamingContent.dropFirst(segmentedContentLength))
                            onSegmentsCallback?(finalTail.isEmpty
                                ? accumulatedToolSegments
                                : accumulatedToolSegments + [.text(finalTail)])
                        }
                        onComplete?(finalContent, finalUsage)
                    }
                    return
                }
                parseOpenAIChunk(payload)
            }
        }
    }

    private func parseOpenAIChunk(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // usage 字段可能出现在任何 chunk（通常是最后一个，include_usage=true 时）
        if let u = obj["usage"] as? [String: Any],
           let pt = u["prompt_tokens"] as? Int,
           let ct = u["completion_tokens"] as? Int {
            // 缓存 token（流式 chunk）
            let cr = (u["cache_read_input_tokens"] as? Int)
                ?? ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                ?? 0
            let cw = u["cache_creation_input_tokens"] as? Int ?? 0
            accumulatedCacheReadTokens = cr; accumulatedCacheCreationTokens = cw
            accumulatedInputTokens = pt
            accumulatedOutputTokens = ct
            gotUsage = true
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any]
        else {
            if let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String {
                DispatchQueue.main.async { [self] in
                    isStreaming = false
                    error = message
                    onError?(message)
                }
            }
            return
        }

        if let fr = choices.first?["finish_reason"] as? String, !fr.isEmpty { finishReason = fr }
        // PR-3: 累积 tool_calls（流式按 index 分片，id/name 首片到达，arguments 增量拼接）
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let idx = tc["index"] as? Int ?? 0
                var entry = pendingToolCalls[idx] ?? ["id": "", "name": "", "arguments": ""]
                if let id = tc["id"] as? String, !id.isEmpty { entry["id"] = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty { entry["name"] = name }
                    if let args = fn["arguments"] as? String {
                        entry["arguments"] = ((entry["arguments"] as? String) ?? "") + args
                    }
                }
                pendingToolCalls[idx] = entry
            }
        }

        // DeepSeek reasoning model：思考链字段
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            DispatchQueue.main.async { [self] in
                streamingThinking += reasoning
                onThinkingToken?(reasoning)  // 实时推送每个 chunk
            }
        }

        if let content = delta["content"] as? String {
            DispatchQueue.main.async { [self] in
                // 标签缓冲：拼接后再检测，防止标签被跨chunk切断
                pendingTagBuffer += content
                let processContent: String
                if pendingTagBuffer.contains("[thinking]") || pendingTagBuffer.contains("[/thinking]") || pendingTagBuffer.contains("<thinking>") || pendingTagBuffer.contains("</thinking>") {
                    processContent = pendingTagBuffer
                    pendingTagBuffer = ""
                } else if pendingTagBuffer.count < 256, Self.endsWithPartialTag(pendingTagBuffer) {
                    // 结尾可能是被切断的标签前缀，继续缓冲。
                    // 用 suffix 检测而非 contains：正文里出现的 </、[/ 等闭合标签不会命中，
                    // 且加 256 字上限，避免缓冲区永久吞字冻结。
                    return
                } else {
                    processContent = pendingTagBuffer
                    pendingTagBuffer = ""
                }
                let content = processContent
                // Gateway [thinking]...[/thinking] 标记路由：
                // thinking 标记之间的 token 走 onThinkingToken，其余走 onToken
                if content.contains("[thinking]") || content.contains("<thinking>") {
                    isInGatewayThinking = true
                    let after = (content.components(separatedBy: "[thinking]").count > 1 ? content.components(separatedBy: "[thinking]").last : content.components(separatedBy: "<thinking>").last) ?? ""
                    let trimmed = after.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        streamingThinking += trimmed
                        onThinkingToken?(trimmed)
                    }
                } else if content.contains("[/thinking]") || content.contains("</thinking>") {
                    let parts = content.contains("[/thinking]") ? content.components(separatedBy: "[/thinking]") : content.components(separatedBy: "</thinking>")
                    let before = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !before.isEmpty {
                        streamingThinking += before
                        onThinkingToken?(before)
                    }
                    isInGatewayThinking = false
                    let after = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if !after.isEmpty {
                        streamingContent += after
                        onToken?(after)
                    }
                } else if isInGatewayThinking {
                    streamingThinking += content
                    onThinkingToken?(content)
                } else {
                    streamingContent += content
                    onToken?(content)
                }
            }
        }
    }

    /// 已知的、可能被跨 chunk 切断的标签。
    private static let bufferableTags = ["[thinking]", "[/thinking]", "<thinking>", "</thinking>"]

    /// 判断缓冲区结尾是否是某个已知标签的非空真前缀（说明标签可能被切断了）。
    private static func endsWithPartialTag(_ s: String) -> Bool {
        for tag in bufferableTags {
            var prefix = tag
            while prefix.count > 1 {
                prefix = String(prefix.dropLast())
                if s.hasSuffix(prefix) { return true }
            }
        }
        return false
    }
}
