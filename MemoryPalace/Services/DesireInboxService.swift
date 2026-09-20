import Foundation
import UserNotifications

// MARK: - 念头收件箱（PR-6）
//
// App 打开 / 回前台时，拉取 gateway 的未读念头（/api/desires/unread），
// 用本地通知展示。念头是欲望系统主动生成的（存在 gateway session_id=desire），
// 没有对应的本地会话，因此点击通知只打开 App（落到当前会话）。
//
// 网关地址 / token：
//   UserDefaults "gatewayBaseURL" / "gatewayAuthToken"
//
// 增量拉取：记录 lastSeen（epoch 毫秒）到 UserDefaults，下次只取更新的念头。

final class DesireInboxService {
    static let shared = DesireInboxService()
    private init() {}

    private static let lastSeenKey = "lib.desireInbox.lastSeenMs"
    private static let fallbackBase = "https://blossom.amberrib.com"
    private let center = UNUserNotificationCenter.current()

    private struct Desire: Decodable {
        let content: String
        let created_at: String?
    }
    private struct Resp: Decodable {
        let desires: [Desire]
    }

    /// App 打开 / 回前台时调用：拉取未读念头并用本地通知展示。
    func checkUnread() async {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? Self.fallbackBase
        let lastSeen = UserDefaults.standard.double(forKey: Self.lastSeenKey)

        guard var comps = URLComponents(string: "\(base)/api/desires/unread") else { return }
        if lastSeen > 0 {
            comps.queryItems = [URLQueryItem(name: "since", value: String(Int(lastSeen)))]
        }
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if let token = UserDefaults.standard.string(forKey: "gatewayAuthToken"), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            let desires = decoded.desires.filter { !$0.content.isEmpty }
            guard !desires.isEmpty else { return }

            await present(desires)
            // 推进 lastSeen，避免重复展示
            UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: Self.lastSeenKey)
        } catch {
            print("[DesireInbox] checkUnread failed: \(error.localizedDescription)")
        }
    }

    /// 用本地通知展示念头（最多 3 条，避免刷屏）。
    private func present(_ desires: [Desire]) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else { return }

        for d in desires.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = "Caelum"
            content.body = d.content
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "desire.\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}
