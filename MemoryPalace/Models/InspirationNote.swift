import Foundation
import SwiftData

/// 灵感盒的一张卡片。flomo 式无压记录：只有正文和时间，没有标题/分类/排版。
/// 标签从正文里的 #xxx 自动解析（支持 #人物/女主 多级），不预先规划目录。
@Model
final class InspirationNote {
    #Index<InspirationNote>(
        [\.profileId],
        [\.profileId, \.createdAt]
    )

    var id: String = UUID().uuidString
    var profileId: String = ""
    var text: String = ""
    /// 解析出的标签（含多级，如 "人物/女主"），冗余存一份便于筛选
    var tags: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// 已同步到服务器笔记本（Caelum 可读）的时间；nil = 还没推上去
    var syncedAt: Date?

    init(profileId: String, text: String, createdAt: Date = Date()) {
        self.id = UUID().uuidString
        self.profileId = profileId
        self.text = text
        self.tags = InspirationNote.parseTags(from: text)
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// 从正文解析 #标签：中英文数字下划线斜杠，遇空白/标点终止。
    /// "今天 #人物/女主 有点冷" → ["人物/女主"]
    static func parseTags(from text: String) -> [String] {
        let pattern = "#([\\p{Han}\\w/]+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !tag.isEmpty, !out.contains(tag) { out.append(tag) }
        }
        return out
    }

    /// 正文首行摘要（列表/搜索用）
    var summary: String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}
