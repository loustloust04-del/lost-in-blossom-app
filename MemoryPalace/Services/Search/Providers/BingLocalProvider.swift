import Foundation
import SwiftSoup

/// Bing 网页抓取（无 API key）。
/// 参考 Kelivo bing_search_service.dart——选择器 `li.b_algo` + h2/a + .b_caption/.b_algoSlug。
/// 实测踩坑：
///  1. Bing 链接是 `https://www.bing.com/ck/a?...&u=a1<base64url>&ntb=1` 跳转壳，必须解 base64 才拿真实 URL；
///     不解的话 URL 全是 bing.com，引用点击没意义。
///  2. `.b_caption p` 在 Bing "deeplinks/扩展卡片" 结果里会吸到 maccaron 维基百科整段，必须硬截断字数。
struct BingLocalProvider: WebSearchProvider {
    static let kind: WebSearchProviderKind = .bingLocal

    /// snippet 字数硬上限——v2 Phase 1：snippet 当索引摘要用，正文走 browse_url 拿
    /// 400 → 100：让模型清楚 snippet 不是答案，必须 browse_url 深读
    private static let snippetMax = 100

    func search(query: String, common: WebSearchCommonOptions, options: WebSearchServiceOptions) async throws -> WebSearchResult {
        guard case .bingLocal(let opts) = options else { throw WebSearchProviderError.empty }

        // URLComponents 自动做正确的 query 编码——手动 addingPercentEncoding(.urlQueryAllowed)
        // 会漏 `+`/`&`（它们是 query 合法字符），中文含空格/符号的查询被服务器拆错
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw WebSearchProviderError.missingURL
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = common.timeout
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue(opts.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchProviderError.decode("not UTF-8")
        }

        let doc = try SwiftSoup.parse(html)
        let blocks = try doc.select("li.b_algo")
        var items: [WebSearchResultItem] = []
        for el in blocks.array().prefix(common.resultSize) {
            guard let titleEl = try el.select("h2").first(),
                  let linkEl = try el.select("h2 > a").first() else { continue }
            let title = (try? titleEl.text()) ?? ""
            let rawHref = (try? linkEl.attr("href")) ?? ""
            guard !title.isEmpty, !rawHref.isEmpty else { continue }

            // 解 Bing redirect ck/a → 真实 URL
            let href = Self.decodeBingRedirect(rawHref)

            // snippet：用 .b_caption p:first-of-type 拿首段，硬截断 400 字
            // 避免 Bing deeplinks 子卡片把整段维基百科塞进同一 li.b_algo
            let snippetEl = try el.select(".b_caption p, .b_algoSlug").first()
            var snippet = (try? snippetEl?.text()) ?? ""
            if snippet.count > Self.snippetMax {
                snippet = String(snippet.prefix(Self.snippetMax)) + "…"
            }
            items.append(WebSearchResultItem(title: title, url: href, text: snippet))
        }
        // [search-serp] Bing 对裸 URLSession 已全面出验证壳页（HTTP 200、真 SERP 标题、
        // 零 b_algo，VPS 复现 2026-07-06）→ 直连路径空手时降级到内置 WKWebView 渲染：
        // 真浏览器环境（JS + cookie + Safari UA）能像 Safari 一样通过验证。
        if items.isEmpty {
            items = try await Self.renderAndExtract(url: url, resultSize: common.resultSize)
        }
        if items.isEmpty { throw WebSearchProviderError.empty }
        return WebSearchResult(items: items)
    }

    /// WKWebView 渲染 SERP → 页内 JS 结构化抽取（选择器与直连路径一致）
    private static func renderAndExtract(url: URL, resultSize: Int) async throws -> [WebSearchResultItem] {
        let js = """
        (() => {
          const out = [];
          document.querySelectorAll('li.b_algo').forEach((li) => {
            const a = li.querySelector('h2 a') || li.querySelector('a');
            if (!a) return;
            const title = (a.textContent || '').trim();
            const href = a.href || '';
            const sn = li.querySelector('.b_caption p') || li.querySelector('.b_algoSlug');
            const text = sn ? (sn.textContent || '').trim() : '';
            if (title && href) out.push({ title: title, url: href, text: text });
          });
          return JSON.stringify(out);
        })()
        """
        let jsonStr = try await InternalBrowser.shared.evaluate(
            url: url, js: js, timeout: 15, emptyMarker: "[]", retries: 3
        )
        guard let data = jsonStr.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr.prefix(resultSize).compactMap { d in
            guard let title = d["title"] as? String, !title.isEmpty,
                  let raw = d["url"] as? String, !raw.isEmpty else { return nil }
            var text = (d["text"] as? String) ?? ""
            if text.count > snippetMax {
                text = String(text.prefix(snippetMax)) + "…"
            }
            return WebSearchResultItem(title: title, url: decodeBingRedirect(raw), text: text)
        }
    }

    /// Bing `ck/a?...&u=a1<base64url>&ntb=1` → 真实 URL
    /// `u=` 参数前两字符是 Bing 的版本 prefix（实测 "a1"），后面是 base64url 编码
    static func decodeBingRedirect(_ href: String) -> String {
        guard href.contains("/ck/a?") || href.contains("bing.com") else { return href }
        guard let comps = URLComponents(string: href),
              let uVal = comps.queryItems?.first(where: { $0.name == "u" })?.value else {
            return href
        }
        // 砍掉前缀（实测 "a1"，也兼容其他长度小前缀）
        let stripped: String
        if uVal.count > 2, uVal.hasPrefix("a") {
            stripped = String(uVal.dropFirst(2))
        } else {
            stripped = uVal
        }
        // base64url → base64
        var b64 = stripped.replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let decoded = String(data: data, encoding: .utf8),
              decoded.lowercased().hasPrefix("http") else {
            return href
        }
        return decoded
    }
}
