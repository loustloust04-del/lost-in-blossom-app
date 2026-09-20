import Foundation

/// 网关搜索 provider：GET {gatewayBaseURL}/api/search?q=...
/// 网关侧用 VPS 的真 Chrome（playwright）跑 Google/DDG——免第三方 key、过反爬墙。
/// 复用全局约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"（与控制台同一个 token）。
struct GatewaySearchProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .gateway

    private var baseURL: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private var token: String {
        UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
    }

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .gateway = options else { throw WebSearchProviderError.empty }
        let tk = token
        guard !tk.isEmpty else { throw WebSearchProviderError.missingAPIKey }

        var comps = URLComponents(string: baseURL + "/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(max(1, min(common.resultSize, 15)))),
        ]
        guard let url = comps?.url else { throw WebSearchProviderError.missingURL }

        var req = URLRequest(url: url)
        // 真浏览器搜索比 API 慢，给足超时（网关侧还有并发闸排队）
        req.timeoutInterval = max(common.timeout, 30)
        req.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchProviderError.decode("not JSON")
        }
        let raw = (json["items"] as? [[String: Any]]) ?? []
        let items = raw.prefix(common.resultSize).compactMap { item -> WebSearchResultItem? in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            let title = item["title"] as? String ?? url
            let snippet = item["snippet"] as? String ?? ""
            return WebSearchResultItem(title: title, url: url, text: snippet)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: Array(items))
    }
}
