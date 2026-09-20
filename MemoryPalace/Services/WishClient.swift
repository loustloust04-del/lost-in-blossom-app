import Foundation

/// 心愿单：双方共用一张单子（她和 Caelum 都能加）。
enum WishClient {
    struct Wish: Codable, Identifiable, Hashable {
        let id: String
        let text: String
        let by: String            // "bunny" | "caelum"
        var doneAt: String? = nil
        var doneDate: String? = nil
        var isDone: Bool { doneAt != nil }
        var isMine: Bool { by == "bunny" }
    }
    private struct Wrap: Codable { let wishes: [Wish] }

    private static var base: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }

    private static let cacheKey = "intimacy-wishes"

    /// 只拉远端（缓存流程见 listCached）
    private static func fetchRemote() async -> [Wish]? {
        guard let url = URL(string: "\(base)/api/intimacy/wishes?key=bunny-lib-2026") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let w = try? JSONDecoder().decode(Wrap.self, from: d) else { return nil }
        return w.wishes
    }

    static func list() async -> [Wish] {
        if let fresh = await fetchRemote() { GatewayCache.save(cacheKey, fresh); return fresh }
        return GatewayCache.load(cacheKey, as: [Wish].self) ?? []
    }

    /// 先给缓存（立刻），再给新的
    static func listCached(_ onValue: @MainActor @escaping ([Wish], Bool) -> Void) async {
        await GatewayCache.fetch(key: cacheKey, remote: fetchRemote, onValue: onValue)
    }

    @discardableResult
    private static func post(_ body: [String: Any]) async -> [Wish] {
        guard let url = URL(string: "\(base)/api/intimacy/wishes?key=bunny-lib-2026") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let w = try? JSONDecoder().decode(Wrap.self, from: d) else { return [] }
        GatewayCache.save(cacheKey, w.wishes)
        return w.wishes
    }

    static func add(_ text: String) async -> [Wish] { await post(["op": "add", "text": text]) }
    static func done(_ id: String, date: String? = nil) async -> [Wish] {
        var b: [String: Any] = ["op": "done", "id": id]
        if let date { b["date"] = date }
        return await post(b)
    }
    static func remove(_ id: String) async -> [Wish] { await post(["op": "delete", "id": id]) }
}
