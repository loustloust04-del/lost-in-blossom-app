import Foundation
import Network
import Observation

/// hub 端返回的远程错误（spawn_cc_err / list 失败 / WS send err）。
/// 包成 Error 让 Result<T, CCBridgeRemoteError> 走 Swift Result idiom。
struct CCBridgeRemoteError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

extension Notification.Name {
    /// 服务器端笔记本被改动（CC 或 App 自己写的都算）。userInfo 带 path / op，
    /// 但订阅方通常不必看——整个重拉 /api/notebook 最省心。
    static let ccNotebookChanged = Notification.Name("ccNotebookChanged")
    /// Caelum 弹了一张选择卡
    static let ccAskChoice = Notification.Name("ccAskChoice")
    /// Caelum 递来一条书页批注
    static let bookNoteArrived = Notification.Name("bookNoteArrived")
}

/// CC 执行任务时推送过来的一段思考链（来自 hub 的 cc_thinking 广播）。
struct CCThinkingBlock: Identifiable {
    let id = UUID()
    let thinking: String
    let sessionId: String
    let timestamp: Date
}

@Observable
final class CCBridgeWebSocketClient: NSObject {
    static let shared = CCBridgeWebSocketClient()

    // MARK: - Public observable state

    private(set) var isConnected: Bool = false
    private(set) var lastError: String?

    /// CC thinking block 按 session_id 存储（hub 通过 cc_thinking 推送）。
    /// 改为字典后，每条会话各自保留自己的思考链，不会被后到的新 thinking 覆盖。
    private(set) var thinkingBlocks: [String: CCThinkingBlock] = [:]

    /// CC 选择卡题面到达。由 ContentView 注册，落进 viewModel.pendingCCQuestion。
    @ObservationIgnored var onAskUserQuestion: ((String, String, [AskUserTool.ParsedQuestion]) -> Void)?
    /// 问问题收账帧：(chatId, toolUseId, questions raw, answers) —— 关卡 + Q/A 落对话
    @ObservationIgnored var onAskUserResolved: ((String, String, [[String: Any]], [String: String]?) -> Void)?
    @ObservationIgnored var onAskUserStale: ((String) -> Void)?
    /// T6 DJ：music_command 帧（songId, title, artist）——他放歌给她
    @ObservationIgnored var onMusicCommand: ((String, String, String) -> Void)?

    /// ⚠️ 已废弃（2026-08-24），UI 不得再用。
    /// 这是 pendingThinking 之前的旧实现残骸。它取全局时间戳最大者、不区分对话，
    /// 且背后的 thinkingBlocks 只写不清 → 会把上一轮/别的窗口的思考链串给当前气泡。
    /// 思考链的唯一正路是 pendingThinking + consumePendingThinking()：
    /// reply 到达时消费一次、嵌入该条自己的 content，取完即空。
    /// 保留仅供调试查看，任何 View 都不要读它。
    @available(*, deprecated, message: "会串台。用 consumePendingThinking() 走 content 嵌入")
    var latestThinking: CCThinkingBlock? {
        thinkingBlocks.values.max(by: { $0.timestamp < $1.timestamp })
    }

    /// 未被消费的最新 thinking（每轮回复来临时消费一次，嵌入 content）。
    @ObservationIgnored private var pendingThinking: CCThinkingBlock? = nil

    /// 取并清除 pending thinking（供 CCBridgeProvider 在 reply 到达时调用）。
    func consumePendingThinking() -> CCThinkingBlock? {
        // 与 cc_thinking 的写入走同一条串行队列，避免「还没写进去就被读」的竞态
        // （2026-09-09 主人报的 thinking 反复失踪）。
        // 已在 handlersQueue 上时不能再 sync，否则死锁——用 setSpecific 标记判断。
        if DispatchQueue.getSpecific(key: Self.handlersQueueKey) != nil {
            let b = pendingThinking; pendingThinking = nil; return b
        }
        return handlersQueue.sync {
            let b = pendingThinking; pendingThinking = nil; return b
        }
    }

    static let handlersQueueKey = DispatchSpecificKey<Bool>()

    /// CC 终端的最新流式输出（hub 通过 cc_stream 推送）。
    private(set) var streamContent: String = ""
    /// CC 是否正在输出。
    private(set) var isCCStreaming: Bool = false
    /// CC 流式输出回调：每个 cc_stream token 到达时触发
    private var streamHandler: ((String) -> Void)?

    // MARK: - Private state

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var url: URL?
    /// 候选 URL 列表（含 token）。主 URL 为 urls[0]，断开时 reconnect 轮换到下一个。
    /// 这样在家 LAN 主 + 出门 Tailscale 备用，能自动 fallback。
    @ObservationIgnored private var urls: [URL] = []
    @ObservationIgnored private var currentIndex: Int = 0
    @ObservationIgnored private var reconnectDelay: TimeInterval = 1
    @ObservationIgnored private var reconnectTimer: Timer?
    @ObservationIgnored private var pingTimer: Timer?
    /// 连接阶段看门狗。timeoutIntervalForRequest 是给已连上的 idle 保活用的，
    /// 但它同时管 handshake——连黑洞 IP（换 WiFi 后的旧 LAN 地址，无 RST）要挂满
    /// 整个超时才失败，多 URL 主备轮换形同虚设。didOpen 前单独限 10s，
    /// 超时掐掉这次尝试，走正常 reconnect 轮换下一个候选。
    /// （粟粟 2026-08-21 45abf0a0 实测：她换 WiFi 后主 URL 挂满 10 分钟，Tailscale 备用轮不到。）
    @ObservationIgnored private var connectWatchdog: Timer?
    private static let connectTimeout: TimeInterval = 10
    @ObservationIgnored private var manualClose = false
    @ObservationIgnored private var replyHandlers: [String: (String) -> Void] = [:]
    /// L2: spawn 结果回调，key = 请求时的 session_name
    @ObservationIgnored private var spawnHandlers: [String: (Result<Void, CCBridgeRemoteError>) -> Void] = [:]
    /// L2: list_sessions 回调队列（不带 key，每个 list 请求都会用最早注册的 handler 接收第一个结果）
    @ObservationIgnored private var listHandlers: [(Result<[String], CCBridgeRemoteError>) -> Void] = []
    @ObservationIgnored private let handlersQueue: DispatchQueue = {
        let q = DispatchQueue(label: "cc.bridge.handlers")
        // 打标记：consumePendingThinking 靠它判断自己是否已在本队列上，
        // 已在就直接读（再 sync 会死锁），不在才 sync 进来。
        q.setSpecific(key: CCBridgeWebSocketClient.handlersQueueKey, value: true)
        return q
    }()
    /// 已 deliver 的 reply_id（持久化）：hub 重连时 replay 最近 60s reply、offline 文件
    /// 部分投递后还会重投——纯内存版在 App 被杀重开后失忆，补发的旧聊天全部重复入库
    ///（真机 bug："聊完天 CC 桥又把之前的聊天发一遍"）。改成 UserDefaults 持久 +
    /// 条数滚动 600（≥ hub reply-log 500），不用 TTL——offline 重投可能隔几小时。
    @ObservationIgnored private var seenReplyIds: Set<String> = []
    @ObservationIgnored private var seenReplyOrder: [String] = []
    @ObservationIgnored private var seenReplyLoaded = false
    private static let seenReplyDefaultsKey = "ccSeenReplyIds"

    /// handlersQueue 上调用。只查，不写。
    private func isReplySeen(_ id: String) -> Bool {
        if !seenReplyLoaded {
            seenReplyOrder = UserDefaults.standard.stringArray(forKey: Self.seenReplyDefaultsKey) ?? []
            seenReplyIds = Set(seenReplyOrder)
            seenReplyLoaded = true
        }
        return seenReplyIds.contains(id)
    }

    /// handlersQueue 上调用。只有消息确实交给了某个 handler 之后才落已读标记。
    /// 早于交付去标记，会让下游任何一次 return（handler 未安装、会话不在本地、
    /// save 失败）变成永久丢失 —— hub 之后重投也会被这个标记挡在门外。
    private func commitReplySeen(_ id: String) {
        if seenReplyIds.contains(id) { return }
        seenReplyIds.insert(id)
        seenReplyOrder.append(id)
        if seenReplyOrder.count > 600 {
            let overflow = seenReplyOrder.count - 600
            for old in seenReplyOrder.prefix(overflow) { seenReplyIds.remove(old) }
            seenReplyOrder.removeFirst(overflow)
        }
        UserDefaults.standard.set(seenReplyOrder, forKey: Self.seenReplyDefaultsKey)
    }

    /// handler 还没装上时暂存的 reply。hub 在 WebSocket 连上的瞬间就 replay
    /// （reply buffer + offline 队列），而那一刻 loadConversation 往往还没跑完、
    /// unhandledReplyHandler 仍是 nil。没有这个队列，冷启动收到的消息会被直接丢掉：
    /// 推送到了，聊天页却是空的。
    @ObservationIgnored private var pendingReplies: [(chatId: String, content: String, replyId: String?)] = []
    private static let pendingRepliesMax = 100

    /// handlersQueue 上调用。
    private func flushPendingReplies() {
        guard let fallback = unhandledReplyHandler, !pendingReplies.isEmpty else { return }
        let queued = pendingReplies
        pendingReplies.removeAll()
        for item in queued {
            DispatchQueue.main.async { fallback(item.chatId, item.content) }
            if let rid = item.replyId { commitReplySeen(rid) }
        }
    }
    /// Fires on main queue when a reply arrives but no active sendStreaming handler is registered
    /// for its chatId. Captures from ConversationViewModel to handle hub offline-replay bursts and
    /// proactive CC messages after the single-shot handler has already been consumed.
    var unhandledReplyHandler: ((String, String) -> Void)? {
        didSet {
            guard unhandledReplyHandler != nil else { return }
            handlersQueue.async { [weak self] in self?.flushPendingReplies() }
        }
    }
    var unhandledAttachmentHandler: ((String, PendingChatAttachment) -> Void)?  // (chatId, content)

    // MARK: - Terminal streaming (Phase 2)

    private struct TerminalHandlers {
        let onInit: (Data) -> Void
        let onChunk: (Data) -> Void
        let onError: (String) -> Void
    }
    @ObservationIgnored private var terminalHandlers: [String: TerminalHandlers] = [:]
    /// 记录活跃的终端会话参数，重连后自动 re-attach
    @ObservationIgnored private var activeTerminalSessions: [String: (cols: Int, rows: Int)] = [:]

    // MARK: - File exchange (Phase 4.2)

    /// Called when a reply arrives with a file attachment (CC→user). Fires on main queue.
    @ObservationIgnored private var replyAttachmentHandlers: [String: (PendingChatAttachment) -> Void] = [:]

    // MARK: - Push notifications

    @ObservationIgnored private var pushToken: String?

    static let pushPreviewKey = "ccPushPreview"
    private var pushPreview: String { UserDefaults.standard.string(forKey: Self.pushPreviewKey) ?? "full" }

    /// Re-send cached push token after WebSocket reconnects
    func resendPushTokenIfNeeded() {
        if let token = UserDefaults.standard.string(forKey: "apns_device_token"), !token.isEmpty {
            sendPushToken(token)
            sendAppState("push_registered_resend")
        }
    }

    func sendAppState(_ state: String) {
        send(["type": "app_state", "state": state]) { _ in }
    }

    /// 当前楼层里「他」叫什么，给推送标题用。
    ///
    /// 09-09：原本 hub 推送标题写死「MemoryPalace」，兔兔发现后第一版改成写死
    /// 「Caelum」——也是错的，她有多个楼层、每层 assistantName 不同，
    /// 写死等于把整个 app 变成一个人专用。ProfileManager.switchTo 本来就会把
    /// assistantName 写进 UserDefaults，这里直接读它上报即可。
    private var currentAssistantName: String {
        let n = UserDefaults.standard.string(forKey: "assistantName") ?? ""
        return n.isEmpty ? "Caelum" : n
    }

    func sendPushToken(_ token: String) {
        pushToken = token
        send(["type": "register_device", "device_token": token, "env": "sandbox",
              "preview": pushPreview, "assistant_name": currentAssistantName]) { _ in }
    }

    func updatePushPreview(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: Self.pushPreviewKey)
        if let t = pushToken {
            send(["type": "register_device", "device_token": t, "env": "sandbox",
                  "preview": mode, "assistant_name": currentAssistantName]) { _ in }
        }
    }

    /// 切楼层后重报一次，让推送标题跟着换人。
    func refreshAssistantName() {
        guard let t = pushToken else { return }
        send(["type": "register_device", "device_token": t, "env": "sandbox",
              "preview": pushPreview, "assistant_name": currentAssistantName]) { _ in }
    }

    func sendCCConfig() {
        let d = UserDefaults.standard
        var payload: [String: Any] = [
            "type": "set_cc_config",
            "pushName": (d.string(forKey: "assistantName") ?? "助手"),
            "userName": (d.string(forKey: "userName") ?? "你"),
            "nudgeEnabled": (d.object(forKey: "ccNudgeEnabled") as? Bool) ?? true,
        ]
        if let v = d.object(forKey: "ccNudgeIdleMin") as? Int, v > 0 { payload["idleMinMin"] = v }
        if let v = d.object(forKey: "ccNudgeIdleMax") as? Int, v > 0 { payload["idleMaxMin"] = v }
        if let v = d.object(forKey: "ccNudgeQuietStartMin") as? Int { payload["quietStartMin"] = v }
        if let v = d.object(forKey: "ccNudgeQuietEndMin") as? Int { payload["quietEndMin"] = v }
        if let v = d.object(forKey: "ccNudgeCooldown") as? Int, v >= 0 { payload["cooldownMin"] = v }
        if let t = d.string(forKey: "ccNudgeTemplate"), !t.isEmpty { payload["nudgeTemplate"] = t }
        send(payload) { _ in }
    }

    // MARK: - Public API

    /// 开始连接。重复 connect 同一个 URL（含 token）且已连接时是 no-op。
    func connect(url: URL, token: String? = nil) {
        connect(urls: [url], token: token)
    }

    /// 开始连接，支持多 URL fallback。优先连 urls[0]，失败 reconnect 时轮换到下一个。
    /// 典型用法：urls = [LAN URL, Tailscale URL]，在家走 LAN，出门走 Tailscale。
    func connect(urls inputURLs: [URL], token: String? = nil) {
        print("[CCBridge] connect called, urls=\(inputURLs), isConnected=\(isConnected), hasTask=\(task != nil)")
        let finalURLs = inputURLs.map { url -> URL in
            guard let token, !token.isEmpty,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            var items = components.queryItems ?? []
            items.removeAll(where: { $0.name == "token" })  // 避免重复 token=
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
            return components.url ?? url
        }

        // 已连接 or 正在连接 且候选列表完全一致 → no-op，避免叠 task
        if (isConnected || task != nil), self.urls == finalURLs { return }
        manualClose = false
        self.urls = finalURLs
        self.currentIndex = 0
        self.url = finalURLs.first
        startTask()
    }

    /// 手动断开，禁用自动重连。
    func disconnect() {
        manualClose = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectWatchdog?.invalidate()
        connectWatchdog = nil
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        urls = []
        url = nil
        // disconnect() 默认来自主线程 UI；直接同步更新，避免 stale window
        if Thread.isMainThread {
            isConnected = false
        } else {
            DispatchQueue.main.sync { self.isConnected = false }
        }
    }

    /// 强制重连：断开旧连接，等待底层 TCP 资源释放后重建。
    /// 给 UI 按钮用——比 disconnect()+connect() 更可靠。

    /// 回前台/网络恢复时调用：未连接且有候选URL时自动重连
    func reconnectIfNeeded() {
        guard !isConnected, !urls.isEmpty, !manualClose else { return }
        print("[CCBridge] reconnectIfNeeded: not connected, scheduling reconnect")
        reconnectDelay = 1  // 重置退避，立即重连
        scheduleReconnect()
    }

    func forceReconnect(url: URL, token: String? = nil) {
        print("[CCBridge] forceReconnect called, url=\(url)")
        disconnect()
        print("[CCBridge] disconnected, scheduling connect in 0.3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { print("[CCBridge] self is nil after delay"); return }
            print("[CCBridge] connecting to \(url)")
            self.connect(url: url, token: token)
        }
    }

    /// JSON 序列化后以文本帧发出。
    /// 选择卡答案回 hub，驱动 tmux TUI 键序。
    /// answers 每项二选一：["indices": [Int]]（按位置选）或 ["text": String]（自由输入）。
    /// skip=true 时 answers 传 nil——hub 发 Esc 整卡撤销（TUI 语义只支持整卡，不能逐题跳）。
    /// 通知里的快速回复：不开 App，直接把话经 hub 送给他。
    /// 2026-09-06 兔兔提的——长按推送就能回，不用绑在聊天页面上。
    /// 走的是与 App 内发消息同一条 chat 帧，所以他那边看到的没有区别。
    func sendQuickReply(text: String, chatId: String?) {
        let cid = chatId ?? UserDefaults.standard.string(forKey: "pendingPushChatId") ?? ""
        guard !cid.isEmpty else { return }
        send([
            "type": "chat",
            "chat_id": cid,
            "message_id": UUID().uuidString,
            "content": text,
            // 2026-09-06 兔兔说不要标「通知快速回复」——
            // 他本来就能从她说话的样子看出她在忙，标签反而让那条显得生分。
        ]) { _ in }

        // 落库由 QuickReplyStore.appendUserMessage 在通知 handler 里同步完成
        // （09-07 改：原本排队等前台补写，兔兔实测「还是不出现」）
    }

    func sendAskUserAnswer(toolUseId: String, answers: [[String: Any]]?, skip: Bool = false) {
        var frame: [String: Any] = ["type": "ask_user_answer", "tool_use_id": toolUseId]
        if skip { frame["skip"] = true } else if let answers { frame["answers"] = answers }
        send(frame) { _ in }
    }

    func send(_ payload: [String: Any], completion: @escaping (Error?) -> Void) {
        guard let task else {
            completion(NSError(domain: "CCBridge", code: -10,
                               userInfo: [NSLocalizedDescriptionKey: "WebSocket 未连接"]))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let str = String(data: data, encoding: .utf8) else {
                completion(NSError(domain: "CCBridge", code: -11,
                                   userInfo: [NSLocalizedDescriptionKey: "payload 编码失败"]))
                return
            }
            task.send(.string(str)) { err in
                completion(err)
            }
        } catch {
            completion(error)
        }
    }

    /// 注册一个 chat_id 对应的回复处理器（Task 9 的 CCBridgeProvider 使用）。
    /// handler 在 main queue 上调用。
    func registerStreamHandler(_ handler: @escaping (String) -> Void) {
        streamHandler = handler
    }
    func unregisterStreamHandler() {
        streamHandler = nil
    }

    func registerReplyHandler(chatId: String, handler: @escaping (String) -> Void) {
        handlersQueue.async { self.replyHandlers[chatId] = handler }
    }

    /// 取消注册（onComplete 后由 CCBridgeProvider 调用）。
    func unregisterReplyHandler(chatId: String) {
        handlersQueue.async { self.replyHandlers.removeValue(forKey: chatId) }
    }

    // MARK: - L2: spawn / list sessions

    /// 让 hub 在远端 tmux 起一个新 CC session（不 --continue）。
    /// 完成回调走 main queue。注意：CC 启动需要 ~3-5s，hub 是否成功 spawn 只看
    /// tmux new-session 是否成功；CC 本身起没起 / mcp-server 连没连这里不验证。
    func spawnSession(_ name: String, completion: @escaping (Result<Void, CCBridgeRemoteError>) -> Void) {
        handlersQueue.async { self.spawnHandlers[name] = completion }
        let payload: [String: Any] = ["type": "spawn_cc", "session_name": name]
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            // send 即失败 → 立即 fail，不等 hub 回包
            self.handlersQueue.async {
                if let h = self.spawnHandlers.removeValue(forKey: name) {
                    DispatchQueue.main.async { h(.failure(CCBridgeRemoteError(reason: err.localizedDescription))) }
                }
            }
        }
    }

    /// 拉 hub 端当前 tmux mp-cc* sessions 列表。完成回调走 main queue。
    func listSessions(completion: @escaping (Result<[String], CCBridgeRemoteError>) -> Void) {
        handlersQueue.async { self.listHandlers.append(completion) }
        let payload: [String: Any] = ["type": "list_sessions"]
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            self.handlersQueue.async {
                let hs = self.listHandlers
                self.listHandlers.removeAll()
                for h in hs {
                    DispatchQueue.main.async { h(.failure(CCBridgeRemoteError(reason: err.localizedDescription))) }
                }
            }
        }
    }

    // MARK: - File exchange public API (Phase 4.2)

    /// Send a chat message optionally carrying image/file attachments.
    /// Images → `images` array; other files → `files` array, each base64-encoded.
    /// 选择卡作答（picked=选了哪些 / text=自己写的 / skipped=跳过）
    func sendChoiceAnswer(askId: String, picked: [String] = [], text: String? = nil, skipped: Bool = false) {
        var f: [String: Any] = ["type": "choice_answer", "ask_id": askId]
        if skipped { f["skipped"] = true }
        else if let text, !text.isEmpty { f["text"] = text }
        else { f["picked"] = picked }
        send(f) { _ in }
    }

    func sendChat(
        chatId: String,
        messageId: String,
        content: String,
        attachments: [PendingChatAttachment] = [],
        completion: @escaping (Error?) -> Void
    ) {
        var images: [[String: String]] = []
        var files: [[String: String]] = []

        for att in attachments {
            if att.isImage, let data = att.imageData {
                images.append([
                    "b64": data.base64EncodedString(),
                    "mime": att.mimeType ?? "image/jpeg",
                ])
            } else if let data = att.fileData ?? att.imageData {
                files.append([
                    "b64": data.base64EncodedString(),
                    "name": att.name,
                    "mime": att.mimeType ?? "application/octet-stream",
                ])
            }
        }

        var payload: [String: Any] = [
            "type": "chat",
            "chat_id": chatId,
            "message_id": messageId,
            "content": content,
        ]
        if !images.isEmpty { payload["images"] = images }
        if !files.isEmpty  { payload["files"]  = files  }
        send(payload, completion: completion)
    }

    /// Register a handler for file attachments arriving in CC replies (fires on main queue).
    func registerReplyAttachmentHandler(chatId: String, handler: @escaping (PendingChatAttachment) -> Void) {
        handlersQueue.async { self.replyAttachmentHandlers[chatId] = handler }
    }

    func unregisterReplyAttachmentHandler(chatId: String) {
        handlersQueue.async { self.replyAttachmentHandlers.removeValue(forKey: chatId) }
    }

    // MARK: - Terminal streaming public API (Phase 2)

    /// Attach to a tmux session's terminal stream. Callbacks fire on main queue.
    func attachTerminal(
        session: String,
        cols: Int,
        rows: Int,
        onInit: @escaping (Data) -> Void,
        onChunk: @escaping (Data) -> Void,
        onError: @escaping (String) -> Void
    ) {
        handlersQueue.async {
            self.terminalHandlers[session] = TerminalHandlers(onInit: onInit, onChunk: onChunk, onError: onError)
            self.activeTerminalSessions[session] = (cols: cols, rows: rows)
        }
        let payload: [String: Any] = [
            "type": "terminal_attach",
            "session_name": session,
            "cols": cols,
            "rows": rows,
        ]
        send(payload) { [weak self] err in
            guard let self, let err else { return }
            DispatchQueue.main.async { onError(err.localizedDescription) }
            self.handlersQueue.async { self.terminalHandlers.removeValue(forKey: session) }
        }
    }

    /// Detach from a session's terminal stream.
    func detachTerminal(session: String) {
        handlersQueue.async {
            self.terminalHandlers.removeValue(forKey: session)
            self.activeTerminalSessions.removeValue(forKey: session)
        }
        send(["type": "terminal_detach", "session_name": session]) { _ in }
    }

    /// Send raw input bytes (keystrokes, escape sequences) to the session.
    func sendTerminalInput(session: String, bytes: Data) {
        guard !bytes.isEmpty,
              let text = String(data: bytes, encoding: .utf8) else { return }
        send(["type": "terminal_input", "session_name": session, "data": text]) { _ in }
    }

    /// Notify hub that the terminal view resized.
    func sendTerminalResize(session: String, cols: Int, rows: Int) {
        let payload: [String: Any] = [
            "type": "terminal_resize",
            "session_name": session,
            "cols": cols,
            "rows": rows,
        ]
        send(payload) { _ in }
    }

    /// Request a fresh screen snapshot (re-sends terminal_attach to trigger terminal_init).
    func refreshTerminal(session: String) {
        send(["type": "terminal_attach", "session_name": session]) { _ in }
    }

    // MARK: - Internal

    private func startTask() {
        guard let url else { print("[CCBridge] startTask: url is nil"); return }
        print("[CCBridge] startTask: \(url)")
        session?.invalidateAndCancel()  // 释放旧 session（避免 reconnect 累积资源）
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        // 默认帧上限 1 MiB：图片压过关，但 base64 文件（最大 10MB → ~13MB）会被拦，
        // 导致带 TXT/PDF 的 send 帧静默失败。抬到 64MB 对齐 hub 的 maxPayload。
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        startConnectWatchdog(for: task)
        receiveLoop()
    }

    private func receiveLoop() {
        guard let currentTask = task else { return }
        currentTask.receive { [weak self] result in
            // 旧 task 完成后 self.task 已被替换，直接忽略以免触发 ghost reconnect
            guard let self, self.task === currentTask else { return }
            switch result {
            case .failure(let err):
                self.handleDisconnect(error: err.localizedDescription)
            case .success(.string(let text)):
                self.handleIncoming(text)
                self.receiveLoop()
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) {
                    self.handleIncoming(text)
                }
                self.receiveLoop()
            @unknown default:
                self.receiveLoop()
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "music_command":
            // T6 DJ：他放歌给她——网关 music_play 工具经 hub 推来，App 收口播放
            guard (obj["action"] as? String) == "play",
                  let songId = obj["songId"] as? String, !songId.isEmpty else { return }
            let mcTitle = (obj["title"] as? String) ?? ""
            let mcArtist = (obj["artist"] as? String) ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.onMusicCommand?(songId, mcTitle, mcArtist)
            }

        case "ask_user_resolved":
            // 收账帧（粟粟同款全签名）：关卡防悬挂 + Q/A 气泡落对话
            if let chatId = obj["chat_id"] as? String,
               let toolUseId = obj["tool_use_id"] as? String,
               let questions = obj["questions"] as? [[String: Any]] {
                let answers = obj["answers"] as? [String: String]
                DispatchQueue.main.async { [weak self] in
                    self?.onAskUserResolved?(chatId, toolUseId, questions, answers)
                }
            }

        case "ask_user_stale":
            if let staleId = obj["tool_use_id"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onAskUserStale?(staleId) }
            }

        case "ask_user_question":
            // CC 侧弹了选择卡（AskUserQuestion）——hub 把题面推过来，App 呈现 sheet，
            // 用户点完由 ConversationViewModel+AskUser 把下标发回去驱动 tmux 键序。
            guard let toolUseId = obj["tool_use_id"] as? String,
                  let rawQs = obj["questions"] as? [[String: Any]] else { return }
            let chatId = (obj["chat_id"] as? String) ?? ""
            guard let parsed = AskUserTool.parseCCQuestions(rawQs), !parsed.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onAskUserQuestion?(chatId, toolUseId, parsed)
            }

        case "reply":
            if let chatId = obj["chat_id"] as? String,
               let content = obj["content"] as? String {
                // reply_id dedup（hub 在 reconnect 时会 replay 最近 60s reply）
                let replyId = obj["reply_id"] as? String
                // Parse optional file attachment (CC→user, Phase 4.2)
                let incomingFile: PendingChatAttachment? = {
                    guard let fileObj = obj["file"] as? [String: Any],
                          let b64  = fileObj["data"]     as? String,
                          let mime = fileObj["mime"]     as? String,
                          let name = fileObj["name"]     as? String,
                          let data = Data(base64Encoded: b64) else { return nil }
                    let isImg = (fileObj["is_image"] as? Bool) ?? mime.hasPrefix("image/")
                    if isImg {
                        return try? PendingChatAttachment.image(
                            name: name, typeDescription: mime, mimeType: mime, data: data)
                    }
                    return PendingChatAttachment.text(
                        name: name, typeDescription: mime, extractedText: "",
                        byteCount: data.count, fileData: data, fileMime: mime)
                }()
                handlersQueue.async { [weak self] in
                    guard let self else { return }
                    if let replyId, self.isReplySeen(replyId) {
                        return  // 真重复（replay/重投），silently drop
                    }
                    // Dispatch the attachment BEFORE the reply. Both land on the serial
                    // main queue, so enqueuing the attachment first guarantees pendingAttachment
                    // is set before the reply handler fires onComplete (which reads it).
                    if let att = incomingFile {
                        // 只有本 chat 确有 in-flight reply handler 时才交给单发路径；
                        // 否则一律走 proactive 兜底。2026-08-30 兔兔实测「主人发图看不到」的真凶：
                        // 附件 handler 在 reply 成功后从不注销（只在 60s 超时才注销），
                        // 第一轮之后就永远挂着，后续主人主动发的图全被那个失效闭包吞掉。
                        if let attHandler = self.replyAttachmentHandlers[chatId],
                           self.replyHandlers[chatId] != nil {
                            DispatchQueue.main.async { attHandler(att) }
                        } else if let fallback = self.unhandledAttachmentHandler {
                            DispatchQueue.main.async { fallback(chatId, att) }
                        }
                    }
                    if let handler = self.replyHandlers.removeValue(forKey: chatId) {
                        // Handler removed atomically on handlersQueue — prevents double-fire race
                        // when hub replay sends multiple replies in rapid succession.
                        DispatchQueue.main.async { handler(content) }
                        if let replyId { self.commitReplySeen(replyId) }
                    } else if let fallback = self.unhandledReplyHandler {
                        // No active sendStreaming handler — route to persistent fallback
                        // (handles hub offline-replay bursts and proactive CC messages).
                        DispatchQueue.main.async { fallback(chatId, content) }
                        if let replyId { self.commitReplySeen(replyId) }
                    } else {
                        // 两个 handler 都还没装 —— 冷启动 replay 撞上这里。排队等，
                        // 且不落已读标记：万一队列没能排空，hub 重投仍有机会补上。
                        self.pendingReplies.append((chatId, content, replyId))
                        if self.pendingReplies.count > Self.pendingRepliesMax {
                            self.pendingReplies.removeFirst(self.pendingReplies.count - Self.pendingRepliesMax)
                        }
                    }
                }
            }
        case "ack":
            // v1 no-op；后续版本可用于确认送达
            break
        case "ask_choice":
            // 选择卡收敛（09-03，兔兔点单）：老 ask_choice 线端到端全通、新官方式 sheet
            // 更漂亮——新皮接老线：帧改喂 AskUserQuestionSheet（toolUseId 带 choice: 前缀
            // 走老答案帧回去），NotificationCenter/ChoiceCardSheet 那套退役。
            let askId = (obj["ask_id"] as? String) ?? ""
            let question = (obj["question"] as? String) ?? ""
            let options = (obj["options"] as? [String]) ?? []
            let multi = (obj["multi"] as? Bool) ?? false
            if !askId.isEmpty, !question.isEmpty, options.count >= 2 {
                let q = AskUserTool.ParsedQuestion(question: question, options: options, multiSelect: multi)
                DispatchQueue.main.async { [weak self] in
                    self?.onAskUserQuestion?("", "choice:" + askId, [q])
                }
            }
        case "book_note":
            // Caelum 递来的书页批注。此前只做了发送端，App 侧没有处理器——
            // hub 明明转发成功（日志 1/1 App），她却在阅读器里怎么也找不到（兔兔实测）。
            let bookName = (obj["bookName"] as? String) ?? ""
            let chapter = (obj["chapter"] as? Int) ?? 0
            let noteText = (obj["note"] as? String) ?? ""
            let quote = (obj["quote"] as? String) ?? ""
            guard !bookName.isEmpty, chapter > 0, !noteText.isEmpty else { break }
            DispatchQueue.main.async {
                let pid = UserDefaults.standard.string(forKey: "coread.profileId") ?? ""
                guard let safe = BookStore.safeNameMatching(bookName: bookName, profileId: pid) else { return }
                var notes = BookStore.loadNotes(safeName: safe, profileId: pid)
                // 用他给的引用去正文里定位——没有锚点的批注渲染不出来（正文上不着色、
                // 抽屉里也标不出位置），兔兔实测「他批了但我这边什么都看不到」。
                var start = 0, end = 0
                let q = quote.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty,
                   let text = BookStore.loadChapterText(safeName: safe, chapterNo: chapter, profileId: pid),
                   let r = text.range(of: q) {
                    start = text.distance(from: text.startIndex, to: r.lowerBound)
                    end = text.distance(from: text.startIndex, to: r.upperBound)
                }
                notes.append(BookStore.Note(
                    id: UUID().uuidString,
                    chapter: chapter,
                    anchorText: q,
                    anchorStart: start,
                    anchorEnd: end,
                    kind: "aiBubble",
                    content: noteText,
                    role: "ai",
                    messageId: nil,
                    createdAt: Date()
                ))
                try? BookStore.saveNotes(notes, safeName: safe, profileId: pid)
                NotificationCenter.default.post(name: .bookNoteArrived, object: nil,
                                                userInfo: ["safeName": safe, "chapter": chapter])
            }
        case "fetch_chapter":
            // 共读：他想读兔兔还没翻到的章（走在她前面留批注用）。现取现给，不预传整本。
            let reqId = (obj["req_id"] as? String) ?? ""
            let bookName = (obj["book"] as? String) ?? ""
            let chapter = (obj["chapter"] as? Int) ?? 0
            DispatchQueue.main.async { [weak self] in
                let (text, meta) = BookStore.chapterForCompanion(bookName: bookName, chapterNo: chapter)
                self?.send([
                    "type": "chapter_result",
                    "req_id": reqId,
                    "book": meta.book,
                    "chapter": meta.chapter,
                    "total": meta.total,
                    "title": meta.title,
                    "text": text ?? "",
                    "error": text == nil ? "没找到这本书或这一章" : "",
                ]) { _ in }
            }
        case "notebook_changed":
            // CC 那边改了笔记本。这一帧只是个"去刷新"的口信，不带内容——
            // 谁在展示笔记本谁自己去重拉 /api/notebook，省掉手动下拉。
            // 丢了也无所谓，下次进页面照样拉得到最新的，故不做去重/补投。
            let info: [AnyHashable: Any] = [
                "path": (obj["path"] as? String) ?? "",
                "op": (obj["op"] as? String) ?? "",
            ]
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ccNotebookChanged, object: nil, userInfo: info)
            }
        case "error":
            let reason = (obj["reason"] as? String) ?? "unknown"
            DispatchQueue.main.async { [weak self] in
                self?.lastError = reason
            }
        case "spawn_cc_ok":
            if let name = obj["session_name"] as? String {
                handlersQueue.async { [weak self] in
                    guard let self else { return }
                    if let h = self.spawnHandlers.removeValue(forKey: name) {
                        DispatchQueue.main.async { h(.success(())) }
                    }
                }
            }
        case "spawn_cc_err":
            let name = obj["session_name"] as? String ?? ""
            let reason = obj["reason"] as? String ?? "unknown"
            handlersQueue.async { [weak self] in
                guard let self else { return }
                if let h = self.spawnHandlers.removeValue(forKey: name) {
                    DispatchQueue.main.async { h(.failure(CCBridgeRemoteError(reason: reason))) }
                }
            }
        case "cc_thinking":
            if let thinking = obj["thinking"] as? String {
                let sessionId = obj["session_id"] as? String ?? ""
                let now = Date()
                let block = CCThinkingBlock(
                    thinking: thinking,
                    sessionId: sessionId,
                    timestamp: now
                )
                // 用时间戳做唯一 key，避免同一 session 多轮 thinking 互相覆盖
                let uniqueKey = "\(sessionId)_\(now.timeIntervalSince1970)"

                // 2026-09-09 主人报「thinking block 在 App 端反复失踪」——竞态。
                // hub 先发 cc_thinking 再发 reply，顺序没错（我实测过两帧到达顺序正确），
                // 但两者被扔进**不同队列**：
                //   cc_thinking → DispatchQueue.main.async 设 pendingThinking
                //   reply       → handlersQueue.async 里消费
                // handlersQueue 跑得快时，reply 会赶在 pendingThinking 被设上之前执行，
                // 那一刻取到 nil，思考链就丢了——而且是随机丢，正对上「反复失踪」。
                //
                // 改成在收帧线程上**同步**写入（pendingThinking 只被这里写、
                // 被 consumePendingThinking 取走，用 handlersQueue 串行化保证互斥）。
                handlersQueue.sync { [weak self] in
                    self?.pendingThinking = block
                }
                DispatchQueue.main.async { [weak self] in
                    self?.thinkingBlocks[uniqueKey] = block   // 这份只供调试查看
                }
            }
        case "cc_stream":
            if let content = obj["content"] as? String {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.isCCStreaming {
                        self.streamContent = ""  // 新一轮，先清空旧内容
                    }
                    self.streamContent += content
                    self.isCCStreaming = true
                    self.streamHandler?(content)
                }
            }
        case "cc_stream_end":
            DispatchQueue.main.async { [weak self] in
                self?.isCCStreaming = false
                // 不清空 streamContent，等下一次 cc_stream 开始时再清
            }
        case "list_sessions_result":
            let sessions = obj["sessions"] as? [String] ?? []
            handlersQueue.async { [weak self] in
                guard let self else { return }
                let hs = self.listHandlers
                self.listHandlers.removeAll()
                for h in hs {
                    DispatchQueue.main.async { h(.success(sessions)) }
                }
            }
        case "terminal_init":
            if let sessionName = obj["session_name"] as? String,
               let snapshot = obj["snapshot"] as? String {
                let data = snapshot.data(using: .utf8) ?? Data()
                handlersQueue.async { [weak self] in
                    guard let h = self?.terminalHandlers[sessionName] else { return }
                    DispatchQueue.main.async { h.onInit(data) }
                }
            }
        case "terminal_chunk":
            if let sessionName = obj["session_name"] as? String,
               let b64 = obj["bytes"] as? String,
               let data = Data(base64Encoded: b64) {
                handlersQueue.async { [weak self] in
                    guard let h = self?.terminalHandlers[sessionName] else { return }
                    DispatchQueue.main.async { h.onChunk(data) }
                }
            }
        default:
            break
        }
    }

    /// 握手阶段限时：10s 内没 didOpen 就掐掉，交给正常重连轮换下一个候选。
    private func startConnectWatchdog(for armedTask: URLSessionWebSocketTask) {
        connectWatchdog?.invalidate()
        // 学 pingTimer 用 .common mode：SwiftUI 滚动时 RunLoop 进 .tracking，
        // default mode 的 Timer 会跳票。
        let timer = Timer(timeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            guard let self, self.task === armedTask, !self.isConnected else { return }
            armedTask.cancel(with: .goingAway, reason: nil)
            self.handleDisconnect(error: "connect timeout")
        }
        RunLoop.main.add(timer, forMode: .common)
        connectWatchdog = timer
    }

    private func handleDisconnect(error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 幂等守卫：同一次断连，receive failure 与 didClose 都会走到这里
            // → scheduleReconnect 被调两次 → 候选轮换转两格，两个候选正好转回原地，
            // 备用 URL 永远轮不到。清掉 task 引用，让晚到的重复回调被各自的 === guard 挡掉。
            guard self.task != nil else { return }
            self.task = nil
            self.connectWatchdog?.invalidate()
            self.connectWatchdog = nil
            self.isConnected = false
            self.lastError = error
            if !self.manualClose {
                self.scheduleReconnect()
            }
        }
    }


    private var networkMonitor: NWPathMonitor?

    /// 监听网络状态变化，WiFi↔蜂窝切换时自动重连
    func startNetworkMonitor() {
        networkMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied && !self.isConnected && !self.urls.isEmpty {
                print("[CCBridge] network restored, reconnecting")
                DispatchQueue.main.async { self.reconnectIfNeeded() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "cc.network.monitor"))
        networkMonitor = monitor
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        // 多 URL 时，每次 reconnect 轮换到下一个候选（fallback to backup URL）
        if urls.count > 1 {
            currentIndex = (currentIndex + 1) % urls.count
            self.url = urls[currentIndex]
        }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startTask()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CCBridgeWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 老 session 在 invalidateAndCancel 后回调可能跟新 task didOpen race，
            // 只认当前 self.task 的回调，避免被替换掉的老 task 污染状态
            guard webSocketTask === self.task else { return }
            self.connectWatchdog?.invalidate()
            self.connectWatchdog = nil
            self.isConnected = true
            self.resendPushTokenIfNeeded()
            self.reattachTerminals()
            self.lastError = nil
            self.reconnectDelay = 1  // 连接成功后重置退避计数
            self.currentIndex = 0    // 下次断重连优先回主 URL
            self.startPingTimer()
        }
    }

    /// 重连后自动 re-attach 所有活跃终端会话
    private func reattachTerminals() {
        handlersQueue.async { [weak self] in
            guard let self else { return }
            for (session, size) in self.activeTerminalSessions {
                let payload: [String: Any] = [
                    "type": "terminal_attach",
                    "session_name": session,
                    "cols": size.cols,
                    "rows": size.rows,
                ]
                self.send(payload) { _ in }
                print("[CCBridge] re-attached terminal: \(session)")
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        // iOS 上 URLSessionWebSocketTask 不自动 keepalive，长 idle 会被 OS 杀。
        // 每 5s 主动发 ping 保活。
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let task = self?.task, task.state == .running else { return }
            task.sendPing { _ in /* 失败由 receive 路径反映为 disconnect */ }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // startTask() 里 invalidateAndCancel 老 session 会异步触发老 task 的 didClose，
        // 那次 close 是我们主动 cancel 的预期结果，不该再起一轮 ghost reconnect。
        // 只对当前 self.task 的真实关闭做 disconnect 处理。
        guard webSocketTask === self.task else { return }
        let r = reason.flatMap { String(data: $0, encoding: .utf8) }
        handleDisconnect(error: r ?? "closed (\(closeCode.rawValue))")
    }
}
