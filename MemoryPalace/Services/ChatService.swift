import Foundation
import UIKit

// MARK: - Chat Provider Protocol
// Concrete providers live in separate files:
// OpenAICompatibleProvider.swift / AnthropicProvider.swift
// ProviderRouter.swift / CCBridgeProvider.swift

@Observable
class BaseChatProvider: NSObject {
    var isStreaming = false
    var streamingContent = ""
    var error: String?

    var currentTask: URLSessionDataTask?
    var urlSession: URLSession?
    var buffer = ""
    var errorBody = ""
    var httpStatusCode: Int = 0
    var receivedDone = false
    var onToken: ((String) -> Void)?
    var onComplete: ((String, TokenUsage?) -> Void)?
    var onError: ((String) -> Void)?
    /// 目录化模式（MetaTools）：完整 MCP 工具目录，MCP 工具超过阈值时由 ProviderRouter 填入，
    /// 供 ToolCallLoop 处理 tool_search/tool_inspect/tool_invoke 时查目录/转发用。
    var metaToolCatalog: [MCPToolDescriptor] = []
    /// 流式过程中累积的 token 用量。usage 信息常在 stream 末尾或分事件到来。
    var accumulatedInputTokens: Int = 0
    var accumulatedOutputTokens: Int = 0
    var accumulatedCacheReadTokens: Int = 0
    var accumulatedCacheCreationTokens: Int = 0
    var gotUsage = false

    var finalUsage: TokenUsage? {
        gotUsage ? TokenUsage(
            inputTokens: accumulatedInputTokens,
            outputTokens: accumulatedOutputTokens,
            cacheReadInputTokens: accumulatedCacheReadTokens,
            cacheCreationInputTokens: accumulatedCacheCreationTokens
        ) : nil
    }

    func sendStreaming(
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
        fatalError("Subclass must implement")
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        urlSession = nil
        isStreaming = false
    }

    func resetState(onToken: @escaping (String) -> Void, onComplete: @escaping (String, TokenUsage?) -> Void, onError: @escaping (String) -> Void) {
        cancel()
        self.onToken = onToken
        self.onComplete = onComplete
        self.onError = onError
        self.streamingContent = ""
        self.error = nil
        self.isStreaming = true
        self.buffer = ""
        self.errorBody = ""
        self.httpStatusCode = 0
        self.receivedDone = false
        self.accumulatedInputTokens = 0
        self.accumulatedOutputTokens = 0
        self.accumulatedCacheReadTokens = 0
        self.accumulatedCacheCreationTokens = 0
        self.gotUsage = false
    }

    func startRequest(_ request: URLRequest) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session
        let task = session.dataTask(with: request)
        currentTask = task
        task.resume()
    }

    func handleErrorBody() -> String {
        var msg = "API 错误 (\(httpStatusCode))"
        if let data = errorBody.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let detail = err["message"] as? String {
                msg = detail
            } else if let err = obj["error"] as? String {
                msg = err
            }
        }
        return msg
    }

    /// 非流式调用 — 用于 memory agent 等后台任务
    func sendNonStreaming(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        apiKey: String,
        baseURL: String,
        extraHeaders: [String: String]
    ) async throws -> (String, TokenUsage?) {
        fatalError("Subclass must implement")
    }

    /// 从非流式响应体中提取错误信息
    static func extractError(from data: Data, statusCode: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return msg
            } else if let err = obj["error"] as? String {
                return err
            }
        }
        return "API 错误 (\(statusCode))"
    }
}

extension BaseChatProvider: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        processData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        DispatchQueue.main.async { [self] in
            let wasStreaming = isStreaming
            isStreaming = false
            urlSession = nil

            if let error = error as? NSError, error.code != NSURLErrorCancelled {
                let msg = error.localizedDescription
                self.error = msg
                onError?(msg)
                return
            }

            if receivedDone { return }

            if httpStatusCode != 0 && httpStatusCode != 200 {
                let msg = handleErrorBody()
                self.error = msg
                onError?(msg)
                return
            }

            if wasStreaming {
                if streamingContent.isEmpty {
                    let msg = "未收到回复"
                    self.error = msg
                    onError?(msg)
                } else {
                    onComplete?(streamingContent, finalUsage)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatusCode = http.statusCode
        }
        completionHandler(.allow)
    }

    /// Override in subclass for provider-specific SSE parsing
    @objc func processData(_ data: Data) {
        // default: no-op
    }
}
