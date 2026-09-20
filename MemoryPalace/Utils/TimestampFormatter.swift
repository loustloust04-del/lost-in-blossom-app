import Foundation

enum TimestampFormatter {
    /// `"yyyy-MM-dd HH:mm"`，固定 POSIX locale，格式稳定不随系统语言切换。
    static func minuteStamp(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: date)
    }

    /// 相对时间描述：刚刚 / N 分钟前 / N 小时前 / N 天前 / yyyy-MM-dd
    static func relativeDescription(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86_400 { return "\(Int(delta / 3600)) 小时前" }
        if delta < 86_400 * 7 { return "\(Int(delta / 86_400)) 天前" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
