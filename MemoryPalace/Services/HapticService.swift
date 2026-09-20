import UIKit

enum HapticMode: String, CaseIterable {
    case off = "off"
    case typewriter = "typewriter"  // ChatGPT 风格
    case minimal = "minimal"        // Claude 风格
}

class HapticService {
    static let shared = HapticService()

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    var mode: HapticMode {
        get { HapticMode(rawValue: UserDefaults.standard.string(forKey: "hapticMode") ?? "typewriter") ?? .typewriter }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hapticMode") }
    }

    // 预热 Taptic Engine（在即将触发前调用，减少延迟）
    func prepare() {
        impactLight.prepare()
        selection.prepare()
    }

    // ═══ ChatGPT 模式专用 ═══

    /// streaming 时每个 token chunk 到达时调用
    /// 需要节流：内部控制最少间隔 50ms，避免过于密集
    private var lastTypewriterTime: TimeInterval = 0

    func streamingTick() {
        guard mode == .typewriter else { return }
        let now = CACurrentMediaTime()
        guard now - lastTypewriterTime > 0.05 else { return } // 50ms 节流
        lastTypewriterTime = now
        impactLight.impactOccurred(intensity: 0.4) // 轻，40% 强度
    }

    /// streaming 结束时调用
    func streamingComplete() {
        guard mode == .typewriter else { return }
        impactLight.impactOccurred(intensity: 0.6)
    }

    // ═══ Claude 模式专用 ═══

    /// 发送消息时
    func sendMessage() {
        guard mode == .minimal else { return }
        impactMedium.impactOccurred()
    }

    // ═══ 两种模式共用 ═══

    /// 复制文本时
    func copyText() {
        guard mode != .off else { return }
        impactLight.impactOccurred(intensity: 0.6)
    }

    /// 删除操作（标签删除、消息删除）
    func deleteAction() {
        guard mode != .off else { return }
        notification.notificationOccurred(.warning)
    }

    /// UI 导航（页面切换、侧边栏）
    func navigation() {
        guard mode != .off else { return }
        selection.selectionChanged()
    }

    /// 长按菜单出现
    func longPress() {
        guard mode != .off else { return }
        impactRigid.impactOccurred()
    }
}
