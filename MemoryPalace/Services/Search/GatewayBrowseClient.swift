import Foundation

/// 网关浏览：GET {gatewayBaseURL}/api/browse?url=...
/// 网关侧用 VPS 的真 Chrome（playwright）抓正文——绕开手机本地离屏 WKWebView 的
/// iOS 前后台 / 低电量节流坑（HTTPS 全超时的根因）。免第三方 key、过反爬墙。
/// 复用与控制台/搜索同一约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"。
enum GatewayBrowseClient {
    struct Page {
        let title: String
        let url: String
        let text: String
        let length: Int
        let truncated: Bool
    }

    enum BrowseError: LocalizedError {
        case notConfigured
        case http(Int, String)
        case decode(String)
        case remote(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured:   return "网关未配置（设置 → 控制台 → 网关 token）"
            case .http(let c, _):  return "网关返回 HTTP \(c)"
            case .decode(let m):   return "网关响应解析失败：\(m)"
            case .remote(let m):   return m
            }
        }
    }

    private static var baseURL: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private static var token: String {
        UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
    }

    /// 有 token 才认为网关可用（baseURL 有默认值）
    static var isConfigured: Bool { !token.isEmpty }

    static func read(url: URL, timeout: TimeInterval = 35) async throws -> Page {
        let tk = token
        guard !tk.isEmpty else { throw BrowseError.notConfigured }

        var comps = URLComponents(string: baseURL + "/api/browse")
        comps?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let reqURL = comps?.url else { throw BrowseError.notConfigured }

        var req = URLRequest(url: reqURL)
        // 真浏览器抓取比 API 慢，给足超时（网关侧还有并发闸排队）
        req.timeoutInterval = timeout
        req.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw BrowseError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowseError.decode("not JSON")
        }
        if let err = json["error"] as? String { throw BrowseError.remote(err) }

        let text = json["text"] as? String ?? ""
        return Page(
            title: json["title"] as? String ?? "",
            url: json["url"] as? String ?? url.absoluteString,
            text: text,
            length: json["length"] as? Int ?? text.count,
            truncated: json["truncated"] as? Bool ?? false
        )
    }
}
