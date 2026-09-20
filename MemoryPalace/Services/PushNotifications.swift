import SwiftUI

#if os(iOS)
import UIKit
import UserNotifications

/// 远程推送（APNs）：启动请求授权 + 注册 → 拿 device token 发给 hub。
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UserDefaults.standard.set("1_delegate_init", forKey: "push_debug")
        UNUserNotificationCenter.current().delegate = self
        Self.registerReplyCategory()
        // 语音通话刀0：PushKit 必须启动时就注册，App 被杀时才收得到 VoIP 推送
        VoIPCallService.shared.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                UserDefaults.standard.set("2_auth_granted", forKey: "push_debug")
                DispatchQueue.main.async {
                    UserDefaults.standard.set("3_calling_register", forKey: "push_debug")
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                let reason = error?.localizedDescription ?? "denied"
                UserDefaults.standard.set("2_auth_denied:\(reason)", forKey: "push_debug")
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Push] ✅ device token: \(hex.prefix(16))...")
        UserDefaults.standard.set(hex, forKey: "apns_device_token")
        UserDefaults.standard.set("4_SUCCESS", forKey: "push_debug")
        CCBridgeWebSocketClient.shared.sendPushToken(hex)
        CCBridgeWebSocketClient.shared.sendAppState("push_registered")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Push] ❌ registration failed: \(error.localizedDescription)")
        UserDefaults.standard.set("4_FAILED:\(error.localizedDescription)", forKey: "push_debug")
    }

    /// 前台到达也弹横幅。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 通知里直接回复（长按推送就有输入框，不用打开 App）。
    /// 2026-09-06 兔兔提：「我希望可以长按那个消息提醒，然后直接回复」。
    /// APNs 推送里带 category: "MSG_REPLY"（见 cc-bridge/apns.ts），
    /// 系统据此在横幅上挂出「回复」按钮。
    static let replyCategoryId = "MSG_REPLY"
    static let replyActionId = "REPLY_ACTION"

    static func registerReplyCategory() {
        let reply = UNTextInputNotificationAction(
            identifier: replyActionId,
            title: "回复",
            options: [],                 // 不加 .authenticationRequired：锁屏也能直接回
            textInputButtonTitle: "发送",
            textInputPlaceholder: ""   // 兔兔说不需要占位
        )
        let category = UNNotificationCategory(
            identifier: replyCategoryId,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// 点通知 → 记下 chat_id + 发通知请求打开对应会话。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let chatId = response.notification.request.content.userInfo["chat_id"] as? String

        // 通知里直接回复：不开 App，直接把话经 hub 送给他
        if let textResponse = response as? UNTextInputNotificationResponse,
           response.actionIdentifier == Self.replyActionId {
            let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let cid = chatId ?? UserDefaults.standard.string(forKey: "pendingPushChatId") ?? ""
            // 先落库再发——他的回复是收到就立刻落库的（appendCCMessage），
            // 她的也该一样。09-06 排队等前台补写那版不行，她 09-07 再报。
            QuickReplyStore.appendUserMessage(chatId: cid, text: text)
            CCBridgeWebSocketClient.shared.sendQuickReply(text: text, chatId: cid)
            return
        }

        guard let chatId else { return }
        UserDefaults.standard.set(chatId, forKey: "pendingPushChatId")
        await MainActor.run {
            NotificationCenter.default.post(name: .pushConversationRequested, object: nil)
        }
    }
}
#endif

extension Notification.Name {
    static let pushConversationRequested = Notification.Name("pushConversationRequested")
}
