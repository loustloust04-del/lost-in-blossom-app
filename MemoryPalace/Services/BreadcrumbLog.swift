import Foundation
import Observation

/// 操作面包屑：全局轨迹环形缓冲（最近 80 条），开发者调试用。
/// 上架版反馈不再带出（保护用户隐私）；本地仅作调试日志。
/// UserDefaults 持久化，跨重启保留"重启前的轨迹"（崩溃排查锚点）。
/// 所有埋点都在主线程路径上调用 add()。
@Observable
final class BreadcrumbLog {
    static let shared = BreadcrumbLog()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        let time: Date
        let icon: String
        let text: String
    }

    private(set) var entries: [Entry] = []

    private static let capacity = 400   // 09-15：探针一秒一条会把 📐🧭📎 挤掉，放大
    private static let storeKey = "breadcrumbLog"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ icon: String, _ text: String) {
        entries.append(Entry(time: Date(), icon: icon, text: text))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// 反馈快照用：时间序文本块
    func formattedDump() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return entries.map { "\(formatter.string(from: $0.time)) \($0.icon) \($0.text)" }
            .joined(separator: "\n")
    }
}
