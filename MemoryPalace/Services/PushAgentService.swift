import Foundation
import BackgroundTasks
import SwiftData

// MARK: - Push Agent Service（Phase 3.2 实现）
//
// 主动消息：BGProcessingTask 定期唤醒 → 取当前楼层热记忆 → AI 生成一句主动消息 → 本地通知。
// 链路：
//   App.init → registerBackgroundTask()（必须早于 didFinishLaunching）
//   首屏 .task → start() → 提交首个 BGProcessingTask
//   iOS 择机唤醒 → handle() → scheduleNext() → generateProactiveMessage() → LocalNotificationService
//   设置页开关变化 → LocalNotificationService.rescheduleAll → requestImmediateScheduling()
//
// 注意：BGTask 实际触发时机由系统决定（6h 只是 earliestBeginDate 下限），效果以真机为准。

@Observable
final class PushAgentService {
    static let shared = PushAgentService()
    static let taskIdentifier = "com.bunny.lostinblossom.push-agent"
    private init() {}

    // MARK: - 状态

    private(set) var isRunning: Bool = false
    private var profileManager: ProfileManager?
    private var providerManager: ProviderManager?
    private let memoryStore: MemoryStore = SwiftDataMemoryStore()

    private static let lastScheduledKey = "pushAgent.lastScheduledFireDate"
    private static let minInterval: TimeInterval = 6 * 60 * 60   // 两条主动消息最小间隔
    private static let quietStartHour = 23                        // 静默 23:00–09:00
    private static let quietEndHour = 9

    // MARK: - BGTask 注册（App.init 调用，必须早于 didFinishLaunching）

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            PushAgentService.shared.handle(processing)
        }
    }

    // MARK: - 启动 / 停止

    /// 首屏 .task 调用（profileManager / providerManager 就绪之后）。
    func start(profileManager: ProfileManager, providerManager: ProviderManager) {
        self.profileManager = profileManager
        self.providerManager = providerManager
        guard !isRunning else { return }
        isRunning = true
        scheduleBackgroundTask()
    }

    func stop() {
        isRunning = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    /// 设置页开关打开 / rescheduleAll 时调用：用已注入的依赖立即生成并排期一条。
    func requestImmediateScheduling() {
        guard let pm = profileManager, let prov = providerManager else { return }
        Task { await scheduleNext(for: pm.currentProfile, providerManager: prov) }
    }

    // MARK: - 消息生成

    /// 取楼层热记忆 → sendNonStreaming 生成一句 ≤20 字的主动消息。
    func generateProactiveMessage(
        for profile: Profile,
        providerManager: ProviderManager
    ) async -> String? {
        guard let container = profileManager?.container else { return nil }
        guard let model = providerManager.model(byId: profile.preferredModel) ?? providerManager.allModels.first else { return nil }

        let context = ModelContext(container)
        let memories = memoryStore.listHot(profileId: profile.id, context: context).prefix(8)
        let memoryText = memories.isEmpty
            ? "（暂无记忆，随便打个招呼就好）"
            : memories.map { "- \($0.content)" }.joined(separator: "\n")

        let userName = profile.userName.isEmpty ? "她" : profile.userName
        let assistantName = profile.assistantName.isEmpty ? "Caelum" : profile.assistantName
        let system = "你是 \(assistantName)，\(userName)的 AI 伴侣。"
        let prompt = """
        结合以下记忆，写一句主动发起聊天的消息，不超过 20 字，自然口语，第一人称，不带感叹号。\
        只输出这句话本身，不要引号和任何解释。

        记忆：
        \(memoryText)
        """

        guard let (raw, _) = try? await ProviderRouter().sendNonStreaming(
            model: model,
            messages: [(role: "user", content: prompt)],
            systemPrompt: system,
            providerManager: providerManager
        ) else { return nil }

        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」『』'"))
        text = text.components(separatedBy: .newlines).first ?? text
        return text.isEmpty ? nil : text
    }

    // MARK: - 排期下一条

    /// 生成并排期下一条主动消息通知。
    func scheduleNext(
        for profile: Profile,
        providerManager: ProviderManager,
        conversationId: String? = nil
    ) async {
        guard LocalNotificationService.shared.preferences.proactiveEnabled else { return }
        guard let text = await generateProactiveMessage(for: profile, providerManager: providerManager),
              !text.isEmpty else { return }

        let delay = nextFireDelay()
        LocalNotificationService.shared.scheduleProactiveMessage(text, in: delay, conversationId: conversationId)
        UserDefaults.standard.set(
            Date().addingTimeInterval(delay).timeIntervalSince1970,
            forKey: Self.lastScheduledKey
        )
    }

    /// 随机抖动 + 最小间隔 + 静默时段（23:00–09:00 顺延到次日早晨）。
    private func nextFireDelay() -> TimeInterval {
        var fire = Date().addingTimeInterval(TimeInterval(Int.random(in: 20 * 60 ..< 3 * 3600)))
        if let last = UserDefaults.standard.object(forKey: Self.lastScheduledKey) as? TimeInterval {
            let minNext = Date(timeIntervalSince1970: last).addingTimeInterval(Self.minInterval)
            if fire < minNext { fire = minNext }
        }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: fire)
        if hour >= Self.quietStartHour || hour < Self.quietEndHour {
            var comps = cal.dateComponents([.year, .month, .day], from: fire)
            comps.hour = Self.quietEndHour
            comps.minute = Int.random(in: 0 ..< 45)
            var morning = cal.date(from: comps) ?? fire
            if morning <= fire {
                morning = cal.date(byAdding: .day, value: 1, to: morning) ?? morning
            }
            fire = morning
        }
        return max(60, fire.timeIntervalSinceNow)
    }

    // MARK: - Background Task

    private func handle(_ task: BGProcessingTask) {
        scheduleBackgroundTask()   // 先排下一次，防断链
        let work = Task { [weak self] in
            guard let self, let pm = self.profileManager, let prov = self.providerManager else {
                task.setTaskCompleted(success: false); return
            }
            // v1 只为当前楼层生成（全楼层遍历一轮会弹多条通知，先克制）
            await self.scheduleNext(for: pm.currentProfile, providerManager: prov)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// 注册下次 BGTask（earliestBeginDate 6h 后，需要网络）。
    private func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
