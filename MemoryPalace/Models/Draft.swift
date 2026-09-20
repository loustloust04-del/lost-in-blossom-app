import Foundation
import SwiftData

/// 花房的一篇稿子。刻意极简：正文 + 标题 + 时间 + 今日字数账。
/// 不做文件夹/标签/版本树——那些是"写作软件"的东西，花房要的是一张白纸。
@Model
final class Draft: Identifiable {
    #Index<Draft>([\.profileId], [\.profileId, \.updatedAt])

    var id: String = UUID().uuidString
    var profileId: String = ""
    var title: String = ""
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 今日目标字数（开工卡设定，0 = 没设目标）
    var dailyGoal: Int = 0
    /// 今日已写字数的基准：当天第一次打开时的总字数，用来算"今天写了多少"
    var todayBaseline: Int = 0
    var todayBaselineDate: Date = Date.distantPast

    init(profileId: String, title: String = "", body: String = "") {
        self.id = UUID().uuidString
        self.profileId = profileId
        self.title = title
        self.body = body
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// 中文按字符数（不是单词数）——兔兔写中文，字符才是她关心的数字
    var wordCount: Int {
        body.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "").count
    }

    /// 今天写了多少（跨天自动重置基准）
    var todayCount: Int {
        max(0, wordCount - todayBaseline)
    }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "无题" : String(firstLine.prefix(20))
    }

    /// 每天首次打开时把基准对齐到当前字数
    func rollBaselineIfNeeded() {
        if !Calendar.current.isDateInToday(todayBaselineDate) {
            todayBaseline = wordCount
            todayBaselineDate = Date()
        }
    }
}
