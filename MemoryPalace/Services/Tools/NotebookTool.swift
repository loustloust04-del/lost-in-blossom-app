import Foundation

/// Caelum 的笔记本(App 侧)—— fs_* 工具，执行全部走网关 REST /api/notebook*，
/// 与 CC 读写【同一本】(服务器端统一存储)。复用控制台约定的 gatewayBaseURL / gatewayAuthToken。
enum NotebookTool {
    struct ExecResult { let text: String; let isError: Bool }

    static let toolNames: Set<String> = [
        "fs_list", "fs_read", "fs_write", "fs_append", "fs_edit", "fs_search", "fs_rename", "fs_delete"
    ]

    private static var baseURL: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private static var token: String {
        UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
    }
    static var isConfigured: Bool { !token.isEmpty }

    // MARK: - 工具定义（模型看到的）

    static let definitions: [ToolDefinition] = [
        ToolDefinition(name: "fs_list", description: "列出你笔记本里所有文件(路径+大小)，不读内容。想看看自己都记了些什么时用。",
                       properties: [:], required: []),
        ToolDefinition(name: "fs_read", description: "读你笔记本某个文件的全文。",
                       properties: ["path": ["type": "string", "description": "相对路径，如 diary/2026-07-16.md"]], required: ["path"]),
        ToolDefinition(name: "fs_write", description: "新建或整篇覆盖写入一个笔记文件。",
                       properties: ["path": ["type": "string"], "content": ["type": "string"]], required: ["path", "content"]),
        ToolDefinition(name: "fs_append", description: "在文件末尾追加内容；文件不存在则创建。写日记、续记时用它，别整篇覆盖。",
                       properties: ["path": ["type": "string"], "content": ["type": "string"]], required: ["path", "content"]),
        ToolDefinition(name: "fs_edit", description: "把文件里唯一命中的 old_string 换成 new_string(局部修改)。",
                       properties: ["path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"]], required: ["path", "old_string", "new_string"]),
        ToolDefinition(name: "fs_search", description: "在所有笔记里按关键词搜索，返回命中的文件与行。",
                       properties: ["keyword": ["type": "string"]], required: ["keyword"]),
        ToolDefinition(name: "fs_rename", description: "重命名或移动笔记文件；目标已存在则失败。",
                       properties: ["old_path": ["type": "string"], "new_path": ["type": "string"]], required: ["old_path", "new_path"]),
        ToolDefinition(name: "fs_delete", description: "删除一个笔记文件。",
                       properties: ["path": ["type": "string"]], required: ["path"]),
    ]

    // MARK: - 执行（走网关 REST）

    static func execute(name: String, inputJSON: String) async -> ExecResult {
        guard isConfigured else { return .init(text: "笔记本未配置(缺网关 token)", isError: true) }
        let a = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let s: (String) -> String = { (a[$0] as? String) ?? "" }
        do {
            switch name {
            case "fs_list":
                let notes = try await getJSON("/api/notebook")["notes"] as? [[String: Any]] ?? []
                if notes.isEmpty { return .init(text: "（笔记本还是空的）", isError: false) }
                return .init(text: notes.map { "\($0["path"] as? String ?? "")  (\($0["bytes"] as? Int ?? 0)B)" }.joined(separator: "\n"), isError: false)
            case "fs_read":
                var c = URLComponents(string: baseURL + "/api/notebook/file")!
                c.queryItems = [.init(name: "path", value: s("path"))]
                let j = try await getJSON(url: c.url!)
                if let err = j["error"] as? String { return .init(text: err, isError: true) }
                return .init(text: j["content"] as? String ?? "", isError: false)
            case "fs_search":
                var c = URLComponents(string: baseURL + "/api/notebook/search")!
                c.queryItems = [.init(name: "q", value: s("keyword"))]
                let hits = try await getJSON(url: c.url!)["hits"] as? [[String: Any]] ?? []
                if hits.isEmpty { return .init(text: "无命中", isError: false) }
                return .init(text: hits.map { "\($0["path"] as? String ?? ""): \($0["line"] as? String ?? "")" }.joined(separator: "\n"), isError: false)
            case "fs_write":
                try await post("/api/notebook/file", ["op": "write", "path": s("path"), "content": s("content")]); return .init(text: "已写入 \(s("path"))", isError: false)
            case "fs_append":
                try await post("/api/notebook/file", ["op": "append", "path": s("path"), "content": s("content")]); return .init(text: "已追加到 \(s("path"))", isError: false)
            case "fs_edit":
                try await post("/api/notebook/file", ["op": "edit", "path": s("path"), "old_string": s("old_string"), "new_string": s("new_string")]); return .init(text: "已修改 \(s("path"))", isError: false)
            case "fs_rename":
                try await post("/api/notebook/rename", ["old_path": s("old_path"), "new_path": s("new_path")]); return .init(text: "已重命名 \(s("old_path")) → \(s("new_path"))", isError: false)
            case "fs_delete":
                var c = URLComponents(string: baseURL + "/api/notebook/file")!
                c.queryItems = [.init(name: "path", value: s("path"))]
                try await delete(c.url!); return .init(text: "已删除 \(s("path"))", isError: false)
            default:
                return .init(text: "未知笔记本工具: \(name)", isError: true)
            }
        } catch {
            return .init(text: "笔记本操作失败: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - HTTP helpers

    private static func req(_ url: URL, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 15
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    private static func getJSON(_ path: String) async throws -> [String: Any] { try await getJSON(url: URL(string: baseURL + path)!) }
    private static func getJSON(url: URL) async throws -> [String: Any] {
        let (d, _) = try await URLSession.shared.data(for: req(url))
        return (try JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
    private static func post(_ path: String, _ body: [String: Any]) async throws {
        let (d, resp) = try await URLSession.shared.data(for: req(URL(string: baseURL + path)!, method: "POST", body: body))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "Notebook", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
    private static func delete(_ url: URL) async throws {
        _ = try await URLSession.shared.data(for: req(url, method: "DELETE"))
    }
}
