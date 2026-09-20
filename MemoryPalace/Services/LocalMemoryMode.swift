import Foundation

/// 本地（粟粟自带）记忆系统三态开关：
/// - on：正常提取 + 注入
/// - recordOnly：继续提取生成记忆，但不注入 prompt（静默记录，攒着以后用）
/// - off：不提取也不注入
/// 兼容旧布尔键 localMemoryEnabled（新键未设置时按旧键折算）。
enum LocalMemoryMode: String, CaseIterable {
    case on
    case recordOnly
    case off

    static let storageKey = "localMemoryMode"

    static var current: LocalMemoryMode {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let m = LocalMemoryMode(rawValue: raw) {
            return m
        }
        // 旧布尔开关折算（App 启动注册默认 true）
        return UserDefaults.standard.bool(forKey: "localMemoryEnabled") ? .on : .off
    }

    /// 是否把记忆注入 prompt
    var injects: Bool { self == .on }
    /// 是否继续提取生成记忆
    var extracts: Bool { self != .off }

    var label: String {
        switch self {
        case .on: return "开启"
        case .recordOnly: return "仅记录"
        case .off: return "关闭"
        }
    }
}
