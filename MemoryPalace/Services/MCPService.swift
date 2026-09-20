import Foundation

// MARK: - Models

/// 一个可调用的 MCP 工具（来自 mcp-rest-bridge.js 的 GET /mcp/tools）。
/// inputSchema 以 JSON 字符串保存，方便 PR-2/PR-3 原样拼进 Anthropic `input_schema`
/// 或 OpenAI function `parameters`，无需 AnyCodable。
struct MCPToolDescriptor: Identifiable, Hashable {
    var id: String { "\(server)/\(name)" }
    let server: String
    let name: String
    let description: String
    /// 原始 inputSchema 的 JSON 文本（object）。缺失时为 "{}"。
    let inputSchemaJSON: String
}

/// MCP 工具返回的一个 content block（{type, text}）。callTool 把 bridge 的
/// `result` 数组解析成这个，PR-2/3 再转成 tool_result 文本。
struct MCPContentBlock: Hashable {
    let type: String
    let text: String?

    /// 把多个 content block 拍平成给模型看的纯文本 tool_result。
    static func flatten(_ blocks: [MCPContentBlock]) -> String {
        blocks.compactMap { $0.text }.joined(separator: "\n")
    }
}

enum MCPError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "MCP 工具桥未配置（缺 baseURL 或 token）"
        case .badURL:        return "MCP 工具桥 baseURL 无效"
        case .http(let c, let m): return "MCP 工具桥 HTTP \(c): \(m)"
        case .decode(let m): return "MCP 工具桥响应解析失败: \(m)"
        }
    }
}

// MARK: - Bridge config（baseURL 进 UserDefaults，token 进 Keychain）

enum MCPBridgeConfig {
    static let baseURLKey = "mcpBridgeBaseURL"
    static let tokenAccount = "mcpBridgeToken"

    static var baseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static var token: String {
        KeychainStore.get(account: tokenAccount) ?? ""
    }
    static var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    /// 供 MCPSettingsTab「工具桥」区块调用。token 不进 UserDefaults。
    static func save(baseURL: String, token: String, syncToken: Bool = false) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: baseURLKey)
        KeychainStore.set(token.trimmingCharacters(in: .whitespaces),
                          account: tokenAccount, sync: syncToken)
    }
}

// MARK: - MCPService（REST bridge 客户端）

/// 对接 mcp-rest-bridge.js：GET /mcp/tools 拉工具列表（5 分钟内存缓存），
/// POST /mcp/call 执行工具。所有 provider 的 tool-calling 循环（PR-2/PR-3）共用它。
actor MCPService {
    static let shared = MCPService()

    private var cachedTools: [MCPToolDescriptor] = []
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300  // 5 分钟

    private func makeRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        let base = MCPBridgeConfig.baseURL
        let token = MCPBridgeConfig.token
        guard !base.isEmpty, !token.isEmpty else { throw MCPError.notConfigured }
        guard let url = URL(string: base.hasSuffix("/") ? base + String(path.dropFirst())
                                                        : base + path) else {
            throw MCPError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = body
        return req
    }

    private func send(_ req: URLRequest) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        if code < 200 || code >= 300 {
            let msg = (json as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw MCPError.http(code, msg)
        }
        guard let json else { throw MCPError.decode("非 JSON 响应") }
        return json
    }

    /// 拉工具列表。默认走 5 分钟缓存，forceRefresh 跳过。
    func fetchTools(forceRefresh: Bool = false) async throws -> [MCPToolDescriptor] {
        if !forceRefresh, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL, !cachedTools.isEmpty {
            return cachedTools
        }
        let req = try makeRequest(path: "/mcp/tools", method: "GET")
        let json = try await send(req)
        guard let obj = json as? [String: Any],
              let rawTools = obj["tools"] as? [[String: Any]] else {
            throw MCPError.decode("缺 tools 数组")
        }
        let tools: [MCPToolDescriptor] = rawTools.map { t in
            let schema = t["inputSchema"] as? [String: Any] ?? [:]
            let schemaJSON: String = {
                guard let d = try? JSONSerialization.data(withJSONObject: schema),
                      let s = String(data: d, encoding: .utf8) else { return "{}" }
                return s
            }()
            return MCPToolDescriptor(
                server: t["server"] as? String ?? "",
                name: t["name"] as? String ?? "",
                description: t["description"] as? String ?? "",
                inputSchemaJSON: schemaJSON
            )
        }
        cachedTools = tools
        cacheTimestamp = Date()
        let snapshot = tools
        DispatchQueue.main.async { MCPToolCache.shared.update(snapshot) }
        return tools
    }

    /// 执行一个工具。arguments 为 JSON object（[String: Any]）。
    func callTool(server: String, tool: String, arguments: [String: Any]) async throws -> [MCPContentBlock] {
        let payload: [String: Any] = ["server": server, "tool": tool, "arguments": arguments]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest(path: "/mcp/call", method: "POST", body: body)
        let json = try await send(req)
        guard let obj = json as? [String: Any] else { throw MCPError.decode("非 object 响应") }
        // bridge 返回 { result: [ {type, text}, ... ] }
        let rawResult = obj["result"]
        let blocks: [[String: Any]]
        if let arr = rawResult as? [[String: Any]] {
            blocks = arr
        } else if let str = rawResult as? String {
            return [MCPContentBlock(type: "text", text: str)]
        } else {
            blocks = []
        }
        return blocks.map { b in
            MCPContentBlock(type: b["type"] as? String ?? "text", text: b["text"] as? String)
        }
    }

    /// 清缓存（设置里改了 bridge 配置后调用）。
    func invalidateCache() {
        cachedTools = []
        cacheTimestamp = nil
    }
}


// MARK: - 同步快照

/// providers 的 sendStreaming 是同步的，需要在构造请求体前同步拿到工具列表。
/// MCPService（actor）异步刷新后把结果推到这里，ProviderRouter 同步读取。
/// Swift 5 下普通单例即可；读写约定在主线程。
final class MCPToolCache {
    static let shared = MCPToolCache()
    private(set) var tools: [MCPToolDescriptor] = []
    func update(_ t: [MCPToolDescriptor]) { tools = t }
}
