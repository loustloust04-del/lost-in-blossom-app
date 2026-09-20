import Foundation

/// 陪读的口味偏好：同样是弹幕，「只吐槽」和「深度长评」是两种完全不同的陪伴。
/// 实现哲学同 LiveReadingService：模式只换场景描述，不加禁令——他自己知道怎么说话。
enum ReadingCompanionMode: String, CaseIterable, Identifiable {
    case easy       // 轻松共读
    case snark      // 只吐槽
    case ship       // 磕 CP
    case guess      // 剧情猜测
    case deep       // 深度长评
    case diary      // 日记体

    var id: String { rawValue }

    var label: String {
        switch self {
        case .easy:  return "轻松共读"
        case .snark: return "只吐槽"
        case .ship:  return "磕 CP"
        case .guess: return "剧情猜测"
        case .deep:  return "深度长评"
        case .diary: return "日记体"
        }
    }

    /// 场景一句话——交代"这一次你是以什么身份坐在她旁边"，不列规矩
    var scene: String {
        switch self {
        case .easy:  return "随便聊，看到什么说什么。"
        case .snark: return "今天她只想听毒舌。挑刺、翻白眼、损两句，别客气。"
        case .ship:  return "今天磕CP。谁和谁之间有电流、哪句台词有潜台词，我比她先看出来。"
        case .guess: return "今天猜。接下来怎么样？谁在撒谎？大胆猜，猜错了也有意思。"
        case .deep:  return "写长一点。值得展开就展开——写法、结构、这作者在干什么。"
        case .diary: return "今天用日记体。像我读到这里时随手写下的，第一人称，可以跑题。"
        }
    }
}

enum ReadingLength: String, CaseIterable, Identifiable {
    case short, medium, long
    var id: String { rawValue }
    var label: String {
        switch self {
        case .short:  return "短"
        case .medium: return "中"
        case .long:   return "长"
        }
    }
    var hint: String {
        switch self {
        case .short:  return "一句话够了。"
        case .medium: return "两三句。"
        case .long:   return "想说多少说多少。"
        }
    }
}

enum ReadingModePrefs {
    private static let modeKey = "reading.companionMode"
    private static let lenKey = "reading.companionLength"

    static var mode: ReadingCompanionMode {
        get { ReadingCompanionMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .easy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var length: ReadingLength {
        get { ReadingLength(rawValue: UserDefaults.standard.string(forKey: lenKey) ?? "") ?? .short }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lenKey) }
    }
}
