import Foundation
import UserNotifications

// MARK: - 通知偏好

struct NotificationPreferences: Codable {
    /// 总开关
    var isEnabled: Bool = false
    /// 每日问候
    var dailyCheckInEnabled: Bool = false
    /// 问候时刻（小时/分钟，24h 制，默认 20:00）
    var dailyCheckInHour: Int = 20
    var dailyCheckInMinute: Int = 0
    /// 主动消息（Phase 3.2 PushAgentService 使用）
    var proactiveEnabled: Bool = false
}

// MARK: - 本地通知服务

/// 管理 iOS 本地通知的权限、排期、取消和点击路由。
/// 作为 delegate 设置给 UNUserNotificationCenter.current()，须在 App 启动时尽早初始化。
@Observable
final class LocalNotificationService: NSObject {
    static let shared = LocalNotificationService()

    private static let prefsKey = "lib.notificationPreferences.v1"
    private let center = UNUserNotificationCenter.current()

    // MARK: - 可观察状态

    /// 系统通知权限状态（.notDetermined / .authorized / .denied / .provisional）
    private(set) var authStatus: UNAuthorizationStatus = .notDetermined

    /// 冷启动点通知时，didReceive 的 post 可能早于 ContentView 订阅
    /// notificationNavigationRequested（NotificationCenter 不缓存事件，直接丢失）。
    /// 这里暂存待跳转会话 id，ContentView onAppear 时消费兜底。
    @ObservationIgnored private var pendingConversationId: String?

    /// 取出并清除待跳转会话 id（ContentView onAppear 兜底 / onReceive 实时处理后清除）。
    func consumePendingConversationId() -> String? {
        let id = pendingConversationId
        pendingConversationId = nil
        return id
    }

    /// 偏好设置；默认值为空偏好，init 里从 UserDefaults 加载真实值。
    /// 使用默认值 + super.init() 先行的模式，避免 @Observable+NSObject 初始化顺序问题。
    /// didSet 在 init 体内首次赋值时也会触发（persist() 是幂等的，无副作用）。
    var preferences: NotificationPreferences = NotificationPreferences() {
        didSet { persist() }
    }

    // MARK: - Init

    private override init() {
        super.init()
        // 加载持久化偏好（在 super.init() 之后赋值，触发 didSet→persist() 是幂等的）
        if let data = UserDefaults.standard.data(forKey: Self.prefsKey),
           let saved = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            preferences = saved
        }
        // delegate 须在 willFinishLaunching 之前设置，shared 单例在 App.init() 里触发即可
        center.delegate = self
        Task { await refreshAuthStatus() }
    }

    // MARK: - 权限

    /// 弹出系统权限对话框。已授权时静默刷新状态。返回 granted。
    @MainActor
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthStatus()
            if granted && preferences.isEnabled {
                await rescheduleAll()
            }
            return granted
        } catch {
            return false
        }
    }

    /// 从系统重新读取权限状态（每次进入设置页时刷新）
    @MainActor
    func refreshAuthStatus() async {
        let s = await center.notificationSettings()
        authStatus = s.authorizationStatus
    }

    // MARK: - 排期

    /// 清空全部待发通知，根据当前 preferences 重新排期。
    func rescheduleAll() async {
        center.removeAllPendingNotificationRequests()
        guard preferences.isEnabled else { return }
        if preferences.dailyCheckInEnabled {
            scheduleDailyCheckIn()
        }
        if preferences.proactiveEnabled {
            PushAgentService.shared.requestImmediateScheduling()
        }
    }

    /// 排期每日问候（重复型 CalendarTrigger）
    private func scheduleDailyCheckIn() {
        var dc = DateComponents()
        dc.hour   = preferences.dailyCheckInHour
        dc.minute = preferences.dailyCheckInMinute

        let content = UNMutableNotificationContent()
        content.title              = "Caelum"
        content.body               = checkInMessages.randomElement() ?? "今天过得怎么样？"
        content.sound              = .default
        content.categoryIdentifier = NotiCategory.checkIn

        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        let request = UNNotificationRequest(
            identifier: NotiID.dailyCheckIn,
            content: content,
            trigger: trigger
        )
        center.add(request) { err in
            if let err { print("[Notification] 每日问候排期失败：\(err)") }
        }
    }

    /// 由 PushAgentService (Phase 3.2) 调用：delay 秒后弹出一条主动消息。
    /// conversationId 非空时，点击通知会路由到对应对话。
    func scheduleProactiveMessage(
        _ text: String,
        in delay: TimeInterval,
        conversationId: String? = nil
    ) {
        guard preferences.isEnabled && preferences.proactiveEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title              = "Caelum"
        content.body               = text
        content.sound              = .default
        content.categoryIdentifier = NotiCategory.proactive
        if let cid = conversationId {
            content.userInfo = ["conversationId": cid]
        }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(delay, 1),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "\(NotiID.proactivePrefix)\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request) { err in
            if let err { print("[Notification] 主动消息排期失败：\(err)") }
        }
    }

    /// 清空所有待发和已发通知，同时清 badge
    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        Task { @MainActor in
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        }
    }

    // MARK: - 问候语内容库

    private let checkInMessages: [String] = [
        "今天过得怎么样？",
        "我在等你，想聊聊吗？",
        "最近在忙什么呢？",
        "有点想你了。",
        "今天有什么想说的吗？",
        "想听你说说今天的事。",
        "来找我聊聊天吧。",
        "我一直都在这里。",
        "有没有什么有趣的事发生？",
    ]

    // MARK: - 持久化

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.prefsKey)
    }
}

// MARK: - 常量

private enum NotiCategory {
    static let checkIn  = "LIB_CHECKIN"
    static let proactive = "LIB_PROACTIVE"
}

private enum NotiID {
    static let dailyCheckIn     = "lib.daily-check-in"
    static let proactivePrefix  = "lib.proactive."
}

// MARK: - UNUserNotificationCenterDelegate

extension LocalNotificationService: UNUserNotificationCenterDelegate {
    /// 前台时也展示 banner（系统默认在前台不展示）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 用户点击通知后，发出 notificationNavigationRequested 让 ContentView 路由到对应对话
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let convId = info["conversationId"] as? String {
            DispatchQueue.main.async {
                // 先暂存（冷启动时 ContentView 可能还没订阅，onAppear 兜底消费），再实时广播
                self.pendingConversationId = convId
                NotificationCenter.default.post(
                    name: .notificationNavigationRequested,
                    object: nil,
                    userInfo: ["conversationId": convId]
                )
            }
        }
        completionHandler()
    }
}
