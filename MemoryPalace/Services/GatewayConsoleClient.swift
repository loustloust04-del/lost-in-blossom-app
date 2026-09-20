import Foundation

/// 网关控制台数据客户端（只读 + 添加记忆）。
/// 复用 App 统一的 gatewayBaseURL / gatewayAuthToken（与 VitalsClient 同一约定）。
/// 端点对应 gateway/src/app.ts：/health /v1/models /api/memories(+dreams/desires/sync) /api/mcp/tools
enum GatewayConsoleClient {

    static var baseURL: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private static var token: String {
        UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
    }

    /// 鉴权诊断：任何请求撞上 401/403 置位，成功 200 清零。
    /// 此前所有方法静默吞错（try? + 空数组兜底），token 没配时控制台全是 0、
    /// 用户看不到任何原因——加载完读这个标志弹横幅指路。
    static var lastAuthFailed = false

    static var tokenConfigured: Bool { !token.isEmpty }

    static func saveConnection(baseURL: String, token: String) {
        UserDefaults.standard.set(baseURL, forKey: "gatewayBaseURL")
        UserDefaults.standard.set(token, forKey: "gatewayAuthToken")
    }

    /// 连接测试：打一个必须鉴权的端点，返回 (HTTP 状态码, 人话结论)。
    /// 用显式参数而不是 UserDefaults，让设置页保存前就能试。
    static func testConnection(baseURL: String, token: String) async -> (Int?, String) {
        guard let url = URL(string: baseURL + "/api/memories?limit=1") else { return (nil, "地址格式不对") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return (nil, "连不上网关（网络或域名问题）") }
        switch http.statusCode {
        case 200: return (200, "连接成功，鉴权通过")
        case 401, 403: return (http.statusCode, "网关拒绝了这个令牌（HTTP \(http.statusCode)）")
        default: return (http.statusCode, "网关返回 HTTP \(http.statusCode)")
        }
    }

    /// 只置位不清零：loadAll 并发打 6 个端点，/health 这类无鉴权端点的 200
    /// 会晚到并把 401 置的标志洗掉。批次开始时由调用方 resetAuthFlag()。
    private static func noteStatus(_ code: Int) {
        if code == 401 || code == 403 { lastAuthFailed = true }
    }

    static func resetAuthFlag() { lastAuthFailed = false }

    private static func get(_ path: String, timeout: TimeInterval = 8) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            noteStatus(http.statusCode)
            if http.statusCode != 200 { throw URLError(.badServerResponse) }
        }
        return data
    }

    /// Supabase 主键有的表是 uuid（String）有的是 int8——统一解码成 String
    struct FlexID: Codable, Hashable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else if let i = try? c.decode(Int.self) { value = String(i) }
            else { value = UUID().uuidString }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }

    // MARK: - Health

    struct HealthInfo {
        let ok: Bool
        let memoryConnected: Bool
        let latencyMs: Int
    }
    private struct HealthResp: Codable { let status: String; let memory: String }

    static func health() async -> HealthInfo? {
        let start = Date()
        guard let data = try? await get("/health", timeout: 5),
              let h = try? JSONDecoder().decode(HealthResp.self, from: data) else { return nil }
        return HealthInfo(
            ok: h.status == "ok",
            memoryConnected: h.memory == "connected",
            latencyMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    // MARK: - Models

    struct GatewayModel: Codable, Identifiable {
        let id: String
        let owned_by: String
    }
    private struct ModelsResp: Codable { let data: [GatewayModel] }

    static func models() async -> [GatewayModel] {
        guard let data = try? await get("/v1/models"),
              let r = try? JSONDecoder().decode(ModelsResp.self, from: data) else { return [] }
        return r.data
    }

    // MARK: - Memories

    struct GatewayMemory: Codable, Identifiable {
        let id: String
        let content: String
        let tier: Int?
        let category: String?
        let is_pinned: Bool?
        let source: String?
        let created_at: String?
    }
    private struct MemoriesResp: Codable {
        let memories: [GatewayMemory]
        let total: Int?
    }

    static func memories(limit: Int = 50, offset: Int = 0, category: String? = nil) async -> (items: [GatewayMemory], total: Int) {
        var path = "/api/memories?limit=\(limit)&offset=\(offset)"
        if let category, !category.isEmpty,
           let enc = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&category=\(enc)"
        }
        guard let data = try? await get(path),
              let r = try? JSONDecoder().decode(MemoriesResp.self, from: data) else { return ([], 0) }
        return (r.memories, r.total ?? r.memories.count)
    }

    /// 手动添加一条记忆（POST /api/memories/sync，网关侧标 source='manual' 并查重）。
    /// 返回 true = 已入库；false = 被查重跳过或失败。
    static func addMemory(content: String, category: String?, tier: Int = 3) async -> Bool {
        guard let url = URL(string: baseURL + "/api/memories/sync") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var mem: [String: Any] = ["content": content, "tier": tier]
        if let category, !category.isEmpty { mem["category"] = category }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["memories": [mem]])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (obj["added"] as? Int ?? 0) > 0
    }

    // MARK: - Dreams / Desires

    struct GatewayDream: Codable, Identifiable {
        let id: FlexID
        let date: String?
        let layer: String?
        let summary: String?
        let created_at: String?
    }
    private struct DreamsResp: Codable { let dreams: [GatewayDream] }

    static func dreams() async -> [GatewayDream] {
        guard let data = try? await get("/api/memories/dreams"),
              let r = try? JSONDecoder().decode(DreamsResp.self, from: data) else { return [] }
        return r.dreams
    }

    struct GatewayDesire: Codable, Identifiable {
        let id: String
        let content: String
        let created_at: String?
    }
    private struct DesiresResp: Codable { let desires: [GatewayDesire] }

    static func desires(limit: Int = 20) async -> [GatewayDesire] {
        guard let data = try? await get("/api/memories/desires?limit=\(limit)"),
              let r = try? JSONDecoder().decode(DesiresResp.self, from: data) else { return [] }
        return r.desires
    }

    // MARK: - MCP 工具

    struct GatewayTool: Codable, Identifiable {
        let name: String
        let description: String?
        let source: String?
        var id: String { name }
    }
    private struct ToolsResp: Decodable {
        let tools: [GatewayTool]
        let count: Int?
        // 单条工具缺 name（网关历史畸形数据）不再拖垮整份列表解码——逐条容错跳过
        private enum CodingKeys: String, CodingKey { case tools, count }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? nil
            var arr = try c.nestedUnkeyedContainer(forKey: .tools)
            var out: [GatewayTool] = []
            while !arr.isAtEnd {
                if let t = try? arr.decode(GatewayTool.self) { out.append(t) }
                else { _ = try? arr.decode(SkipOne.self) }
            }
            tools = out
        }
    }
    private struct SkipOne: Decodable {}

    static func mcpTools() async -> [GatewayTool] {
        guard let data = try? await get("/api/mcp/tools", timeout: 12),
              let r = try? JSONDecoder().decode(ToolsResp.self, from: data) else { return [] }
        return r.tools
    }

    // MARK: - Admin 通用请求

    private static func send(_ path: String, method: String, json: [String: Any]? = nil, timeout: TimeInterval = 8) async -> [String: Any]? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        noteStatus(http.statusCode)
        guard http.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func sendOK(_ path: String, method: String, json: [String: Any]? = nil) async -> Bool {
        (await send(path, method: method, json: json))?["ok"] as? Bool ?? false
    }

    // MARK: - Admin：记忆管理

    static func deleteMemory(id: String) async -> Bool {
        await sendOK("/api/admin/memories/\(id)", method: "DELETE")
    }

    static func pinMemory(id: String, pinned: Bool) async -> Bool {
        await sendOK("/api/admin/memories/\(id)/pin", method: "POST", json: ["pinned": pinned])
    }

    // MARK: - Admin：通道 key 管理

    struct GatewayChannel: Codable, Identifiable {
        let name: String
        let configured: Bool
        let masked: String
        let overridden: Bool
        var id: String { name }
    }
    private struct ChannelsResp: Codable { let channels: [GatewayChannel] }

    static func channels() async -> [GatewayChannel] {
        guard let data = try? await get("/api/admin/channels"),
              let r = try? JSONDecoder().decode(ChannelsResp.self, from: data) else { return [] }
        return r.channels
    }

    static func setChannelKey(name: String, key: String) async -> Bool {
        await sendOK("/api/admin/channels/\(name)/key", method: "PUT", json: ["key": key])
    }

    /// 清除覆盖，回落到网关启动时的 env 值
    static func clearChannelKey(name: String) async -> Bool {
        await sendOK("/api/admin/channels/\(name)/key", method: "DELETE")
    }

    // MARK: - Admin：定时任务（VPS crontab）

    struct GatewayCronJob: Codable, Identifiable {
        let idx: Int
        let line: String
        let enabled: Bool
        var id: Int { idx }
    }
    private struct CronResp: Codable { let jobs: [GatewayCronJob] }

    static func cronJobs() async -> [GatewayCronJob] {
        guard let data = try? await get("/api/admin/cron"),
              let r = try? JSONDecoder().decode(CronResp.self, from: data) else { return [] }
        return r.jobs
    }

    /// toggle/delete 都带当前行原文，网关侧校验防并发漂移误改
    static func cronToggle(job: GatewayCronJob, enabled: Bool) async -> Bool {
        await sendOK("/api/admin/cron/toggle", method: "POST",
                     json: ["idx": job.idx, "line": job.line, "enabled": enabled])
    }

    static func cronAdd(line: String) async -> Bool {
        await sendOK("/api/admin/cron/add", method: "POST", json: ["line": line])
    }

    static func cronDelete(job: GatewayCronJob) async -> Bool {
        await sendOK("/api/admin/cron/delete", method: "POST",
                     json: ["idx": job.idx, "line": job.line])
    }

    // MARK: - Admin：MCP 服务器管理

    struct MCPServer: Codable, Identifiable {
        let name: String
        let url: String
        let ok: Bool
        let toolCount: Int
        let ms: Int
        let error: String?
        var id: String { name }
    }
    private struct MCPServersResp: Codable {
        let servers: [MCPServer]
        let managed: Bool
    }

    /// 服务器列表 + 逐台探活（网关侧并行探，探活可能要几秒）
    static func mcpServers() async -> [MCPServer] {
        guard let data = try? await get("/api/admin/mcp/servers", timeout: 30),
              let r = try? JSONDecoder().decode(MCPServersResp.self, from: data) else { return [] }
        return r.servers
    }

    /// 添加服务器（网关先探活，探不通默认拒绝；force=true 强行加）。
    /// 返回 (成功?, 错误信息)。
    static func addMcpServer(name: String?, url: String, force: Bool) async -> (Bool, String?) {
        guard let reqURL = URL(string: baseURL + "/api/admin/mcp/servers") else { return (false, "bad url") }
        var req = URLRequest(url: reqURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["url": url, "force": force]
        if let name, !name.isEmpty { body["name"] = name }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (false, "网关无响应")
        }
        let ok = obj["ok"] as? Bool ?? false
        return (ok, ok ? nil : (obj["error"] as? String ?? "未知错误"))
    }

    static func deleteMcpServer(name: String) async -> Bool {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return await sendOK("/api/admin/mcp/servers/\(enc)", method: "DELETE")
    }

    /// 手动刷新网关工具缓存
    static func refreshMcpTools() async -> Bool {
        await sendOK("/api/admin/mcp/refresh", method: "POST")
    }
}
