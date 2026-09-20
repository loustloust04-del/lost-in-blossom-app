import Foundation

/// 服务器端笔记本的 UI 侧读写口子。
///
/// 和 `NotebookTool` 打的是同一套 REST（/api/notebook*）、同一本笔记 ——
/// 区别只在使用者：那边是给模型调的 fs_* 工具，这边是给界面用的。
/// 之所以不直接复用 NotebookTool，是它的 HTTP helper 全是 private，
/// 且返回值是拼给模型看的文本；界面需要的是结构化的 FileMeta。
///
/// 与 `FileLibraryStore` 的关系：那个存在手机本地 App Support 里、按 profile 分库、
/// 离线可用；这个存在服务器上、全局一本、CC 和 App 共享。两套互不相通，
/// 文件库面板把它们并列成两个来源，让人自己选看哪边。
enum NotebookRemoteStore {
    struct FileMeta: Identifiable, Codable, Equatable {
        let path: String
        let bytes: Int
        var id: String { path }
    }

    private static var baseURL: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private static var token: String {
        UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
    }

    /// 没配网关 token 就没法访问服务器笔记本，界面据此决定要不要显示这个来源。
    static var isConfigured: Bool { !token.isEmpty }

    // MARK: - 读

    static func list() async throws -> [FileMeta] {
        let notes = try await getJSON("/api/notebook")["notes"] as? [[String: Any]] ?? []
        return notes.compactMap { n in
            guard let p = n["path"] as? String, !p.isEmpty else { return nil }
            return FileMeta(path: p, bytes: n["bytes"] as? Int ?? 0)
        }.sorted { $0.path < $1.path }
    }

    static func read(_ path: String) async throws -> String {
        var c = URLComponents(string: baseURL + "/api/notebook/file")!
        c.queryItems = [.init(name: "path", value: path)]
        let j = try await getJSON(url: c.url!)
        if let err = j["error"] as? String { throw fail(err) }
        return j["content"] as? String ?? ""
    }

    // MARK: - 写

    static func write(_ path: String, content: String) async throws {
        try await post("/api/notebook/file", ["path": path, "content": content])
    }

    /// 末尾追加（Gateway op=append）
    static func append(_ path: String, content: String) async throws {
        try await post("/api/notebook/file", ["op": "append", "path": path, "content": content])
    }

    /// 局部替换（Gateway op=edit）
    static func edit(_ path: String, oldString: String, newString: String) async throws {
        try await post("/api/notebook/file", ["op": "edit", "path": path,
                                              "old_string": oldString, "new_string": newString])
    }

    /// 全文搜索
    static func search(_ keyword: String) async throws -> [String] {
        var c = URLComponents(string: baseURL + "/api/notebook/search")!
        c.queryItems = [.init(name: "q", value: keyword)]
        let j = try await getJSON(url: c.url!)
        return (j["hits"] as? [Any])?.compactMap { hit in
            if let s = hit as? String { return s }
            if let d = hit as? [String: Any] { return d["path"] as? String }
            return nil
        } ?? []
    }

    static func rename(_ oldPath: String, to newPath: String) async throws {
        try await post("/api/notebook/rename", ["old_path": oldPath, "new_path": newPath])
    }

    static func delete(_ path: String) async throws {
        var c = URLComponents(string: baseURL + "/api/notebook/file")!
        c.queryItems = [.init(name: "path", value: path)]
        _ = try await URLSession.shared.data(for: req(c.url!, method: "DELETE"))
    }

    // MARK: - HTTP

    private static func fail(_ msg: String) -> NSError {
        NSError(domain: "NotebookRemote", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func req(_ url: URL, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if !token.isEmpty { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private static func getJSON(_ path: String) async throws -> [String: Any] {
        try await getJSON(url: URL(string: baseURL + path)!)
    }

    private static func getJSON(url: URL) async throws -> [String: Any] {
        let (d, _) = try await URLSession.shared.data(for: req(url))
        return (try JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws {
        let (d, resp) = try await URLSession.shared.data(for: req(URL(string: baseURL + path)!, method: "POST", body: body))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw fail(msg)
        }
    }
}
