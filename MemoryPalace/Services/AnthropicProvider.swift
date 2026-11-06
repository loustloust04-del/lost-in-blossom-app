import Foundation

// MARK: - Anthropic Provider

/// 在 content_block_start 时创建，在 content_block_stop 时 finalize.
private struct ActiveBlock {
    enum Kind {
        case text
        case toolUse(id: String, name: String)
        case toolResult(toolUseId: String)
    }
    var kind: Kind
    var accumulated: String = ""
}

final class AnthropicProvider: BaseChatProvider {
    private var currentEventType = ""

    /// 由 ProviderRouter 在调用 sendStreaming() 前设置. 为空则不使用 MCP.
    var mcpServersToInject: [MCPServerConfig] = []

    /// 流式完成后仅在存在 tool 段时调用. ConversationViewModel 用于 setSegments().
    var onSegmentsCallback: (([MessageSegment]) -> Void)?

    /// index → 进行中的 content block 状态
    private var activeBlocks: [Int: ActiveBlock] = [:]

    /// content_block_stop 时已完成的段（text + tool，保持顺序）
    private var pendingSegments: [MessageSegment] = []

    // MARK: - PR-2 客户端 tool-calling 循环（bridge 工具，Anthropic 不代为执行）
    /// 由 ProviderRouter 在调用前设置；非空时注入 body["tools"] 并启用多轮循环。
    var bridgeTools: [MCPToolDescriptor] = []
    private var toolRound = 0
    private var roundStopReason: String?
    private var loopBody: [String: Any] = [:]
    private var loopURL: URL?
    private var loopApiKey = ""
    private var loopHeaders: [String: String] = [:]
    private var loopUseMCPBeta = false
    /// 跨轮累积的 segments（每轮 toolUse + 本地生成的 toolResult），终轮一次性回调 UI。
    private var accumulatedToolSegments: [MessageSegment] = []

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
        currentEventType = ""
        activeBlocks = [:]
        pendingSegments = []

        // Build Anthropic Messages API format
        var apiMessages: [[String: Any]] = []
        for msg in messages {
            // Detect multimodal content (JSON array string starting with "[{")
            if msg.role == "user", msg.content.hasPrefix("[{"),
               let data = msg.content.data(using: .utf8),
               let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                apiMessages.append(["role": msg.role, "content": blocks])
            } else {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
        }

        // BP4 消息历史：断点打在倒数第二条（上轮 assistant 回复，不再变化）。
        // 最后一条是本轮新的 user 消息（每轮变，不缓存）。
        // 滞回裁剪期间（30轮），历史前缀纹丝不动，缓存白吃。
        if systemLayers != nil, apiMessages.count >= 2 {
            let targetIdx = apiMessages.count - 2  // 倒数第二条
            var last = apiMessages[targetIdx]
            if let str = last["content"] as? String {
                last["content"] = [["type": "text", "text": str, "cache_control": ["type": "ephemeral"]]]
            } else if var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = blocks
            }
            apiMessages[targetIdx] = last
        }

        let maxTok = samplingParams?.maxTokens ?? 4096
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": maxTok,
            "stream": true,
        ]
        // prompt caching 断点 1/2：分层 system → text block 数组，层 1（稳定核心）+ 层 2
        // （半稳定）末尾各打一个断点；层 3（volatile）不打断点，怎么变都不影响前两层缓存。
        if let layers = systemLayers, !layers.isEmpty {
            body["system"] = Self.buildSystemBlocks(layers)
        } else if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        // metadata.user_id：让同一用户请求粘在同一后端节点，避免缓存写在 A 节点读在 B 节点永远 miss
        // （走中转/gateway 时必需；原生 API 无害）。
        body["metadata"] = ["user_id": Self.stablePromptUserId]
        if let p = samplingParams {
            if p.temperature != 1.0 { body["temperature"] = p.temperature }
            if p.topP != 1.0 { body["top_p"] = p.topP }
            if p.topK > 0 { body["top_k"] = p.topK }
            body["stream"] = p.streaming
        }

        // MCP servers injection (Anthropic mcp_servers beta)
        let enabledMCP = mcpServersToInject.filter(\.isEnabled)
        if !enabledMCP.isEmpty {
            body["mcp_servers"] = enabledMCP.map { s -> [String: Any] in
                var server: [String: Any] = ["type": "url", "url": s.url, "name": s.name]
                if !s.authorizationToken.isEmpty {
                    server["authorization_token"] = s.authorizationToken
                }
                return server
            }
        }

        guard let url = URL(string: "\(baseURL)/messages") else {
            onError("无效的 API 地址: \(baseURL)")
            isStreaming = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // MCP beta header (only when MCP servers are active)
        if !enabledMCP.isEmpty {
            request.setValue("mcp-client-0.1", forHTTPHeaderField: "anthropic-beta")
        }
        // PR-2: bridge 工具（客户端执行；Anthropic 只返回 tool_use 并停）。工具定义写死保证缓存稳定。
        var antTools: [[String: Any]] = bridgeTools.isEmpty ? [] : ToolCallLoop.anthropicTools(bridgeTools)
        // Toolbase P0: 注册表内建工具（anthropic 家族——目前 search/browse 的门控
        // 只发 OpenAI 系，这里通常为空；保留调用作为未来工具的统一接入点）
        antTools += ToolSchemaRenderer.render(
            ToolRegistry.enabledDefinitions(ToolGateContext(family: .anthropic)),
            family: .anthropic
        )
        // 联网搜索：Anthropic 直连用 server tool（web_search_20250305 形状特殊，
        // 不进注册表，Claude 后端自执行搜索），放 MCP 工具之后
        if WebSearchSettings.isSearchEnabledFlag {
            antTools.append(WebSearchToolService.anthropicServerTool())
        }
        if !antTools.isEmpty {
            body["tools"] = antTools
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // PR-2: 存循环上下文，bridge 工具触发 tool_use 时多轮重发
        loopBody = body
        loopURL = url
        loopApiKey = apiKey
        loopHeaders = extraHeaders
        loopUseMCPBeta = !enabledMCP.isEmpty
        toolRound = 0
        accumulatedToolSegments = []
        roundStopReason = nil
        startRequest(request)
    }

    /// PR-2: 用当前 loopBody（已追加 assistant tool_use + user tool_result）重发一轮。
    private func fireAnthropicRound() {
        currentEventType = ""
        activeBlocks = [:]
        pendingSegments = []
        roundStopReason = nil
        receivedDone = false
        buffer = ""
        guard let url = loopURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(loopApiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in loopHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if loopUseMCPBeta { request.setValue("mcp-client-0.1", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: loopBody)
        isStreaming = true
        startRequest(request)
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
        for msg in messages {
            if msg.role == "user", msg.content.hasPrefix("[{"),
               let data = msg.content.data(using: .utf8),
               let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                apiMessages.append(["role": msg.role, "content": blocks])
            } else {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": 4096,
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }

        guard let url = URL(string: "\(baseURL)/messages") else {
            throw NSError(domain: "ChatService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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
              let contentArray = obj["content"] as? [[String: Any]],
              let text = contentArray.first?["text"] as? String else {
            throw NSError(domain: "ChatService", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])
        }

        var usage: TokenUsage? = nil
        if let u = obj["usage"] as? [String: Any],
           let it = u["input_tokens"] as? Int,
           let ot = u["output_tokens"] as? Int {
            usage = TokenUsage(
                inputTokens: it,
                outputTokens: ot,
                cacheReadInputTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreationInputTokens: u["cache_creation_input_tokens"] as? Int ?? 0
            )
        }

        return (text, usage)
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

            if line.hasPrefix("event: ") {
                currentEventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                handleAnthropicEvent(type: currentEventType, data: payload)
            }
        }
    }

    private func handleAnthropicEvent(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return }

        switch type {
        case "message_start":
            // { "type": "message_start", "message": { "usage": { "input_tokens": N,
            //   "cache_read_input_tokens": N, "cache_creation_input_tokens": N } } }
            if let msg = obj["message"] as? [String: Any],
               let u = msg["usage"] as? [String: Any] {
                if let it = u["input_tokens"] as? Int {
                    accumulatedInputTokens = it
                    gotUsage = true
                }
                // prompt caching：缓存读/写 token。缓存开启后 input_tokens 只是未缓存余量。
                if let cr = u["cache_read_input_tokens"] as? Int {
                    accumulatedCacheReadTokens = cr
                    gotUsage = true
                }
                if let cc = u["cache_creation_input_tokens"] as? Int {
                    accumulatedCacheCreationTokens = cc
                    gotUsage = true
                }
            }

        case "content_block_start":
            // 新的 content block 开始. 共三种类型：text / tool_use / tool_result.
            let index = obj["index"] as? Int ?? 0
            let block = obj["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "text":
                activeBlocks[index] = ActiveBlock(kind: .text)
            case "tool_use":
                let id = block?["id"] as? String ?? ""
                let rawName = block?["name"] as? String ?? ""
                activeBlocks[index] = ActiveBlock(kind: .toolUse(id: id, name: rawName))
            case "tool_result":
                let toolUseId = block?["tool_use_id"] as? String ?? ""
                var toolResultBlock = ActiveBlock(kind: .toolResult(toolUseId: toolUseId))
                // mcp_servers beta: tool_result 内容有时直接包含在 content_block_start 中
                if let content = block?["content"] as? String {
                    toolResultBlock.accumulated = content
                }
                activeBlocks[index] = toolResultBlock
            default:
                break
            }

        case "content_block_delta":
            let index = obj["index"] as? Int ?? 0
            let delta = obj["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                let text = delta?["text"] as? String ?? ""
                activeBlocks[index]?.accumulated += text
                // 只有 text block 才通过 onToken 实时更新
                if let block = activeBlocks[index], case .text = block.kind {
                    DispatchQueue.main.async { [self] in
                        streamingContent += text
                        onToken?(text)
                    }
                }
            case "input_json_delta":
                // 累积 tool_use block 的输入 JSON 片段
                let partial = delta?["partial_json"] as? String ?? ""
                activeBlocks[index]?.accumulated += partial
            default:
                if let text = delta?["text"] as? String, !text.isEmpty {
                    // fallback: 仅有 text 字段而无 type 的情况（兼容旧版 Anthropic API）
                    activeBlocks[index]?.accumulated += text
                    DispatchQueue.main.async { [self] in
                        streamingContent += text
                        onToken?(text)
                    }
                }
            }

        case "content_block_stop":
            // block 完成 → 生成 MessageSegment 后追加到 pendingSegments
            let index = obj["index"] as? Int ?? 0
            if let block = activeBlocks.removeValue(forKey: index) {
                finalizeBlock(block)
            }

        case "message_delta":
            if let d = obj["delta"] as? [String: Any], let sr = d["stop_reason"] as? String {
                roundStopReason = sr
            }
            // { "usage": { "output_tokens": N } }
            if let u = obj["usage"] as? [String: Any],
               let ot = u["output_tokens"] as? Int {
                accumulatedOutputTokens = ot
                gotUsage = true
            }

        case "message_stop":
            receivedDone = true
            let roundSegments = pendingSegments
            // PR-2: 本轮里属于 bridge 工具的 tool_use（Anthropic 没代执行，等客户端跑）
            let bridgeCalls: [ToolCallLoop.ToolCall] = roundSegments.compactMap { seg in
                if case .toolUse(let id, let name, let inputJSON, _, _) = seg,
                   bridgeTools.contains(where: { $0.name == name }) {
                    return ToolCallLoop.ToolCall(id: id, name: name, argumentsJSON: inputJSON)
                }
                return nil
            }
            if roundStopReason == "tool_use", !bridgeCalls.isEmpty, toolRound < ToolCallLoop.maxRounds {
                accumulatedToolSegments.append(contentsOf: roundSegments)
                // [search-ui] 实时推送（结果未回）：气泡立刻长出 pending 卡片。
                // processData 在 delegate 线程，推送回 main。
                let pendingSnapshot = accumulatedToolSegments
                DispatchQueue.main.async { [weak self] in
                    self?.onSegmentsCallback?(pendingSnapshot)
                }
                var assistantContent: [[String: Any]] = []
                for seg in roundSegments {
                    switch seg {
                    case .text(let t):
                        if !t.isEmpty { assistantContent.append(["type": "text", "text": t]) }
                    case .toolUse(let id, let name, let inputJSON, _, _):
                        let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
                        assistantContent.append(["type": "tool_use", "id": id, "name": name, "input": input])
                    default: break
                    }
                }
                toolRound += 1
                Task { [weak self] in
                    guard let self else { return }
                    let outcomes = await ToolCallLoop.execute(bridgeCalls, bridgeTools: self.bridgeTools, metaToolCatalog: self.metaToolCatalog)
                    await MainActor.run {
                        var userContent: [[String: Any]] = []
                        for o in outcomes {
                            var tr: [String: Any] = ["type": "tool_result", "tool_use_id": o.id, "content": o.text]
                            if o.isError { tr["is_error"] = true }
                            userContent.append(tr)
                            self.accumulatedToolSegments.append(.toolResult(toolUseId: o.id, text: o.text, isError: o.isError, integrationName: nil))
                        }
                        var msgs = (self.loopBody["messages"] as? [[String: Any]]) ?? []
                        msgs.append(["role": "assistant", "content": assistantContent])
                        msgs.append(["role": "user", "content": userContent])
                        self.loopBody["messages"] = msgs
                        // [search-ui] 实时推送（结果已回）：pending 卡片翻成来源列表
                        self.onSegmentsCallback?(self.accumulatedToolSegments)
                        self.fireAnthropicRound()
                    }
                }
                return
            }
            let allSegs = accumulatedToolSegments.isEmpty ? roundSegments : (accumulatedToolSegments + roundSegments)
            let hasTool = allSegs.contains {
                if case .toolUse = $0 { return true }
                if case .toolResult = $0 { return true }
                return false
            }
            DispatchQueue.main.async { [self] in
                isStreaming = false
                if hasTool {
                    onSegmentsCallback?(allSegs)
                }
                onComplete?(streamingContent, finalUsage)
            }

        case "error":
            if let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String {
                DispatchQueue.main.async { [self] in
                    isStreaming = false
                    error = message
                    onError?(message)
                }
            }

        default:
            break
        }
    }

    /// block 完成时转换为 MessageSegment 并追加到 pendingSegments。
    private func finalizeBlock(_ block: ActiveBlock) {
        switch block.kind {
        case .text:
            // 文本已实时累积到 streamingContent。非空时也追加到 segments。
            let text = block.accumulated
            if !text.isEmpty {
                pendingSegments.append(.text(text))
            }
        case .toolUse(let id, let rawName):
            // Q2: 去除 server name 前缀 ("imprint-memory__memory_remember" → "memory_remember")
            let parts = rawName.components(separatedBy: "__")
            let displayName = parts.count > 1 ? parts.dropFirst().joined(separator: "__") : rawName
            let serverName = parts.count > 1 ? parts[0] : nil
            pendingSegments.append(.toolUse(
                id: id,
                name: displayName,
                inputJSON: block.accumulated.isEmpty ? "{}" : block.accumulated,
                integrationName: serverName,
                iconName: nil
            ))
        case .toolResult(let toolUseId):
            pendingSegments.append(.toolResult(
                toolUseId: toolUseId,
                text: block.accumulated,
                isError: false,
                integrationName: nil
            ))
        }
    }

    // MARK: - Prompt caching helpers

    /// 分层 system → Anthropic content block 数组，层 1/层 2 末尾各打一个 ephemeral 断点。
    static func buildSystemBlocks(_ layers: SystemPromptLayers) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !layers.stableCore.isEmpty {
            blocks.append(["type": "text", "text": layers.stableCore, "cache_control": ["type": "ephemeral"]])
        }
        // BP2：摘要（30轮变一次，最稳定）
        if !layers.summaryLayer.isEmpty {
            blocks.append(["type": "text", "text": layers.summaryLayer, "cache_control": ["type": "ephemeral"]])
        }
        // 记忆+世界书（每轮可能变，不打断点——打了会破坏后面messages的缓存）
        if !layers.semiStable.isEmpty {
            blocks.append(["type": "text", "text": layers.semiStable])
        }
        if !layers.volatile.isEmpty {
            blocks.append(["type": "text", "text": layers.volatile])
        }
        return blocks
    }

    /// 稳定的 per-install user id，供 metadata.user_id 路由粘性用。
    static var stablePromptUserId: String {
        let key = "mpStablePromptUserId"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
}
