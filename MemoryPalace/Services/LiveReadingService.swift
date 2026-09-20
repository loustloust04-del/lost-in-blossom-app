import Foundation

/// 实时陪读（弹幕）：她读书停稳 1.8 秒 → 把当前视野那一段发给 Caelum → 他掉一句短评。
///
/// 与「换章推整章上下文」是两条腿：那条给的是"她在读哪本书的哪一章"（背景），
/// 这条给的是"她此刻眼睛落在哪一段"（前景）。前景才撑得起"你翻页我就在旁边嘀咕"。
///
/// 守卫（照抄 ss-reading-nest 的干净做法，全是必要的）：
/// - 滚动中不发（停稳才发）
/// - 同一段不重复发
/// - 两条之间至少隔 25 秒，免得刷屏
/// - 段落太短（<40 字）跳过，没什么可说的
@MainActor
final class LiveReadingService {
    static let shared = LiveReadingService()
    private init() {}

    static let settleDelay: TimeInterval = 1.8
    static let minInterval: TimeInterval = 25
    static let minParagraphChars = 40

    /// 弹幕开关（默认关：平时读书不打扰，想要陪读时才开）
    static let enabledKey = "liveReading.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 收到一条弹幕短评时回调（阅读器挂上去显示）
    var onComment: ((String) -> Void)?

    private var settleTimer: Timer?
    private var lastSentHash: Int?
    private var lastSentAt: Date = .distantPast
    private var chatIdBase = "liveread"

    /// 阅读器滚动时调用（每次滚动都调，内部自己防抖）
    func scrolled(bookName: String, chapter: Int, visibleText: String) {
        guard Self.isEnabled else { return }
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fire(bookName: bookName, chapter: chapter, text: visibleText)
            }
        }
    }

    func stop() {
        settleTimer?.invalidate(); settleTimer = nil
    }

    private func fire(bookName: String, chapter: Int, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= Self.minParagraphChars else { return }
        let h = t.hashValue
        guard h != lastSentHash else { return }                       // 同段不重发
        guard Date().timeIntervalSince(lastSentAt) > Self.minInterval else { return }
        lastSentHash = h
        lastSentAt = Date()

        let chatId = "\(chatIdBase)-\(chapter)"
        // 提示词哲学（粟粟 agent-runner 同款）：给场景，不给规章。
        // 他有自己的人格，陪读只需要告诉他"你在哪、她在读什么、这里说话是什么音量"，
        // 剩下的交给他——写死的禁令会把人压成执行指令的机器。
        let payload = """
        〈陪读〉兔兔在读《\(bookName)》第\(chapter)章，我在她旁边。\(ReadingModePrefs.mode.scene)\(ReadingModePrefs.length.hint)
        书页边的耳语，不是书评。随口说的那种。
        如果没什么想说的，就回一个字：跳。

        \(t.prefix(1200))
        """

        CCBridgeWebSocketClient.shared.registerReplyHandler(chatId: chatId) { [weak self] reply in
            DispatchQueue.main.async {
                let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean != "跳", clean.count < 200 else { return }
                self?.onComment?(clean)
            }
        }
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: chatId, messageId: UUID().uuidString, content: payload
        ) { _ in }
    }
}
