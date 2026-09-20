import Foundation
import SwiftData

// MARK: - 记忆对齐（PR-4）
//
// 本地 SwiftData ↔ 网关 Supabase 双向对齐：
//   syncToGateway()   把本地手动写入的记忆（isUserExplicit==true）POST 到 /api/memories/sync
//   syncFromGateway() 从 /api/memories/diff?since= 拉差异写入本地 SwiftData
//
// 触发时机：App 启动 / 回前台自动跑一次（仅在「启用后端记忆系统」开关开启时），
//          或用户手动点「对齐」按钮（手动恒可用）。
//
// 去重：content 相似度 > 0.8 视为重复，跳过。
//   · 上行去重由网关负责（embedding 相似度）
//   · 下行去重在本地用字符二元组 Dice 系数估算
//
// 网关地址 / token 复用全局约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"。

final class MemorySync {
    static let shared = MemorySync()
    private init() {}

    private static let lastPullKey = "lib.memorySync.lastPullMs"
    private static let fallbackBase = "https://blossom.amberrib.com"
    private static let dupThreshold = 0.8

    private let store = SwiftDataMemoryStore()
    private var ranThisLaunch = false

    // MARK: 网关 JSON

    private struct GWMem: Decodable {
        let content: String
        let category: String?
        let tier: Int?
        let source: String?
    }
    private struct DiffResp: Decodable { let memories: [GWMem] }

    private struct OutMem: Encodable {
        let content: String
        let category: String?
        let tier: Int
    }
    private struct SyncBody: Encodable { let memories: [OutMem] }
    private struct SyncResult: Decodable { let added: Int?; let skipped: Int? }

    // MARK: 请求构造

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest? {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? Self.fallbackBase
        guard var comps = URLComponents(string: "\(base)\(path)") else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        if let token = UserDefaults.standard.string(forKey: "gatewayAuthToken"), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    // MARK: 触发入口

    /// App 启动 / 回前台调用：每个进程生命周期只跑一次，且仅在后端记忆开关开启时。
    func alignOnLaunch(container: ModelContainer, profileId: String) async {
        guard UserDefaults.standard.bool(forKey: "useBackendMemory") else { return }
        guard !ranThisLaunch else { return }
        ranThisLaunch = true
        await align(container: container, profileId: profileId)
    }

    /// 手动对齐（设置页/面板按钮调用），不受开关限制。
    @discardableResult
    func align(container: ModelContainer, profileId: String) async -> (pushed: Int, pulled: Int) {
        let pushed = await syncToGateway(container: container, profileId: profileId)
        let pulled = await syncFromGateway(container: container, profileId: profileId)
        return (pushed, pulled)
    }

    // MARK: 上行：本地手动记忆 → 网关

    @discardableResult
    func syncToGateway(container: ModelContainer, profileId: String) async -> Int {
        let ctx = ModelContext(container)
        // 立刻映射成值类型，不把 Memory 带过 await。
        let out: [OutMem] = store.listAll(profileId: profileId, context: ctx)
            .filter { $0.isUserExplicit && $0.supersededAt == nil }
            .map { OutMem(content: $0.content, category: $0.category, tier: 2) }
        guard !out.isEmpty else { return 0 }

        guard let body = try? JSONEncoder().encode(SyncBody(memories: out)),
              let req = makeRequest(path: "/api/memories/sync", method: "POST", body: body) else { return 0 }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return 0 }
            let result = try JSONDecoder().decode(SyncResult.self, from: data)
            return result.added ?? 0
        } catch {
            print("[MemorySync] syncToGateway failed: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: 下行：网关 → 本地

    @discardableResult
    func syncFromGateway(container: ModelContainer, profileId: String) async -> Int {
        let since = UserDefaults.standard.double(forKey: Self.lastPullKey)
        var query: [URLQueryItem] = []
        if since > 0 { query.append(URLQueryItem(name: "since", value: String(Int(since)))) }
        guard let req = makeRequest(path: "/api/memories/diff", method: "GET", query: query) else { return 0 }

        let incoming: [GWMem]
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return 0 }
            incoming = try JSONDecoder().decode(DiffResp.self, from: data).memories
        } catch {
            print("[MemorySync] syncFromGateway failed: \(error.localizedDescription)")
            return 0
        }
        guard !incoming.isEmpty else {
            UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: Self.lastPullKey)
            return 0
        }

        // await 之后再开 DB，不跨 await 持有 Memory。
        let ctx = ModelContext(container)
        var existing = store.listAll(profileId: profileId, context: ctx).map { $0.content }
        var added = 0
        for m in incoming {
            let content = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            if existing.contains(where: { Self.similarity($0, content) > Self.dupThreshold }) { continue }
            do {
                _ = try store.add(
                    content: content,
                    category: m.category ?? "fact",
                    keywords: [],
                    profileId: profileId,
                    isUserExplicit: false,
                    extractedBy: "gateway-sync",
                    sourceConversationId: nil,
                    sourceQuote: nil,
                    sourceNodeId: nil,
                    context: ctx
                )
                existing.append(content)   // 防止本批内部重复
                added += 1
            } catch {
                print("[MemorySync] local add failed: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: Self.lastPullKey)
        return added
    }

    // MARK: 相似度（字符二元组 Sørensen–Dice 系数）

    static func similarity(_ a: String, _ b: String) -> Double {
        let s1 = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let s2 = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if s1.isEmpty || s2.isEmpty { return 0 }
        if s1 == s2 { return 1 }
        let b1 = bigrams(s1)
        let b2 = bigrams(s2)
        if b1.isEmpty || b2.isEmpty { return 0 }
        var counts: [String: Int] = [:]
        for g in b1 { counts[g, default: 0] += 1 }
        var inter = 0
        for g in b2 {
            if let c = counts[g], c > 0 { inter += 1; counts[g] = c - 1 }
        }
        return 2.0 * Double(inter) / Double(b1.count + b2.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 2 else { return chars.map { String($0) } }
        var out: [String] = []
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.append(String(chars[i]) + String(chars[i + 1]))
        }
        return out
    }
}
