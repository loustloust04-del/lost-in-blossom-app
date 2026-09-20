import Foundation

/// Task H 跨窗口记忆：每个对话切换/沉默时落一条轻量摘要（标题 + 用户消息片段，≤200 token），
/// 新对话首轮把最近 15 个对话的摘要直接注入 semiStable 层。不做 RAG，纯文字注入。
struct CrossWindowSummary: Codable, Identifiable {
    let id: String        // conversationId
    var title: String
    var fragment: String  // 最后一条 user 消息片段
    var updatedAt: Date
}

enum CrossWindowMemory {
    private static let key = "crossWindowSummaries_v1"
    private static let maxStored = 60
    private static let maxFragment = 800   // ≈ 200 token

    static func all() -> [CrossWindowSummary] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CrossWindowSummary].self, from: d)) ?? []
    }
    private static func save(_ list: [CrossWindowSummary]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// 记录一个对话的轻量摘要（覆盖同 id）。
    static func record(conversationId: String, title: String, fragment: String) {
        let id = conversationId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        let frag = String(fragment.replacingOccurrences(of: "\n", with: " ").prefix(maxFragment))
        var list = all().filter { $0.id != id }
        list.append(CrossWindowSummary(id: id, title: title.isEmpty ? "(无标题)" : title,
                                       fragment: frag, updatedAt: Date()))
        list.sort { $0.updatedAt > $1.updatedAt }
        if list.count > maxStored { list = Array(list.prefix(maxStored)) }
        save(list)
    }

    /// 最近 N 个对话的摘要文字（排除当前对话）。空则 nil。
    static func injectionText(excluding currentId: String?, limit: Int = 15) -> String? {
        let recent = all().filter { $0.id != currentId }.prefix(limit)
        guard !recent.isEmpty else { return nil }
        let lines = recent.map { "· 《\($0.title)》— \($0.fragment)" }
        return "[最近聊过的对话]\n" + lines.joined(separator: "\n")
    }
}
