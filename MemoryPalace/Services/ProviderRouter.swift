import Foundation

// MARK: - Provider Router

@Observable
final class ProviderRouter {
    private var openAIProvider = OpenAICompatibleProvider()
    private var anthropicProvider = AnthropicProvider()
    private var ccBridgeProvider = CCBridgeProvider()

    var isStreaming: Bool {
        openAIProvider.isStreaming || anthropicProvider.isStreaming || ccBridgeProvider.isStreaming
    }

    var streamingContent: String {
        if openAIProvider.isStreaming || !openAIProvider.streamingContent.isEmpty {
            return openAIProvider.streamingContent
        }
        if anthropicProvider.isStreaming || !anthropicProvider.streamingContent.isEmpty {
            return anthropicProvider.streamingContent
        }
        return ccBridgeProvider.streamingContent
    }

    var error: String? {
        openAIProvider.error ?? anthropicProvider.error ?? ccBridgeProvider.error
    }

    func sendStreaming(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        systemLayers: SystemPromptLayers? = nil,
        providerManager: ProviderManager,
        samplingParams: SamplingParams? = nil,
        additionalHeaders: [String: String] = [:],
        onSegments: (([MessageSegment]) -> Void)? = nil,
        onThinkingToken: ((String) -> Void)? = nil,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (String, TokenUsage?) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard let provider = providerManager.provider(for: model) else {
            onError("找不到提供商: \(model.providerId)")
            return
        }

        // ccBridge 不要求 apiKey（WebSocket 本地连接，没有云端鉴权）
        let apiKey: String
        if provider.type == .ccBridge {
            apiKey = ""
        } else {
            guard let key = providerManager.apiKey(for: provider.id) else {
                onError("未设置 \(provider.name) 的 API Key")
                return
            }
            apiKey = key
        }

        let chatProvider: BaseChatProvider
        switch provider.type {
        case .openaiCompatible:
            openAIProvider.onSegmentsCallback = onSegments
            openAIProvider.onThinkingToken = onThinkingToken
            // PR-3: REST bridge 客户端工具（function calling）
            // MetaTools 目录化：MCP 工具超阈值时只注入 3 个元工具，完整目录进 metaToolCatalog。
            let oaiMCPTools = sanitizedBridgeTools()
            if oaiMCPTools.count > ProviderRouter.metaToolThreshold {
                openAIProvider.bridgeTools = MetaTools.toolDescriptors
                openAIProvider.metaToolCatalog = oaiMCPTools
            } else {
                openAIProvider.bridgeTools = oaiMCPTools
                openAIProvider.metaToolCatalog = []
            }
            if MCPBridgeConfig.isConfigured { Task { _ = try? await MCPService.shared.fetchTools() } }
            chatProvider = openAIProvider
        case .anthropic:
            // MCP 服务器注入：provider 为 anthropic 且 mcpEnabled 不为 false 时
            let mcpEnabled = samplingParams?.mcpEnabled ?? true
            anthropicProvider.mcpServersToInject = mcpEnabled ? provider.mcpServers.filter(\.isEnabled) : []
            anthropicProvider.onSegmentsCallback = onSegments
            // PR-2: REST bridge 客户端工具（所有 provider 可用）。同步读快照，异步预热下一轮。
            // MetaTools 目录化：MCP 工具超阈值时只注入 3 个元工具，完整目录进 metaToolCatalog。
            let antMCPTools = sanitizedBridgeTools()
            if antMCPTools.count > ProviderRouter.metaToolThreshold {
                anthropicProvider.bridgeTools = MetaTools.toolDescriptors
                anthropicProvider.metaToolCatalog = antMCPTools
            } else {
                anthropicProvider.bridgeTools = antMCPTools
                anthropicProvider.metaToolCatalog = []
            }
            if MCPBridgeConfig.isConfigured { Task { _ = try? await MCPService.shared.fetchTools() } }
            chatProvider = anthropicProvider
        case .ccBridge:
            ccBridgeProvider.onSegmentsCallback = onSegments
            chatProvider = ccBridgeProvider
        }

        let mergedHeaders = provider.extraHeaders.merging(additionalHeaders) { _, new in new }
        let effectiveMessages = modelSupportsVision(model: model, provider: provider)
            ? messages
            : filterImageBlocks(from: messages)
        chatProvider.sendStreaming(
            messages: effectiveMessages,
            model: model.modelId,
            systemPrompt: systemPrompt,
            systemLayers: systemLayers,
            apiKey: apiKey,
            baseURL: provider.baseURL,
            extraHeaders: mergedHeaders,
            samplingParams: samplingParams,
            onToken: onToken,
            onComplete: onComplete,
            onError: onError
        )
    }

    /// MetaTools 目录化阈值：MCP 工具数超过它就只注入 3 个元工具（详见 applyBridgeTools 内联逻辑）。
    private static let metaToolThreshold = 15

    /// 桥工具净化：剔除与本地同名的 search_web / browse_url，并按名字兜底去重。
    /// ⚠️ 搜索/浏览工具由各 Provider 内部原生注入（OpenAICompatibleProvider 与
    /// AnthropicProvider 各自的 isSearchEnabledFlag 分支），Router 层【不要】再注入——
    /// 此前两层双注入导致 OpenAI 兼容端报 "Tool names must be unique"。
    private func sanitizedBridgeTools() -> [MCPToolDescriptor] {
        let reserved: Set<String> = [WebSearchToolService.toolName, BrowseURLTool.toolName]
        let tools = (MCPBridgeConfig.isConfigured ? MCPToolCache.shared.tools : [])
            .filter { !reserved.contains($0.name) }
        var seen = Set<String>()
        return tools.filter { seen.insert($0.name).inserted }
    }


    private func modelSupportsVision(model: ProviderModel, provider: APIProvider) -> Bool {
        switch provider.type {
        case .anthropic, .ccBridge:
            return true
        case .openaiCompatible:
            let mid = model.modelId.lowercased()
            if mid.contains("deepseek") { return false }
            if mid.contains("gpt-3.5") { return false }
            return true
        }
    }

    private func filterImageBlocks(from messages: [(role: String, content: String)]) -> [(role: String, content: String)] {
        return messages.map { msg in
            guard msg.role == "user",
                  msg.content.hasPrefix("[{"),
                  let data = msg.content.data(using: .utf8),
                  let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                return msg
            }
            var filtered: [[String: Any]] = []
            for block in blocks {
                if (block["type"] as? String) == "image" {
                    filtered.append(["type": "text", "text": "[图片]"])
                } else {
                    filtered.append(block)
                }
            }
            if filtered.count == 1,
               filtered[0]["type"] as? String == "text",
               let text = filtered[0]["text"] as? String {
                return (role: msg.role, content: text)
            }
            guard let json = try? JSONSerialization.data(withJSONObject: filtered),
                  let str = String(data: json, encoding: .utf8) else {
                return msg
            }
            return (role: msg.role, content: str)
        }
    }

    /// 非流式调用 — 用于 memory agent 等后台任务
    func sendNonStreaming(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager
    ) async throws -> (String, TokenUsage?) {
        guard let provider = providerManager.provider(for: model) else {
            throw NSError(domain: "ProviderRouter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到提供商: \(model.providerId)"])
        }

        // ccBridge 不要求 apiKey（WebSocket 本地连接，没有云端鉴权）
        let apiKey: String
        if provider.type == .ccBridge {
            apiKey = ""
        } else {
            guard let key = providerManager.apiKey(for: provider.id) else {
                throw NSError(domain: "ProviderRouter", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "未设置 \(provider.name) 的 API Key"])
            }
            apiKey = key
        }

        let chatProvider: BaseChatProvider
        switch provider.type {
        case .openaiCompatible:
            chatProvider = OpenAICompatibleProvider() // 独立实例，避免干扰流式
        case .anthropic:
            chatProvider = AnthropicProvider()
        case .ccBridge:
            chatProvider = CCBridgeProvider() // 独立实例（内部用 shared WS singleton）
        }

        return try await chatProvider.sendNonStreaming(
            messages: messages,
            model: model.modelId,
            systemPrompt: systemPrompt,
            apiKey: apiKey,
            baseURL: provider.baseURL,
            extraHeaders: provider.extraHeaders
        )
    }

    /// 思考完成后，用当前 provider 异步生成一句话总结（不阻塞正文流式）
    /// - Returns: 总结文本，失败时返回 nil
    func summarizeThinking(
        thinkingText: String,
        model: ProviderModel,
        providerManager: ProviderManager
    ) async -> String? {
        guard !thinkingText.isEmpty else { return nil }
        let truncated = String(thinkingText.prefix(1500))
        let prompt = "请用一句话（不超过20字）概括以下AI的思考过程：\n\n\(truncated)"
        let messages: [(role: String, content: String)] = [(role: "user", content: prompt)]
        guard let result = try? await sendNonStreaming(
            model: model,
            messages: messages,
            systemPrompt: nil,
            providerManager: providerManager
        ) else { return nil }
        let summary = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    func cancel() {
        cancelAPI()
        cancelCC()
    }

    /// 只取消 API 车道（openAI/anthropic），不打断 CC 的等待
    func cancelAPI() {
        openAIProvider.cancel()
        anthropicProvider.cancel()
    }

    /// 只取消 CC 车道，不打断 API 流
    func cancelCC() {
        CCBridgeWebSocketClient.shared.unregisterStreamHandler()
        ccBridgeProvider.cancel()
    }
}
