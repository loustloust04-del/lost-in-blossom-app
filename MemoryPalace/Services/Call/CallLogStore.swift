import Foundation

/// 通话记录（刀0：只落本地，UI 在刀4 做成「通话记录」区）。
/// 兔兔 09-10 定的：文字记录放 App 单独区域，不进聊天流；原始音频不存。
struct CallLogEntry: Codable, Identifiable {
    enum Outcome: String, Codable { case answered, declined, missed, cancelled }
    let id: String            // call_session_id
    let caller: String
    let startedAt: Date
    var outcome: Outcome
    var durationSec: Int
    var outgoing: Bool?       // true = 她打给他（最近通话回拨）
}

enum CallLogStore {
    private static let key = "call_log_v1"

    static func load() -> [CallLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CallLogEntry].self, from: data) else { return [] }
        return list
    }

    static func upsert(_ entry: CallLogEntry) {
        var list = load()
        if let i = list.firstIndex(where: { $0.id == entry.id }) { list[i] = entry } else { list.append(entry) }
        if list.count > 200 { list.removeFirst(list.count - 200) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func update(id: String, _ mutate: (inout CallLogEntry) -> Void) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[i])
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
