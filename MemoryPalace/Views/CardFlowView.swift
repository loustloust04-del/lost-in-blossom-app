import SwiftUI
import SwiftData
import UIKit
import MarkdownUI
import UniformTypeIdentifiers
import VariableBlur

private struct TextSelectItem: Identifiable {
    let id: String
    let text: String
    let thinkingText: String?
}

/// [white-screen-fix A 刀] 聊天列表的 UIScrollView 通道 + 「回底」唯一写手。
/// 粟粟 6 月探针钉死的白屏元凶：`proxy.scrollTo(最后一条)` 逼 SwiftUI 从头到尾 mount
/// 全部 cell 去找目标（1276 条实测 4950 次 makeBubbleView），屏幕这期间就是白的；
/// 我们「三步走 × 七个触发」= 七场 mount 风暴互相 race。
/// UIKit 直写 contentOffset 不依赖 cell 测量、不 mount 远端（她的冷弹回底同款：
/// 「proxy.scrollTo 对 LazyVStack 远端目标按估算高度跳」`0942c8a2`）。
/// 列表方向不变、气泡不翻——07-02 反转列表三连炸的雷一个都不碰。
// ── [B 计划·反转列表] ──────────────────────────────────────────────────────
// ScrollView 整体翻转（rotation π + scaleX −1，走 CALayer transform），每个 cell 再翻回正，
// ForEach 吃 reversed。于是 offset 0 = 最新消息：进对话不用找、新消息插在物理顶自动出现、
// 在底吐字最后一行天然钉底。学 Stream Chat SwiftUI / 粟粟 5ccfb2b1。
// 七月回滚三雷的今日拆法：编辑框已是纯 SwiftUI TextField；WebView 气泡已原生化（砖 1）；
// 长按菜单接 BubbleMenuOverlay（砖 3）；思考链真机验。
struct FlippedUpsideDown: ViewModifier {
    func body(content: Content) -> some View {
        content
            .rotationEffect(.radians(.pi))
            .scaleEffect(x: -1, y: 1, anchor: .center)
    }
}
extension View {
    func flippedUpsideDown() -> some View { modifier(FlippedUpsideDown()) }
}

final class ChatScrollHost {
    weak var scrollView: UIScrollView? {
        didSet {
            // 反转后「点状态栏回顶」会滚到视觉底（offset 0），关掉
            scrollView?.scrollsToTop = false
            // [反转列表] 兔兔 09-13 B 包：「上滚时底部一条白横条消不掉」——系统还是往 UIScrollView 塞了
            // 一截自动 inset，落在物理顶=视觉底。反转后所有留白都由 contentMargins 显式给
            // （视觉顶 50+状态栏，视觉底 6），系统那套一律不要
            scrollView?.contentInsetAdjustmentBehavior = .never
            if let sv = scrollView {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let i = sv.adjustedContentInset
                    BreadcrumbLog.shared.add("📐", "列表 inset top=\(Int(i.top)) bottom=\(Int(i.bottom)) offset=\(Int(sv.contentOffset.y)) h=\(Int(sv.bounds.height))")
                }
            }
            // [armed-pin] 武装期内 contentSize 一变（新气泡量出真高）就同步钉底——KVO 在 setter 里
            // 同步回调，赶在这一帧提交之前，不等定时器
            // [hold-reading] 她在上面读历史时，物理顶（视觉底）来了新内容/他在吐字 → 内容整体被推 Δ，
            // 视口会跟着滑到新内容上（兔兔 09-13 B 包 #6「会拽回底部」）。补偿：contentSize 长 Δ 就把
            // offset 也加 Δ，她眼前的字纹丝不动。只在 hold 期内、且她不在底时补（粟粟 StreamFollowController
            // 的简版：不逐 cell 报高，按总高差补）
            sizeObs = scrollView?.observe(\.contentSize, options: [.old, .new]) { [weak self] sv, change in
                guard let self else { return }
                if CACurrentMediaTime() < self.holdUntil,
                   let o = change.oldValue?.height, let n = change.newValue?.height, abs(n - o) > 0.5 {
                    // 逐帧补：总高变 Δ，offset 跟着变 Δ（含入场动画期间的逐帧增长）
                    sv.contentOffset.y += (n - o)
                    return
                }
                self.pinIfArmed()
            }
        }
    }
    private var sizeObs: NSKeyValueObservation?
    private var armedUntil: CFTimeInterval = 0
    private var holdUntil: CFTimeInterval = 0
    private var holdBaseOffset: CGFloat = 0
    private var holdBaseHeight: CGFloat = 0
    /// [hold-reading] 上滑读历史时来了新内容 / 他在吐字：接下来一小段时间内的内容增长都补偿掉。
    /// round 3：记基线（offset / contentSize），KVO 逐帧补之外再在 0 / 0.1 / 0.35s 事后校准一次——
    /// 目标位置 = 基线 offset + (当前总高 − 基线总高)。不管 SwiftUI 中间怎么动，最后一定停在她原来看的那行。
    func holdReading(for seconds: CFTimeInterval = 0.8) {
        guard let sv = scrollView else { return }
        let fresh = CACurrentMediaTime() >= holdUntil
        holdUntil = CACurrentMediaTime() + seconds
        if fresh {
            holdBaseOffset = sv.contentOffset.y
            holdBaseHeight = sv.contentSize.height
        }
        for d in [0.0, 0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.settleHold() }
        }
    }
    private func settleHold() {
        guard let sv = scrollView, !sv.isTracking, !sv.isDragging else { return }
        let target = holdBaseOffset + (sv.contentSize.height - holdBaseHeight)
        if abs(sv.contentOffset.y - target) > 1 {
            BreadcrumbLog.shared.add("🧭", "读历史校准 offset \(Int(sv.contentOffset.y))→\(Int(target))（总高 \(Int(holdBaseHeight))→\(Int(sv.contentSize.height))）")
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: false)
        }
    }

    /// [armed-pin] 发送那一刻武装 0.6s：期间滚动几何一变就钉底。
    /// 兔兔 09-12 真机（A 刀后）：「发长消息的一瞬间闪一下白」——长消息时输入框长到五六行，
    /// 发送瞬间缩回一行，底 inset 突然少一百多 pt，offset 还停在旧底，多出来的那截没画=白帧，
    /// 而回底挂在 0.1s 后的定时器上，中间那几帧就是她看到的闪。短消息输入框不缩所以没事。
    func arm(for seconds: CFTimeInterval = 0.6) {
        armedUntil = CACurrentMediaTime() + seconds
        pinToBottom()                                   // 当下按旧几何先钉一次
        DispatchQueue.main.async { [weak self] in self?.pinToBottom() }   // 下一圈 runloop（inset 已落）再钉
    }
    func pinIfArmed() {
        guard CACurrentMediaTime() < armedUntil else { return }
        pinToBottom()
    }

    /// [反转列表] 视觉底 = 物理顶 = offset 原点（−顶 inset）。不再和 contentSize 打交道。
    /// 同一位置不重写（避免和手指/惯性打架）；手指按着/拖着时不写，不抢她的手。
    func pinToBottom() {
        guard let sv = scrollView, !sv.isTracking, !sv.isDragging else { return }
        let y = -sv.adjustedContentInset.top
        if abs(sv.contentOffset.y - y) < 0.5 { return }
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
    }

    /// 键盘当前盖住列表的高度（去掉 home 条那段，它本来就在 adjustedContentInset 里）
    private var keyboardOverlap: CGFloat = 0

    /// [keyboard-ride] 让内容和键盘同一条曲线一起走。
    /// 兔兔 09-12 真机：「键盘先升上去，聊天界面才把最后一条露出来」——之前是等 keyboardDidShow
    /// 再 +0.05s 一把写到底，内容永远落后键盘一整个动画。粟粟同款：读通知里的终态 frame /
    /// 时长 / 曲线，用 UIView.animate 按同一曲线推 contentOffset，两者同帧同速。
    /// show / hide / 键盘换高（emoji 键盘）都走这一个口，按 overlap 差值推，不重复。
    func rideWithKeyboard(_ note: Notification, follow: Bool) {
        guard let sv = scrollView, let window = sv.window,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let endInWindow = window.convert(end, from: nil)
        let overlap = max(0, window.bounds.maxY - endInWindow.minY - window.safeAreaInsets.bottom)
        let delta = overlap - keyboardOverlap
        keyboardOverlap = overlap
        guard follow, abs(delta) > 0.5 else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        let target = CGPoint(x: sv.contentOffset.x, y: sv.contentOffset.y + delta)
        UIView.animate(withDuration: duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            sv.contentOffset = target
        }
    }
}

/// 挂在 ScrollView 内容里，顺 superview 链爬到宿主 UIScrollView 交给 host。
struct ChatScrollViewFinder: UIViewRepresentable {
    let host: ChatScrollHost
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async { [weak v] in
            var node: UIView? = v?.superview
            while let cur = node {
                if let sv = cur as? UIScrollView { host.scrollView = sv; break }
                node = cur.superview
            }
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if host.scrollView == nil {
            var node: UIView? = uiView.superview
            while let cur = node {
                if let sv = cur as? UIScrollView { host.scrollView = sv; break }
                node = cur.superview
            }
        }
    }
}

struct CardFlowView: View {
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(\.scenePhase) private var scenePhase
    // globalWBManager 通过 ContentView 同步到 viewModel.globalWorldBookEntries
    /// 气泡模式：在此读、传给 BubbleView 并参与其 ==，否则 Equatable 会挡住重绘
    @AppStorage("chatBubbleMode") private var chatBubbleMode = false
    @AppStorage("blurRadius") private var blurRadius = 1.3
    @AppStorage("bubbleSpacing") private var bubbleSpacing: Double = 31
    @State private var showInConvSearch = false
    @FocusState private var inConvSearchFocused: Bool
    @State private var showStickerPanel = false
    @State private var showAddToChat = false
    @State private var showFilePicker = false
    @State private var fileErrorMessage: String?
    @State private var pendingImageData: Data?
    @State private var pendingFileData: Data?
    @State private var pendingFileName: String?
    /// 多附件（09-12）：一次多张图 / 多文件。旧的三个单件绑定留给粘贴/拖入等旧路径
    @State private var pendingAttachments: [PendingChatAttachment] = []
    /// 附件条当前属于哪条对话（09-13：切大对话时 isCurrentConvLoading 分支把 onChange 挤出树，
    /// 换对话事件漏掉，附件跟着聊天框走到别的对话——兔兔真机 #12。onAppear 再核对一次）
    @State private var attachmentsConvId: String? = nil
    // iOS 下 PinBar 已挪到 ContentView.iOSChatTopBar，state 同步搬走。
    // macOS 下 PinBar 仍作为 VStack 子项留在 CardFlowView，保留这两个 state。
    @State private var isAtBottom: Bool = true
    @State private var scrollHost = ChatScrollHost()   // [white-screen-fix A 刀] 回底唯一写手
    /// [B·砖3] Telegram 式长按浮层：environment 给树内 marker 递 model；浮层本体由 Presenter 挂 window 层
    @StateObject private var bubbleMenuModel = BubbleMenuOverlayModel()
    /// 键盘弹出瞬间视口缩小会把 isAtBottom 打成 false——willShow 时抓快照，didShow 后按它回底。
    @State private var wasAtBottomBeforeKeyboard: Bool = true
    /// [B·round4 遮挡关系] 底部安全区内容（输入条 / 贴纸面板占位 / 编辑工具栏占位）的实际高度。
    /// 列表 frame 现在伸到屏幕底，用它当物理顶 contentMargin：最新消息停在输入条上方，更早的
    /// 内容滚过输入条底下的毛玻璃渐变——兔兔 09-15：「要粟粟那种没有白横条、精致的遮挡关系」
    @State private var bottomBarHeight: CGFloat = 0
    @State private var keyboardUp: Bool = false
    /// [短对话顶对齐] 消息列表实测高度；不满一屏时物理顶（视觉底）塞一块 viewport − 内容 的垫块，
    /// 让第一条回到最顶上往下长（.frame(minHeight:alignment:.bottom) 那招在翻转 ScrollView 里不生效，09-15 实测）
    /// round 9：存「垫块高」而不是「列表高」——长对话里列表高每 mount 一条就变一次，存它会让
    /// 整个聊天页每次上滑都重算一遍（兔兔 09-15：「百多条从下往上滑很卡、页面变重」——这一半是它）。
    /// 存垫块：满一屏后恒为 0，不再触发重算。
    @State private var shortConvPad: CGFloat = 0
    @State private var textSelectItem: TextSelectItem?

    @ViewBuilder
    private func makeBubbleView(for node: MessageNode) -> some View {
        let info = viewModel.branchInfoMap[node.id]
        // API 车道用 streamingNodeId，CC 车道用 ccTurnNodeId（CC 豁免后不再占 API 车道状态）
        let isNodeCCWaiting = viewModel.ccTurnNodeId == node.id
        // turn 级判定（不是 provider 级 isStreaming）：工具执行的空窗期 provider
        // isStreaming 短暂为 false，若在此判定，流式文本/思考链会闪没
        //（真机 bug："回复消失，搜索完又出现"）。assistantTurnInFlight 盖住整个
        // 工具循环；OR provider 级作为群聊发言等非 turn 路径的兜底。
        let isNodeAPIStreaming = (viewModel.assistantTurnInFlight || viewModel.providerRouter.isStreaming)
            && viewModel.streamingNodeId == node.id
        let isNodeStreaming = isNodeAPIStreaming || isNodeCCWaiting
        let isNodeHighlighted = viewModel.highlightedNodeId == node.id
        let isNodeSearchMatch = viewModel.inConvMatches.contains(node.id)
        // 思考链/流式文本只传给 API 车道的流式节点——CC 等待期间这些全局值
        // 可能属于并行的 API 对话，传给 CC 气泡会显示别人的文本
        let isThinkingNow = isNodeAPIStreaming && viewModel.isThinking
        let streamingThinkingForNode = isNodeAPIStreaming ? viewModel.streamingThinkingText : ""
        let thinkingSummaryForNode = isNodeAPIStreaming ? viewModel.thinkingSummary : ""
        BubbleView(
            chatBubbleMode: chatBubbleMode,
            node: node,
            hasBranches: info != nil,
            branchInfo: info,
            isStreaming: isNodeStreaming,
            streamingContentText: isNodeAPIStreaming ? viewModel.streamingText : "",
            isThinking: isThinkingNow,
            streamingThinkingText: streamingThinkingForNode,
            thinkingSummary: thinkingSummaryForNode,
            isHighlighted: isNodeHighlighted,
            isSearchMatch: isNodeSearchMatch,
            isLastAssistant: node.role == "assistant" && node.id == viewModel.currentPath.last?.id,
            onNotice: { viewModel.transientNotice = TransientNotice($0) },
            onToggleFavorite: { viewModel.toggleFavorite(node) },
            onTogglePin: { viewModel.togglePin(node) },
            onSoftDelete: { viewModel.softDelete(node) },
            onSwitchBranch: { nodeId, idx in viewModel.switchBranch(at: nodeId, to: idx) },
            onRegenerate: makeRegenerateAction(for: node),
            onEdit: makeEditAction(for: node),
            groupMembers: {
                guard let conv = viewModel.selectedConversation, conv.kind == "group" else { return [] }
                return conv.participants.map { (id: $0.id, name: $0.name) }
            }(),
            onGroupReply: { [weak viewModel] pid in
                guard let viewModel, let pm = providerManager else { return }
                viewModel.groupRequestReply(participantId: pid, providerManager: pm, context: modelContext)
            },
            regexScripts: {
                let profileScripts = profileManager?.currentProfile.regexScripts ?? []
                let presetId = profileManager?.currentProfile.presetId ?? ""
                let presetScripts = presetManager?.preset(byId: presetId)?.regexScripts ?? []
                return presetScripts + profileScripts
            }()
        )
        // B3 性能：流式期间 CardFlowView.body 每 token 重算 → makeBubbleView 对**所有**节点
        // 重建 BubbleView（含闭包，SwiftUI 视为输入变化）→ 每条气泡 body 重跑 ContentCleaner /
        // extractThinking / ArtifactDetector / Markdown 解析。对话越长越卡。.equatable() 拦下
        // "父重建但语义未变"的非流式气泡，只有真正变化的节点（流式那条 / 内容改动）才重渲染。
        .equatable()
    }

    private func makeRegenerateAction(for node: MessageNode) -> (() -> Void)? {
        guard node.role == "assistant", let pm = providerManager else { return nil }
        return {
            guard let prof = self.profileManager?.currentProfile else { return }
            let preset = self.presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
            let modelId = UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""
            let model = pm.model(byId: modelId) ?? pm.availableModels.first ?? ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4")
            self.viewModel.regenerate(assistantNodeId: node.id, model: model, profile: prof, preset: preset, providerManager: pm, context: self.modelContext)
        }
    }

    private func makeEditAction(for node: MessageNode) -> ((String) -> Void)? {
        guard node.role == "user", let pm = providerManager else { return nil }
        return { newText in
            guard let prof = self.profileManager?.currentProfile else { return }
            let preset = self.presetManager?.preset(byId: prof.presetId) ?? Preset.balanced
            let modelId = UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""
            let model = pm.model(byId: modelId) ?? pm.availableModels.first ?? ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4")
            self.viewModel.editAndResend(node.id, newText: newText, model: model, profile: prof, preset: preset, providerManager: pm, context: self.modelContext)
        }
    }

    // Pin Bar handlers：iOS 版已挪到 ContentView；macOS 版保留（PinBar 仍在 CardFlowView）

    /// [white-screen-fix A 刀] 回底：UIKit 直写 offset，不再 `proxy.scrollTo`。
    /// 旧「三步走」（scrollTo(lastId) → 50ms 哨兵 → 500ms 哨兵）每一步都逼 LazyVStack
    /// 从头 mount 到目标 = 白屏本体（粟粟探针，见 ChatScrollHost 注释）。
    /// 现在：写一次 offset；懒加载在落点 mount 出真实高度后 contentSize 会变，
    /// 再复核三次（只写 offset，零 mount 风暴）。找不到 UIScrollView（理论上不会）才退回
    /// 单步禁动画 scrollTo 哨兵。
    /// [round 10] 预热渲染窗口之外、紧挨着的下一批（renderStart 往前 step 条）的 Markdown 解析
    private func prewarmMarkdown(before start: Int) {
        let path = viewModel.currentPath
        let lo = max(0, start - ConversationViewModel.renderWindowStep)
        guard lo < start, start <= path.count else { return }
        let items: [(nodeId: String, text: String)] = path[lo..<start].compactMap { n in
            guard n.role == "assistant" || n.role == "user", !n.content.isEmpty, n.contentType != "multimodal_text" else { return nil }
            let cleaned = ContentCleaner.clean(n.content, cacheKey: "\(n.id)_\(n.content.count)")
            let body = n.role == "assistant" ? (ContentCleaner.extractThinking(from: cleaned).content) : cleaned
            return (n.id, n.role == "user" ? body : BubbleMarkdownSimplifier.simplify(body))
        }
        MarkdownParseCache.prewarm(items)
    }

    /// 列表往输入条底下多伸多少：输入条本身的高度（含 home 条那截由安全区自己管），封顶 96
    private var barOverlap: CGFloat { min(max(bottomBarHeight, 0), 96) }
    /// 视觉顶留白：状态栏 + nav 按钮区（GeometryReader 忽略了顶部安全区，读不到时按 59 兜底）
    private var topReserve: CGFloat {
        let top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 59
        return 50 + max(top, 44)
    }

    /// 附件条随对话走：存到旧对话名下，取回新对话名下
    private func swapAttachments(from oldId: String?, to newId: String?) {
        if let oldId, oldId != newId { viewModel.draftAttachments[oldId] = pendingAttachments }
        pendingAttachments = newId.flatMap { viewModel.draftAttachments[$0] } ?? []
        attachmentsConvId = newId
    }

    /// force=false（默认）：只在用户已经在底部时才滚，避免流式时弹跳
    /// force=true：强制滚底（切换对话、消息完成、发送、用户点回底按钮）
    private func scrollToLastMessage(proxy: ScrollViewProxy, force: Bool = false) {
        guard force || isAtBottom else { return }
        guard !viewModel.currentPath.isEmpty else { return }
        guard scrollHost.scrollView != nil else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { proxy.scrollTo("__bottom_sentinel__", anchor: .top) }   // 反转：哨兵在物理顶
            return
        }
        scrollHost.pinToBottom()
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scrollHost.pinToBottom() }
        }
    }

    var body: some View {
        if viewModel.isCurrentConvLoading {
            VStack {
                Spacer()
                ProgressView("加载中...")
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // iOS 下路线 C chat page 有 wallpaper，loading 区透明让 wallpaper 可见
        } else {
            VStack(spacing: 0) {
                // In-conversation search bar
                if showInConvSearch {
                    InConversationSearchBar(
                        viewModel: viewModel,
                        focused: $inConvSearchFocused,
                        onDismiss: {
                            showInConvSearch = false
                            viewModel.clearInConvSearch()
                        }
                    )
                }

                ScrollViewReader { proxy in
                    // [反转列表] GeometryReader 是「安全区容器」：它不忽略底部安全区（输入条 + 键盘），
                    // 所以里面的 ScrollView 的 frame 本身停在输入条之上、底部零 inset——反转后
                    // 才不会把 inset 落到错边；它只忽略顶部安全区，好让内容照旧伸到状态栏下，
                    // 并把状态栏高度读出来补进视觉顶留白。
                    GeometryReader { geo in
                    ScrollView {
                        // 方案 2 v2：恢复 ZStack sibling 结构（之前 .overlay() 把 sticker overlay
                        // frame 锁定到 LazyVStack 大小，sticker 拖到 LazyVStack 之外就接不到 touch）。
                        // StickerCanvasLayer 自己声明 minHeight = max sticker maxY + buffer，让
                        // ZStack 自然 layout 时 height = max(LazyVStack.h, sticker overlay 声明 h)，
                        // 保证 overlay 永远覆盖所有 sticker 实际位置。
                        // 详见 docs/plan-sticker-pan-relationship-fix-2026-04-25.md 方案 2 v2。
                        ZStack(alignment: .topLeading) {
                          VStack(spacing: 0) {
                            // [短对话顶对齐] 物理顶垫块：不满一屏时把消息推到物理底=视觉顶。
                            // 视觉顶的 nav 留白已经算进列表高（见下方 padding(.bottom)），这里只扣输入条那截
                            Color.clear.frame(height: shortConvPad)
                            LazyVStack(spacing: bubbleSpacing) {
                                // [反转列表] 物理顺序 = 视觉倒序：这里第一项是视觉底。
                                // 哨兵留在物理顶，proxy 回落路径用 scrollTo(anchor: .top)
                                Color.clear
                                    .frame(height: 1)
                                    .id("__bottom_sentinel__")
                                // 群聊：谁没说上话（V6 刀2.5，失败凭证可见化 + 重试）——视觉底
                                if let conv = viewModel.selectedConversation, conv.kind == "group" {
                                    GroupClaimStatusRow(conversationId: conv.id) { pid in
                                        guard let pm = providerManager else { return }
                                        viewModel.groupRequestReply(participantId: pid,
                                                                    providerManager: pm,
                                                                    context: modelContext)
                                    }
                                    .flippedUpsideDown()
                                }
                                ForEach(viewModel.visiblePath.reversed(), id: \.id) { node in
                                    makeBubbleView(for: node)
                                        .flippedUpsideDown()   // cell 翻回正
                                        .id(node.id)
                                        // 新消息插在物理顶：从物理顶滑入 = 视觉底滑入
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                        // 贴纸定位追踪：每条气泡记录 midY。旧版用 .task(id: midY)——
                                        // 滚动时每帧每条可见气泡 cancel+新建一个 async Task，是滚动卡顿
                                        // 大户。改 iOS 18 原生 onGeometryChange：同步闭包、值变才回调、
                                        // 零 Task 分配。bubblePositions 是 @ObservationIgnored，写它不触发重绘。
                                        .background(
                                            Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                                                proxy.frame(in: .named("scrollContent")).midY
                                            } action: { midY in
                                                stickerVM.bubblePositions[node.id] = midY
                                            }
                                        )
                                }
                                // 只渲染尾部窗口，滑到（视觉）顶自动往前扩一段——物理末尾 = 视觉顶
                                if viewModel.hasMoreAbove {
                                    Button {
                                        withAnimation(.none) { viewModel.expandRenderWindow() }
                                    } label: {
                                        Text("看更早的消息")
                                            .font(.system(size: Theme.F.caption))
                                            .foregroundColor(Theme.textMuted)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .flippedUpsideDown()
                                    .onAppear {
                                        // 滑到顶就自动扩，不用真去点；并把再下一批提前解析好（round 10）
                                        viewModel.expandRenderWindow()
                                        prewarmMarkdown(before: viewModel.renderStart)
                                    }
                                }
                            }
                            // 新消息入场动画：路径长度变化时触发 ForEach item transition
                            .animation(isAtBottom ? .easeOut(duration: 0.2) : nil, value: viewModel.currentPath.count)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)      // 物理顶=视觉底：贴着输入条（B round 3）
                            // 物理底=视觉顶：nav 区留白放进内容里（round 8）。之前放在 contentMargins(.bottom)，
                            // 那只是 UIScrollView 的 inset——内容不满一屏时根本推不动，第一条顶到 nav 按钮底下
                            // （兔兔 09-15 截图）。放进 padding 后短对话/长对话都是同一段留白。
                            .padding(.bottom, 16 + topReserve)
                            .frame(maxWidth: .infinity)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                                let pad = max(0, geo.size.height - (barOverlap + 4) - h)
                                if abs(pad - shortConvPad) > 0.5 { shortConvPad = pad }   // 长对话恒 0，不重算
                            }
                          }   // VStack（垫块 + 列表）

                            StickerCanvasLayer(
                                stickerVM: stickerVM,
                                profileId: profileManager?.currentProfile.id ?? ""
                            )
                            // [反转列表] 画布**不**整体翻（会让坐标系和 bubblePositions 反），
                            // 每张贴纸在层内自己翻回正（粟粟 764c79e3 的修正）
                        }
                        .coordinateSpace(name: "scrollContent")
                        .background(ChatScrollViewFinder(host: scrollHost))   // [white-screen-fix A 刀] 爬到宿主 UIScrollView
                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers, location in
                            handleStickerDrop(providers: providers, location: location)
                        }
                    }
                    // [反转列表] 整个 ScrollView 翻转；offset 0 = 最新。defaultScrollAnchor 不再需要。
                    .flippedUpsideDown()
                    .clipped()
                    // 视觉顶 nav 区留白改进内容 padding（见 LazyVStack），这里不再给 bottom margin
                    // 物理顶=视觉底：让出往输入条底下伸的那截 + 一点呼吸
                    .contentMargins(.top, barOverlap + 4, for: .scrollContent)
                    // 反转后 safe area 的 bottom inset 会落到物理底=视觉顶（错边）。让 ScrollView
                    // 的 frame 本身停在输入条/键盘之上（见下方 GeometryReader 容器），底部零 inset；
                    // 键盘弹起容器变矮，offset 0 的最新消息跟着上去。顶部照旧伸到状态栏下。
                    .ignoresSafeArea(.container, edges: .top)
                    // 路线 C + PinBar 挪位后：PinBar 已进 ContentView.iOSChatTopBar HStack。
                    // 这里只剩 blur + gradient 130pt 的视觉柔化层（z 层：blur < nav HStack）。
                    .overlay(alignment: .top) {
                        ZStack {
                            VariableBlurView(maxBlurRadius: blurRadius, direction: .blurredTopClearBottom)
                            LinearGradient(
                                stops: [
                                    .init(color: Theme.mainBg, location: 0.0),
                                    .init(color: Theme.mainBg.opacity(0.7), location: 0.15),
                                    .init(color: Theme.mainBg.opacity(0.5), location: 0.28),
                                    .init(color: Theme.mainBg.opacity(0.3), location: 0.45),
                                    .init(color: Theme.mainBg.opacity(0.1), location: 0.75),
                                    .init(color: Theme.mainBg.opacity(0), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .frame(height: 130)
                        .ignoresSafeArea(.all, edges: .top)
                        .allowsHitTesting(false)
                    }

                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        // [反转列表] 视觉底 = offset 原点；离原点 200pt 内算在底
                        geometry.contentOffset.y + geometry.contentInsets.top < 200
                    } action: { _, atBottom in
                        isAtBottom = atBottom
                        // round 9：回到底就把渲染窗口收回初始大小——上滑时挂上的几百条气泡全部卸掉，
                        // 页面重新变轻（左右滑分页也跟着轻）。她在底，收的是物理远端，视口不动。
                        if atBottom, viewModel.renderStart < max(0, viewModel.currentPath.count - 2 * ConversationViewModel.initialRenderWindow) {
                            withAnimation(.none) { viewModel.resetRenderWindow() }
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        // [armed-pin] 底 inset（输入框缩回）或内容高度一变 → 武装期内同步钉底
                        geometry.contentInsets.bottom + geometry.contentSize.height
                    } action: { _, _ in
                        scrollHost.pinIfArmed()
                    }
                    .onAppear {
                        // [white-screen-fix] 首次/视图重建进入：defaultScrollAnchor 对含 WebView 的
                        // 动态高度气泡锚不准 → 白屏（需手动下滑才显示）。显式滚底兜底，延迟等 layout 落定。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToLastMessage(proxy: proxy, force: true)
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        // [white-screen-fix] App 回前台会重布局、易白屏，而 isCurrentConvLoading 不变化
                        // 触发不到下面那条兜底 → 这里补一刀。
                        if phase == .active {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToLastMessage(proxy: proxy, force: true)
                            }
                        }
                    }
                    // [white-screen-fix] 键盘：弹出/收起改的是 safe-area inset（视口），
                    // defaultScrollAnchor(.sizeChanges) 只认 content size 不认视口变化 →
                    // 打字时原本贴底的内容被键盘顶乱（真机 bug："打着字白屏，要手动下滑找"）。
                    // 在底才滚，不打扰上滑读历史。
                    .onReceive(NotificationCenter.default.publisher(for: ChatScrollBench.startNotification)) { note in
                        // 深翻基准：开发调试页按一下，回到这条对话的底部后自动开滚
                        guard let sv = scrollHost.scrollView else { return }
                        let speed = (note.userInfo?["speed"] as? Double) ?? 3000
                        scrollHost.pinToBottom()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            FrameHitchProbe.mark("深翻基准")
                            ChatScrollBench.shared.start(on: sv, speed: speed)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                        // [keyboard-ride] 在底才跟：内容和键盘同曲线一起升；上滑读历史的不动
                        wasAtBottomBeforeKeyboard = isAtBottom
                        keyboardUp = true
                        FrameHitchProbe.mark("键盘弹起")
                        // [反转列表] 键盘避让由容器变矮完成（offset 0 跟着上去），不再推 offset
                        _ = note
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        keyboardUp = false
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                        // 动画结束后校一次（ride 落准了就是 no-op，差 0.5pt 内不写）
                        if wasAtBottomBeforeKeyboard {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollToLastMessage(proxy: proxy, force: true)
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                        if isAtBottom || wasAtBottomBeforeKeyboard {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollToLastMessage(proxy: proxy, force: true)
                            }
                        }
                    }
                    .onChange(of: viewModel.isCurrentConvLoading) { _, loading in
                        // 对话加载完成 → 滚到最后一条（applyTreeData 只在搜索跳转时设 scrollToNodeId，
                        // 普通切对话不会自动滚，ScrollView 保留上一对话的 offset，所以要在这里兜底）
                        if !loading, !viewModel.currentPath.isEmpty {
                            FrameHitchProbe.mark("打开对话(\(viewModel.currentPath.count)条)")
                            prewarmMarkdown(before: viewModel.renderStart)   // round 10：下一批先解析好
                            // B20 修复：先把 currentPathCount 同步给 stickerVM，再 migrate 飞远的贴纸
                            stickerVM.currentPathCount = viewModel.currentPath.count
                            stickerVM.migrateStickerPositions(context: modelContext)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollToLastMessage(proxy: proxy, force: true)
                            }
                        }
                    }
                    .onChange(of: viewModel.currentPath.count) { old, n in
                        // B20 修复：path 变（新消息进来等）→ 同步给 stickerVM，让 clampStickerY
                        // 在 drag end 时拿到最新 path 长度
                        stickerVM.currentPathCount = n
                        // [white-screen-fix] 发送：进页面/回前台/键盘起落四个时机都有「等布局落定再
                        // 强制回底」的兜底，唯独发送没有——一次塞两条（她的话 + 空占位泡）还带 0.2s
                        // 入场动画，只靠 defaultScrollAnchor 钉底会飞，露出没画的区域（兔兔 09-02：
                        // 「发完整页空白，往下划一下才回来」，两条车道都会）。刚发的（尾部两条里有
                        // user）无条件回底；别人的消息进来（CC 主动说话）只在她本来就在底时回底。
                        guard n > old else { return }
                        let justSent = viewModel.currentPath.suffix(n - old).contains { $0.role == "user" }
                        if !justSent && !isAtBottom {
                            scrollHost.holdReading()   // [hold-reading] 她在读历史，新消息别把她拽下去
                            return
                        }
                        guard justSent || isAtBottom else { return }
                        scrollHost.arm()   // [armed-pin] 当下 + 下一圈 + 几何一变都钉，不留白帧
                        FrameHitchProbe.mark(justSent ? "发送" : "收到消息")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToLastMessage(proxy: proxy, force: true)
                        }
                    }
                    .onChange(of: viewModel.ccTurnNodeId) { old, new in
                        // [white-screen-fix] CC 车道不流式：他的回复一次性落进空占位泡，高度从 0
                        // 跳到整条——API 车道有 streamingText 收尾回底，CC 这边没有对应出口。
                        // turn 结束（ccTurnNodeId → nil）且她在底 → 同款兜底。
                        if old != nil, new == nil, isAtBottom {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToLastMessage(proxy: proxy, force: true)
                            }
                        } else if old != nil, new == nil {
                            scrollHost.holdReading()   // [hold-reading] CC 回复落进空泡，她在上面读，别拽
                        }
                    }
                    .onChange(of: viewModel.scrollToNodeId) { _, nodeId in
                        if let nodeId {
                            // 回复完成时 vm 会把 scrollToNodeId 设成新回复——她在上面读历史就别拽
                            // （兔兔 09-15：「回复的话还是会被拉到最底下」——真凶在这，不是补偿）。
                            // 搜索跳转的目标不是最后一条，不受影响
                            if nodeId == viewModel.currentPath.last?.id, !isAtBottom {
                                viewModel.scrollToNodeId = nil
                                scrollHost.holdReading()
                                return
                            }
                            // 先无动画跳（让 LazyVStack 加载目标），再动画微调
                            proxy.scrollTo(nodeId, anchor: .center)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(nodeId, anchor: .center)
                                }
                                viewModel.scrollToNodeId = nil
                            }
                        }
                    }
                    .onChange(of: viewModel.streamingText) { oldText, newText in
                        // [hold-reading] 她在读历史时他在吐字：每次文字变化都续一段补偿期
                        if !isAtBottom { scrollHost.holdReading(); if !newText.isEmpty { return } }
                        // 流式结束 → 回底（只在她本来就在底时；反转后在底吐字本就钉底，这是校准）
                        if newText.isEmpty && !oldText.isEmpty, isAtBottom {
                            scrollToLastMessage(proxy: proxy, force: true)
                        }
                        // [scroll-anchor] 流式期间不再逐 token scrollTo——
                        // defaultScrollAnchor(.bottom) 在用户位于底部时自动钉底，
                        // 上滑读历史时自动不打扰。旧的 0.3s 节流 scrollTo 风暴
                        //（长对话卡顿源之一 + 与 WebView 高度变化竞争白屏源）整体移除。
                    }
                    // 编辑贴纸时锁住纵向滚动，否则纵向 pinch 被 ScrollView 吃掉
                    .scrollDisabled(stickerVM.isEditingStickers)
                    .scrollDismissesKeyboard(.immediately)
                    }   // GeometryReader（安全区容器）
                    // round 6：不能忽略底部安全区——这台 App 的键盘避让是 PagingViewController 往 chat HC 的
                    // additionalSafeAreaInsets 注入的（走的是 container 不是 .keyboard），round 4 一忽略，
                    // 键盘一起被忽略 → 「键盘和输入框水平往上提，把最后一条盖住」。而且 UIHostingController
                    // 里 ignoresSafeArea 会让内部 UIView 溢出 hc.view.bounds（粟粟 gotcha 04-20）——她那边
                    // 短对话里那根多出来的黑条多半也是这个溢出。
                    // 遮挡关系改用负 padding：frame 照旧停在安全区（键盘一来就变矮），只往输入条底下多伸
                    // barOverlap 那么多，内容滚过输入条的毛玻璃；最新一条靠 contentMargins 停在输入条上方。
                    .ignoresSafeArea(.container, edges: .top)
                    .padding(.bottom, -barOverlap)
                    .overlay(alignment: .bottomTrailing) {
                        // 回底按钮浮在列表上，不占 safe area（见上）
                        if !isAtBottom && !viewModel.currentPath.isEmpty {
                            ScrollToBottomButton(
                                isVisible: true,
                                action: { scrollToLastMessage(proxy: proxy, force: true) }
                            )
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .environment(\.bubbleMenuOverlayModel, bubbleMenuModel)   // [B·砖3] 树内 marker 拿 model
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Group {
                        if showStickerPanel {
                            // 透明占位：把滚动内容推上去，真正的面板在外层 overlay
                            Color.clear.frame(height: 320)
                        } else if stickerVM.isEditingStickers {
                            // 编辑模式：工具栏在 overlay，这里只占位
                            Color.clear.frame(height: 60)
                        } else if let pm = providerManager {
                            VStack(spacing: 0) {
                                // 回底按钮已挪到 ScrollView 的 overlay（B round 3）：它在 safeAreaInset 里会把
                                // 列表 frame 抬高 54pt——反转列表下 frame 是硬边，那 54pt 就是兔兔看到的
                                // 「上滚时底部消不掉的白横条」（正序时内容可以滚进 inset 区，看不出来）
                                ChatInputBar(
                                    viewModel: viewModel, modelContext: modelContext,
                                    profileManager: profileManager, providerManager: pm, presetManager: presetManager,
                                    pendingImageData: $pendingImageData,
                                    pendingFileData: $pendingFileData,
                                    pendingFileName: $pendingFileName,
                                    pendingAttachments: $pendingAttachments,
                                    onStickerTap: {
                                        // + 号 → Add to Chat 功能面板（iOS）
                                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                        showAddToChat = true
                                    }
                                )
                                .equatable()
                            }
                            .animation(.easeOut(duration: 0.25), value: isAtBottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        }   // Group
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomBarHeight = $0 }
                    }
                    .animation(.easeInOut(duration: 0.25), value: showStickerPanel)
                    .animation(.easeInOut(duration: 0.25), value: stickerVM.isEditingStickers)
                }

                // 底栏：编辑模式 = 工具栏，普通模式 = 输入框（仅 macOS，iOS 合并在 StickerKeyboardPanel）
            }
            .animation(.easeInOut(duration: 0.25), value: stickerVM.isEditingStickers)
            .overlay(alignment: .bottom) {
                if showStickerPanel || stickerVM.isEditingStickers {
                    StickerKeyboardPanel(
                        stickerVM: stickerVM,
                        viewModel: viewModel,
                        showCard: showStickerPanel,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if showStickerPanel {
                                    showStickerPanel = false
                                } else {
                                    // 只有工具栏时，键盘按钮 = 退出编辑
                                    stickerVM.isEditingStickers = false
                                    stickerVM.selectedPlacedStickerId = nil
                                }
                            }
                        },
                        onStickerTap: {
                            withAnimation(.easeInOut(duration: 0.25)) { showStickerPanel.toggle() }
                        }
                    )
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showStickerPanel)
            .animation(.easeInOut(duration: 0.25), value: stickerVM.isEditingStickers)
            .background {
                // Hidden button for Cmd+F shortcut
                Button("") {
                    showInConvSearch.toggle()
                    if showInConvSearch {
                        inConvSearchFocused = true
                    } else {
                        viewModel.clearInConvSearch()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            .onChange(of: viewModel.selectedConversation?.id) { oldId, convId in
                loadStickersForConversation(convId)
                isAtBottom = true   // 避免上一对话的 false 泄漏到新对话（会让 safeAreaInset 错位）
                // 清除上一对话残留的附件
                pendingFileData = nil
                pendingFileName = nil
                pendingImageData = nil
                // 多附件随对话暂存/取回（09-12）：切走时存起来，切回来时还在
                swapAttachments(from: oldId, to: convId)
            }
            .onAppear {
                loadStickersForConversation(viewModel.selectedConversation?.id)
                // 大对话切换走 loading 分支时上面的 onChange 不在树上，这里补核对
                let cid = viewModel.selectedConversation?.id
                if attachmentsConvId != cid { swapAttachments(from: attachmentsConvId, to: cid) }
                // 注入贴纸 mutation callback：加/删贴纸时推对话走 3s debounce 重排
                stickerVM.onConversationMutated = { [viewModel] convId in
                    if let conv = viewModel.selectedConversation, conv.id == convId {
                        conv.updateTime = Date()
                        viewModel.markConversationDirty()
                    }
                }
            }
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            .overlay(alignment: .top) {
                // B20 part 2: transient toast (e.g. "已切换到分支")
                if let notice = viewModel.transientNotice {
                    TransientNoticeCapsule(text: notice.text)
                        .id(notice.id)
                        .padding(.top, 16)
                        .onAppear {
                            let id = notice.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                if viewModel.transientNotice?.id == id {
                                    viewModel.transientNotice = nil
                                }
                            }
                        }
                }
            }
            // Add to Chat 功能面板（+ 号触发）
            // 从 Files App "用 Lost in Blossom 打开" 接收文件
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("incomingFileReceived"))) { notif in
                if let data = notif.userInfo?["data"] as? Data,
                   let name = notif.userInfo?["name"] as? String {
                    pendingFileData = data
                    pendingFileName = name
                }
            }
            // CC 选择卡：pendingCCQuestion 非 nil 时弹出。
            // 答完或关掉都会经 ConversationViewModel+AskUser 回帧，驱动 tmux 里的 TUI 键序。
            // 挂在 CardFlowView 而非 InputFieldContainer——后者没有 viewModel（08-31 编译错的原因）。
            // 弹出条件一比一照粟粟（CardFlowView:1280）：**只在这张卡所属的那个对话里弹**。
            // 我们原本写的是 activeAskQuestions != nil——不管兔兔在哪个对话都弹出来，
            // 卡是给 A 会话的、她正在看 B 会话，照样糊她一脸。
            .sheet(isPresented: Binding(
                get: {
                    let convId = viewModel.selectedConversation?.id
                    if let c = viewModel.pendingCCQuestion { return c.chatId == convId }
                    return false
                },
                set: { if !$0 { viewModel.dismissActiveAskCard() } }
            )) {
                AskUserQuestionSheet(viewModel: viewModel)
            }
            .onAppear {
            CCBridgeWebSocketClient.shared.onAskUserQuestion = { chatId, toolUseId, questions in
                viewModel.pendingCCQuestion = PendingCCQuestion(
                    chatId: chatId, toolUseId: toolUseId, questions: questions
                )
            }
            // V6：收尾上次被中断的群聊轮次（App 被杀/崩溃留下的 running 僵尸）
            ConversationViewModel.reconcileStaleGroupTurns(context: modelContext)
            // 冷场破冰：打开群聊时看一眼，安静太久就让人先开口
            if let pm = providerManager {
                viewModel.groupMaybeBreakIce(providerManager: pm, context: modelContext)
            }
            // 问问题收账（粟粟同款全签名）：关卡 + Q/A 气泡落对话
            CCBridgeWebSocketClient.shared.onAskUserResolved = { chatId, toolUseId, questions, answers in
                viewModel.handleCCAskUserResolved(chatId: chatId, toolUseId: toolUseId,
                                                  questions: questions, answers: answers, context: modelContext)
            }
            CCBridgeWebSocketClient.shared.onAskUserStale = { toolUseId in
                viewModel.handleCCAskUserStale(toolUseId: toolUseId)
            }
            // API 通路：ToolCallLoop 在 AskUserGate 挂起，题面从这儿进 sheet
            AskUserGate.shared.onQuestions = { questions in
                viewModel.pendingAPIQuestion = PendingAPIQuestion(questions: questions)
            }
            // T6 DJ：他放歌 → 解析直链→建 Song→开播（CloudMusicView.playRemote 同款，
            // 边听边存照旧）。装在 CardFlowView：主界面在，DJ 就在，不用先开音乐面板
            CCBridgeWebSocketClient.shared.onMusicCommand = { songId, title, artist in
                let pid = profileManager?.currentProfile.id ?? ""
                let ctx = modelContext
                Task {
                    guard let d = await MusicLibraryClient.detail(songId: songId), let url = d.url else { return }
                    await MainActor.run {
                        let song = Song(profileId: pid, title: title, artist: artist, album: "",
                                        source: url, isRemote: true, durationSec: 0, lyrics: d.lyric)
                        song.remoteId = songId
                        ctx.insert(song)
                        try? ctx.save()
                        if let remote = URL(string: url) { MusicCache.store(songId: songId, from: remote) }
                        MusicPlayer.shared.play(song: song, in: [song]) { s in
                            MusicCache.localURL(songId: s.remoteId) ?? URL(string: s.source)
                        }
                        HapticService.shared.longPress()
                    }
                }
            }
            }
            .sheet(isPresented: $showAddToChat) {
                AddToChatSheet(
                    onOpenSticker: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showStickerPanel = true
                            stickerVM.isEditingStickers = true
                        }
                    },

                    pendingImageData: $pendingImageData,
                    pendingFileData: $pendingFileData,
                    pendingFileName: $pendingFileName,
                    pendingAttachments: $pendingAttachments
                )
            }
            .alert("文件添加失败", isPresented: Binding(
                get: { fileErrorMessage != nil },
                set: { if !$0 { fileErrorMessage = nil } }
            )) {
                Button("好的") { fileErrorMessage = nil }
            } message: {
                Text(fileErrorMessage ?? "")
            }
            // 双击消息气泡 → 文本选取 sheet
            .sheet(item: $textSelectItem) { item in
                TextSelectSheet(text: item.text, thinkingText: item.thinkingText)
            }
        }
    }

    // MARK: - Sticker Helpers

    private func loadStickersForConversation(_ convId: String?) {
        stickerVM.bubblePositions.removeAll()
        guard let convId, let pid = profileManager?.currentProfile.id else {
            stickerVM.placedStickers = []
            return
        }
        stickerVM.loadPlacedStickers(conversationId: convId, profileId: pid, context: modelContext)
    }

    private func handleStickerDrop(providers: [NSItemProvider], location: CGPoint) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let assetId = UUID(uuidString: idString),
                  let convId = viewModel.selectedConversation?.id,
                  let pid = profileManager?.currentProfile.id else { return }

            let nearestId = findNearestMessageId(y: location.y)
            print("[贴纸定位] drop y=\(location.y), bubblePositions=\(stickerVM.bubblePositions.count)条, nearest=\(nearestId ?? "nil")")

            // 查 asset 类型——便签需要复制 noteContent/noteStyle
            let asset = stickerVM.stickerAssets.first(where: { $0.id == assetId })

            DispatchQueue.main.async {
                if let asset, asset.isNote {
                    stickerVM.placeNote(
                        content: asset.noteContent ?? "",
                        style: asset.noteStyle ?? "yellow_square",
                        conversationId: convId,
                        position: location,
                        nearestMessageId: nearestId,
                        profileId: pid,
                        context: modelContext
                    )
                } else {
                    stickerVM.placeSticker(
                        assetId: assetId,
                        conversationId: convId,
                        position: location,
                        nearestMessageId: nearestId,
                        profileId: pid,
                        context: modelContext
                    )
                }
            }
        }
        return true
    }

    /// 找 Y 坐标最近的消息 ID（用 GeometryReader 测量的真实位置）
    private func findNearestMessageId(y: CGFloat) -> String? {
        guard !stickerVM.bubblePositions.isEmpty else {
            // fallback：没有测量数据时用第一条消息
            return viewModel.currentPath.first?.id
        }
        var bestId: String?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (nodeId, centerY) in stickerVM.bubblePositions {
            let dist = abs(centerY - y)
            if dist < bestDist {
                bestDist = dist
                bestId = nodeId
            }
        }
        return bestId
    }
}

// MARK: - In-Conversation Search Bar

struct InConversationSearchBar: View {
    var viewModel: ConversationViewModel
    var focused: FocusState<Bool>.Binding
    var onDismiss: () -> Void
    @State private var keyword: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)

            TextField("搜索当前对话...", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .onSubmit {
                    viewModel.searchInConversation(keyword: keyword)
                }
                .onChange(of: keyword) { _, newValue in
                    if newValue.isEmpty {
                        viewModel.clearInConvSearch()
                    }
                }

            if !viewModel.inConvMatches.isEmpty {
                Text("\(viewModel.inConvMatchIndex + 1)/\(viewModel.inConvMatches.count)")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .monospacedDigit()

                Button(action: { viewModel.navigateInConvMatch(direction: -1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.navigateInConvMatch(direction: 1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            } else if !keyword.isEmpty && viewModel.inConvMatchIndex == -1 {
                Text("无结果")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.sidebarBg)
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    var viewModel: ConversationViewModel
    var modelContext: ModelContext
    var profileManager: ProfileManager?
    var providerManager: ProviderManager
    var presetManager: PresetManager?
    var pendingImageData: Binding<Data?> = .constant(nil)
    var pendingFileData: Binding<Data?> = .constant(nil)
    var pendingFileName: Binding<String?> = .constant(nil)
    var pendingAttachments: Binding<[PendingChatAttachment]> = .constant([])
    var onStickerTap: (() -> Void)? = nil

    @AppStorage("blurRadius") private var blurRadius = 1.3
    @AppStorage("selectedChatModel") private var selectedModelId = ""
    @State private var showModelPicker = false
    @State private var showCCDisconnectedAlert = false
    @FocusState private var isFocused: Bool

    private var currentModel: ProviderModel {
        // Try stored selection
        if !selectedModelId.isEmpty, let model = providerManager.model(byId: selectedModelId) {
            return model
        }
        // Fallback to first available model
        return providerManager.availableModels.first ?? ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4")
    }

    private var systemPrompt: String? {
        let prompt = profileManager?.currentProfile.systemPrompt ?? ""
        return prompt.isEmpty ? nil : prompt
    }


    var body: some View {
        #if DEBUG
        let _ = {
            PerfCounters.chatInputBarBody += 1
            print(String(format: "[PERF] ChatInputBar.body #%d t=%.3f focused=%@",
                         PerfCounters.chatInputBarBody,
                         CFAbsoluteTimeGetCurrent(),
                         isFocused ? "Y" : "N"))
        }()
        #endif
        // Claude App 风格：InputFieldContainer 自带两层布局（TextEditor + 工具栏），
        // ChatInputBar 只负责外层 padding、环境模糊背景、sheet、alert。
        return InputFieldContainer(
            isFocused: $isFocused,
            // turn 级状态（不是 provider 级 isStreaming）：工具循环空窗期按钮不闪回 send，
            // 堵住本对话在空窗期插队发送（user+user 连排）。别的对话照常显示 send → 排队。
            // 群聊例外：插话直接入树被轮次吸收（sendMessage 群分支），按钮保持发送态。
            isStreaming: viewModel.selectedConversation?.kind == "group" ? false : viewModel.isCurrentConvResponding,
            modelName: currentModel.name,
            pendingImageData: pendingImageData,
            pendingFileData: pendingFileData,
            pendingFileName: pendingFileName,
            pendingAttachments: pendingAttachments,
            onSend: { text in send(text) },
            onCancelStream: { viewModel.cancelAssistantTurn(context: modelContext) },
            onStickerTap: onStickerTap,
            onModelTap: { showModelPicker.toggle() },
            currentStyleId: viewModel.selectedConversation?.currentStyleId,
            onStyleChange: { styleId in
                viewModel.selectedConversation?.currentStyleId = styleId
            },
            groupMembers: {
                guard let conv = viewModel.selectedConversation, conv.kind == "group" else { return [] }
                return conv.participants.map { (name: $0.name, colorHex: $0.colorHex) }
            }(),
            draftConversationId: viewModel.selectedConversation?.id,
            initialDraft: viewModel.selectedConversation?.draftText ?? "",
            onDraftChange: { [weak viewModel] newText in
                guard let conv = viewModel?.selectedConversation, conv.draftText != newText else { return }
                conv.draftText = newText
                // 显式 save：autosave 时机不保证，被杀进程就丢（单行 update 每键无感）
                try? modelContext.save()
            }
        )
        // 定位对齐粟粟（她走 UIKit：container 的 leading/trailing 直接贴 chatHC.view，
        // bottom 钉 keyboardLayoutGuide.topAnchor，全程没有手写间距）。
        // 我们没有她那套 UIKit 定位层，用 SwiftUI 等价物：
        //   左右 16 → 8（她是 0 贴边，但我们输入框本体没有她那层 container 内边距，
        //   完全贴边会让玻璃描边压在屏幕边缘上，取 8 折中）
        //   底部 8 → 0（她无手写底距，安全区已经给了 home indicator 的位置）
        .padding(.horizontal, 8)
        .padding(.bottom, 0)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(alignment: .bottom) {
            ZStack {
                VariableBlurView(maxBlurRadius: blurRadius, direction: .blurredBottomClearTop)
                LinearGradient(
                    stops: [
                        .init(color: Theme.mainBg.opacity(0), location: 0.0),
                        .init(color: Theme.mainBg.opacity(0.1), location: 0.25),
                        .init(color: Theme.mainBg.opacity(0.3), location: 0.55),
                        .init(color: Theme.mainBg.opacity(0.4), location: 0.72),
                        .init(color: Theme.mainBg.opacity(0.35), location: 0.85),
                        .init(color: Theme.mainBg.opacity(0), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: isFocused ? 80 : 160)
            .offset(y: isFocused ? 10 : 40)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.25), value: isFocused)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerPopover(
                providerManager: providerManager,
                selectedModelId: currentModel.id
            ) { model in
                selectedModelId = model.id
                providerManager.touchLastUsed(providerId: model.providerId, modelId: model.modelId)
                showModelPicker = false
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            providerManager.resolveStaleSelectedModel()
            providerManager.resolveStaleFavorites()
        }
        .alert("预算保险闸", isPresented: Binding(
            get: { viewModel.budgetBlockedMessage != nil },
            set: { if !$0 { viewModel.budgetBlockedMessage = nil } }
        )) {
            Button("好") { viewModel.budgetBlockedMessage = nil }
        } message: {
            Text(viewModel.budgetBlockedMessage ?? "")
        }
        .alert("CC 未连接", isPresented: $showCCDisconnectedAlert) {
            Button("好") { }
        } message: {
            Text("CC 未连接，请检查 CC Bridge 设置")
        }
    }

    /// 返回 true 表示发送成功（子 view 应清空 text），false = 预算被拦（text 保留）
    private func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = pendingImageData.wrappedValue
        let fileData = pendingFileData.wrappedValue
        let fileName = pendingFileName.wrappedValue
        let attachments = pendingAttachments.wrappedValue
        guard !trimmed.isEmpty || imageData != nil || fileData != nil || !attachments.isEmpty else { return false }

        // Task 3: 选了 CC 模型但 CC 未连接 → 弹提示，不发送（保留 text）
        if providerManager.provider(for: currentModel)?.type == .ccBridge,
           !CCBridgeWebSocketClient.shared.isConnected {
            showCCDisconnectedAlert = true
            return false
        }

        let prof = profileManager?.currentProfile ?? Profile(name: "", emoji: "", description: "", userName: "你", assistantName: "AI")
        let preset = presetManager?.preset(byId: prof.presetId) ?? Preset.balanced

        // 预算 pre-check：被拦时返回 false，子 view 保留 text
        guard viewModel.preCheckBudget(
            text: trimmed,
            model: currentModel,
            profile: prof,
            preset: preset,
            providerManager: providerManager
        ) else { return false }

        // globalWorldBookEntries 已由 ContentView 同步
        let accepted = viewModel.sendMessage(trimmed, imageData: imageData, fileData: fileData, fileName: fileName, attachments: attachments, model: currentModel, profile: prof, preset: preset, providerManager: providerManager, context: modelContext)
        guard accepted else { return false }   // 被拦（如 API 车道抽不出文本的附件）→ 保留 text 与附件
        pendingImageData.wrappedValue = nil
        pendingFileData.wrappedValue = nil
        pendingFileName.wrappedValue = nil
        pendingAttachments.wrappedValue = []
        if let cid = viewModel.selectedConversation?.id { viewModel.draftAttachments[cid] = nil }
        return true
    }
}

// MARK: - ChatInputBar Equatable (B3 性能优化)
//
// 目的：流式响应期间 CardFlowView body 因读 viewModel.providerRouter.streamingText 每
// token 重算 → ContentView.iOSLayout 重算 → PagingContainerView.updatePages 无条件
// 大锤 → child HC.rootView 替换 → ChatInputBar 整棵重 diff（log 实测 326 次 / 19 次
// ContentView.body，放大 17×）。
//
// EquatableView 拦下"父重建传来的 instance 相等" case，body 跳过。@FocusState /
// @State / @AppStorage / @Observable 的 invalidation 走独立通路，focus/打字/流式
// isStreaming/切对话 的响应都还在。
//
// 5 个 class ref 跨 session 稳定，切楼层由 ContentView.id(profile.id) 重建整棵 →
// ref 全换 → == false → 重算。onStickerTap 闭包 nil/non-nil 二值：iOS 永远 non-nil、
// macOS 永远 nil，当前代码下 behavior 稳定；若未来 closure 变条件性，需加 UUID signal。
//
// Research: docs/research-chatinputbar-equatable.md
extension ChatInputBar: Equatable {
    static func == (lhs: ChatInputBar, rhs: ChatInputBar) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.modelContext === rhs.modelContext
            && lhs.profileManager === rhs.profileManager
            && lhs.providerManager === rhs.providerManager
            && lhs.presetManager === rhs.presetManager
            && (lhs.onStickerTap == nil) == (rhs.onStickerTap == nil)
            && (lhs.pendingImageData.wrappedValue != nil) == (rhs.pendingImageData.wrappedValue != nil)
            && (lhs.pendingFileData.wrappedValue != nil) == (rhs.pendingFileData.wrappedValue != nil)
            && lhs.pendingAttachments.wrappedValue.map(\.id) == rhs.pendingAttachments.wrappedValue.map(\.id)
    }
}

// MARK: - InputFieldContainer — 独立子 view 持有 inputText
//
// 把 inputText + TextField + Send Button + glassEffect 封装成 fileprivate 子 view，
// 打字时只重建这个子 view（~80ms），外层 ChatInputBar（底部按钮行 / VariableBlurView /
// sheet / alert）不受影响。粟粟 2026-04-19 log 实测 150-170ms/字 → 预期 ≤80ms/字。

/// Claude App 风格两层输入框：
/// 上层 TextField(axis:.vertical，自适应高度) + 下层工具栏（+ 号 | Spacer | 语音/发送）
private struct InputFieldContainer: View {
    /// 输入框排法：true = 细版单行（模型/✨ 在框外），false = 旧版两层（模型/✨ 在框内）。
    /// 只切「排法」，不切修复——TextField 自适应高度、发送键 branchIndicator 配色、
    /// 单按钮换图标、玻璃背景，两种排法共享同一份代码。
    @AppStorage("slimInputBar") private var slimInputBar = true
    /// 输入框全屏展开（参照 ChatGPT App）——细输入框最多 6 行，长消息看不全前文
    @State private var expandedInput = false
    /// 输入框是否已经换行/长到多行——决定右上角展开按钮出不出现
    /// TextField 实测高度（onGeometryChange 量的真值，不是估的）
    @State private var fieldHeight: CGFloat = 0
    /// 输入框是否已经长到头（撑满 lineLimit 上限、再打字也不长了）——此刻才给展开入口。
    /// 兔兔 2026-08-29 定的判定：不是「字够多」，是「框到顶了」，
    /// 因为正是那一刻才真的看不全前文。
    /// 13pt 字行高约 16pt + vertical padding 20，6 行封顶约 116pt，取 110 留余量。
    /// （933bd5a7 做过一次，后来被覆盖成字数阈值，08-31 修回。）
    /// 09-12 兔兔：「全屏编辑器没了」——不是被删，是旧版排法（slimInputBar=false）的 TextField
    /// 从来没量过高度，fieldHeight 恒 0，按钮永远不出；而且旧版 15pt × 5 行封顶约 102pt，
    /// 就算量了也过不了 110。两边各按各的行高定阈值：细版 110，旧版 92。
    private var inputAtMaxHeight: Bool { fieldHeight >= (slimInputBar ? 110 : 92) }
    /// 键盘是否已开始升起。驱动源用 keyboardWillShow 而非 isFocused——
    /// 粟粟 2026-08-16 真机终验记过这个坑：isFocused 驱动会让「输入框先闪下 10pt、
    /// 模型选择器异位、再上滑」的起步预抖。willShow 与键盘同一时刻，混不进可感范围。
    @State private var kbUp = false
    @State private var text: String = ""
    @FocusState.Binding var isFocused: Bool
    let isStreaming: Bool
    let modelName: String
    @Binding var pendingImageData: Data?
    @Binding var pendingFileData: Data?
    @Binding var pendingFileName: String?
    @Binding var pendingAttachments: [PendingChatAttachment]
    let onSend: (String) -> Bool
    let onCancelStream: () -> Void
    let onStickerTap: (() -> Void)?
    let onModelTap: () -> Void
    var currentStyleId: String? = nil
    var onStyleChange: ((String) -> Void)? = nil
    /// 群聊成员（名字+气泡色）。单聊传空数组，@ 补全整体不启用。
    var groupMembers: [(name: String, colorHex: String)] = []
    /// B41 草稿三件套：对话 id（切换信号）+ 初始草稿（恢复源）+ 每键回调（外层直写模型+save）。
    /// 粟粟教训：只靠"切换时 flush"必漏——翻页常驻不走 onDisappear、同 id 不走 onChange、
    /// rootView 重建 @State 直接蒸发。所以每键直写，切换恢复只是读取。
    var draftConversationId: String? = nil
    var initialDraft: String = ""
    var onDraftChange: ((String) -> Void)? = nil

    // ── @ 补全（G2）：纯 SwiftUI 层检测 text 末尾的 @片段，不碰 UITextView 内部 ──

    /// text 末尾正处于 "@xxx" 输入状态时返回 xxx（可为空串=刚打出 @）；否则 nil。
    private var mentionFragment: String? {
        guard !groupMembers.isEmpty else { return nil }
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        let frag = String(text[text.index(after: atIdx)...])
        // @ 后已出现空白 → 这个提及已完成，不再弹
        guard !frag.contains(where: { $0.isWhitespace }) else { return nil }
        guard frag.count <= 20 else { return nil }
        return frag
    }

    private var mentionCandidates: [(name: String, colorHex: String)] {
        guard let frag = mentionFragment else { return [] }
        if frag.isEmpty { return groupMembers }
        return groupMembers.filter { $0.name.range(of: frag, options: .caseInsensitive) != nil }
    }

    /// 把末尾的 @片段 替换成 @名字 + 空格（空格同时是后端 mentioned() 认的边界）。
    private func completeMention(_ name: String) {
        guard let atIdx = text.lastIndex(of: "@") else { return }
        text = String(text[..<atIdx]) + "@" + name + " "
    }

    private var canSend: Bool {
        isStreaming || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImageData != nil || pendingFileData != nil || !pendingAttachments.isEmpty
    }
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImageData != nil || pendingFileData != nil || !pendingAttachments.isEmpty
    }


    /// 风格快捷切换 ✨——两种排法共用（细版在框外那条，旧版在框内控件行）
    @ViewBuilder
    private var styleMenu: some View {
                Menu {
                    Button("无风格") {
                        onStyleChange?("")
                    }
                    ForEach(StyleManager.shared.styles) { style in
                        Button(style.name) {
                            onStyleChange?(style.id)
                        }
                    }
                } label: {
                    let hasStyle = !(currentStyleId?.isEmpty ?? true)
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        if hasStyle, let name = StyleManager.shared.find(currentStyleId ?? "")?.name {
                            Text(name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    // 与旁边模型胶囊同款：同样 ultraThinMaterial 玻璃 + 同内距，
                    // 两个并排才像一组。原来 5% 不透明度的底看着像个幽灵圆。
                    .foregroundColor(hasStyle ? Theme.branchIndicator : Theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
    }

    var body: some View {
        #if DEBUG
        let _ = {
            PerfCounters.inputFieldBody += 1
            print(String(format: "[PERF] InputFieldContainer.body #%d t=%.3f len=%d",
                         PerfCounters.inputFieldBody,
                         CFAbsoluteTimeGetCurrent(),
                         text.count))
        }()
        #endif
        return AnyView(VStack(spacing: 0) {
            // ── 多附件条（09-12）：缩略图 / 文件块横排，各自可删 ──────────────
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            ZStack(alignment: .topTrailing) {
                                if att.isImage, let d = att.imageData, let ui = ThumbnailCache.thumbnail(for: d, maxPixel: 56) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    VStack(spacing: 2) {
                                        Image(systemName: "doc.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(Theme.branchIndicator)
                                        Text(att.typeDescription)
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(Theme.textMuted)
                                        Text(att.name)
                                            .font(.system(size: 9))
                                            .foregroundColor(Theme.textMuted)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 72, height: 56)
                                    .padding(.horizontal, 4)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarBg))
                                }
                                Button {
                                    pendingAttachments.removeAll { $0.id == att.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(Theme.textMuted)
                                        .background(Circle().fill(Theme.mainBg))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                Divider().padding(.horizontal, 12)
            }
            // ── 图片预览行（pendingImageData 非 nil 时显示）──────────────
            if let imgData = pendingImageData, let uiImg = UIImage(data: imgData) {
                HStack(spacing: 8) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("photo.jpg")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Button {
                        pendingImageData = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().padding(.horizontal, 12)
            }
            // ── PDF 预览行（pendingFileData 非 nil 时显示）────────────────
            if pendingFileData != nil {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 60, height: 60)
                    Text(pendingFileName ?? "document.pdf")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        pendingFileData = nil
                        pendingFileName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().padding(.horizontal, 12)
            }
            // ── @ 补全候选条（G2，群聊输入 @ 时出现）───────────────────
            if !mentionCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionCandidates, id: \.name) { member in
                            Button {
                                completeMention(member.name)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(Color(hexString: member.colorHex))
                                        .frame(width: 8, height: 8)
                                    Text(member.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.mainBg.opacity(0.7)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
                Divider().padding(.horizontal, 12).padding(.top, 6)
            }
            // 旧版排法：文本独占上层（细版下文本在控件行里）
            if !slimInputBar {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .padding(.horizontal, 15)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    // 到顶时右上角浮着展开按钮，给首行末尾让出位置（同细版）
                    .padding(.trailing, inputAtMaxHeight ? 26 : 0)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        fieldHeight = h
                    }
            }

            // ── 控件行：细版 = + | 文本 | 发送；旧版 = + | 模型 | ✨ | Spacer | 发送 ──
            // 2026-08-24 兔兔第二轮真机验收：上一刀只把模型/✨ 挪到框外，
            // + 与发送键仍独占下面一行，所以还是两层、没瘦下来。
            // 粟粟那个是真单层——三者同处一个 HStack，文本多行时两侧按钮垂直居中。
            // 这里按她的排法并成一行；alignment 显式 .center，否则多行时按钮会被顶到顶部。
            HStack(alignment: .center, spacing: 0) {
                // + 号按钮
                if let onStickerTap {
                    Button(action: onStickerTap) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }

                // 旧版排法：模型/✨ 回到框内（细版下它们在框外那条）
                if !slimInputBar {
                    Button(action: onModelTap) {
                        HStack(spacing: 4) {
                            Text(modelName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(Theme.textMuted.opacity(0.7))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    styleMenu
                    Spacer()
                }

                // 文本输入（TextField(axis:.vertical) 自适应高度，封顶后内部滚）
                // 细版：与 + / 发送同处一行。旧版：这一行只放控件，文本在上层。
                if slimInputBar {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.leading, 6)
                    .padding(.vertical, 10)
                    // 到顶时右上角浮着展开按钮，给首行末尾让出位置，否则压字
                    .padding(.trailing, inputAtMaxHeight ? 26 : 0)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        fieldHeight = h
                    }
                }

                // 发送 / 停止 / 语音占位 —— 同一个按钮换图标，不做 if/else 两个按钮
                // 2026-08-24 兔兔第三轮：上一刀把黑换成 Theme.accent，太淡、糊进背景。
                // 粟粟用的是 Theme.branchIndicator（她注释叫「薄荷发送」），饱和度够。
                // 她也不拆两个按钮：canSend ? arrow.up : waveform，底色 canSend 才填，
                // 否则 Color.clear——这样空↔有字切换不会闪。
                Button(action: triggerSend) {
                    Image(systemName: isStreaming ? "stop.fill" : (canSend ? "arrow.up" : "waveform"))
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(canSend || isStreaming ? .white : Theme.textMuted.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(
                                isStreaming ? Theme.danger
                                            : canSend ? Theme.branchIndicator : Color.clear
                            )
                            .animation(.easeInOut(duration: 0.15), value: isStreaming)
                            .animation(.easeInOut(duration: 0.15), value: canSend)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !isStreaming)
                // 44×44 是 iOS 标准最小点击区，也是整行高度的下限——
                // 兔兔报「输入框太细」的根因：我上一刀只搬了粟粟里层那个 32 的圆，
                // 没搬她外面这层 44（CardFlowView:2035），行高就少了 8pt。
                .frame(width: 44, height: 44)
                .padding(.trailing, 4)
            }
            // 不设任何行高——粟粟那边整行也没有 frame(height:)，
            // 高度全靠 TextField 自己的 .padding(.vertical, 10) 撑出来。
            // 之前写死 44 正是「不随文字长高」第三次复发的根因。
            // 也不加 horizontal padding：她的左右内距全在 + / 发送键各自的 leading/trailing 上。
        }
        // 玻璃卡片只包「输入框本体」——模型/风格已挪到框外下方那条
        // 她 CardFlowView:2047 就一行纯材质，没有描边也没有投影。
        // 我原先加的 mainBg 打底 + strokeBorder + shadow 正是框看着比她「重」的原因。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        // 展开成全屏编辑：挂框内右上角（ChatGPT 那样）。
        // 只在输入框已长到头时出现：单行时框才 44pt 高，「右上角」就是右边、会撞发送键；
        // 而且没长满之前本来也看得全，不需要展开。
        .overlay(alignment: .topTrailing) {
            if inputAtMaxHeight {
                Button { expandedInput = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textMuted.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture { isFocused = true }
        )
        // ── 框外下方：模型 + 风格 ────────────────────────────────────
        // 兔兔 2026-08-24 定的方案（照粟粟思路）：这俩都是「这次对话用什么」的设置，
        // 不是「发这条消息」的动作，摘出框外输入框就回归单层 = 细。
        // 键盘升起时收起这条：兔兔发现原来 safeAreaInset 挂在输入框上，
        // 它就永远跟着输入框走，键盘顶不掉。粟粟那边也不是物理顶掉的——
        // 她显式写 `if !kbUp { bottomControlRow.transition(.opacity) }`。
        // 过渡只用淡入淡出不带位移：滑动成分会被看成「灰块被推下去」（她的原话）。
        // spacing 6 常驻——兔兔观察到粟粟键盘升起时输入框与键盘之间有条小缝。
        // 那正是她外层 VStack(spacing: 6) 留下的：kbUp 收的是 bottomControlRow 的
        // 内容，间距本身还在。我们原先整个 inset 一起消失，输入框就贴死键盘了。
        .safeAreaInset(edge: .bottom, spacing: 6) {
            if slimInputBar && !kbUp {
            HStack(spacing: 6) {
                Spacer()
            styleMenu
                // 模型胶囊（吸粟粟实调：10pt 字 + 5×5 状态点 + 中间截断，超长名不撑爆）
                Button(action: onModelTap) {
                    HStack(spacing: 4) {
                        Circle()
                            // 她 CardFlowView:1420 用的是 branchIndicator（薄荷），
                            // 我原先用 accent——那个太淡，兔兔说信号灯发暗。
                            .fill(Theme.branchIndicator.opacity(0.6))
                            .frame(width: 5, height: 5)
                        Text(modelName)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    // 她的实调：padding(6) 撑开触摸区 → contentShape → padding(-6) 收回视觉位置
                    .padding(6)
                    .contentShape(Rectangle())
                    .padding(-6)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            .padding(.trailing, 8)   // 粟粟实调：胶囊左移 8px
            .transition(.opacity)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $expandedInput) {
            ExpandedInputSheet(
                text: $text,
                onSend: {
                    expandedInput = false
                    triggerSend()
                },
                onDismiss: { expandedInput = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { kbUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { kbUp = false }
        }
        #endif
        // B41 草稿：每键上报（外层写 conversation.draftText + 显式 save）
        .onChange(of: text) { _, newText in
            onDraftChange?(newText)
        }
        // 切对话：换成新对话的草稿（旧对话的已实时落盘，无需 flush）
        .onChange(of: draftConversationId) { _, _ in
            text = initialDraft
        }
        // 冷启动 / view 重建：恢复当前对话的草稿
        .onAppear {
            if text.isEmpty, !initialDraft.isEmpty { text = initialDraft }
        }
    }

    private func triggerSend() {
        if isStreaming { onCancelStream(); return }
        HapticService.shared.sendMessage()
        if onSend(text) { text = "" }
    }
}

// MARK: - Model Picker Popover

struct ModelPickerPopover: View {
    let providerManager: ProviderManager
    let selectedModelId: String
    let onSelect: (ProviderModel) -> Void

    /// 优先显示收藏；收藏为空时 fallback 展示所有 enabled provider 的 models + 顶部提示。
    private var groupedSource: (items: [(APIProvider, [ProviderModel])], isFallback: Bool) {
        let favs = providerManager.favoritesByProvider
        if !favs.isEmpty {
            return (favs, false)
        }
        return (providerManager.enabledProviders.map { ($0, $0.models) }, true)
    }

    var body: some View {
        let source = groupedSource

        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if source.isFallback && !source.items.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                            .font(.system(size: Theme.F.caption))
                        Text("在 API 设置点 ★ 收藏常用模型")
                            .font(.system(size: Theme.F.caption))
                    }
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                }

                ForEach(source.items, id: \.0.id) { pair in
                    let provider = pair.0
                    let models = pair.1

                    Text(provider.name)
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach(models, id: \.id) { model in
                        let isSelected = model.id == selectedModelId
                        Button {
                            onSelect(model)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: Theme.F.body))
                                    .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                                Text(model.name)
                                    .font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, Theme.optionRowVerticalPadding)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Theme.accent.opacity(0.4) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if source.items.isEmpty {
                    Text("请先在设置中添加 API Key")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .padding(12)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Thinking UI

/// 思考进行中的呼吸动画标签
struct ThinkingBreathLabel: View {
    @State private var breathPhase = false

    var body: some View {
        Text("思考中…")
            .opacity(breathPhase ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: breathPhase)
            .onAppear { breathPhase = true }
    }
}

/// 思考内容底部 sheet（Claude App 风格）
struct ThinkingPanelView: View {
    let thinkingText: String
    let isThinking: Bool

    @State private var animateProgress = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Thought process")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 16))
                    .hidden()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // 思考进行中：橙色流动进度线
            if isThinking {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: geo.size.width * 0.3, height: 2)
                        .offset(x: animateProgress
                            ? geo.size.width * 0.7
                            : -geo.size.width * 0.3)
                        .animation(
                            .linear(duration: 1.5).repeatForever(autoreverses: false),
                            value: animateProgress
                        )
                        .onAppear { animateProgress = true }
                }
                .frame(height: 2)
                .clipped()
            }

            // 思考全文
            ScrollView {
                Text(thinkingText)
                    .font(.system(size: 15))
                    .lineSpacing(7.5)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Multimodal User Bubble

private struct MultimodalUserBubble: View {
    let content: String
    let fontScale: Double
    let lineSpacingScale: Double

    @State private var previewItems: [BubbleAttachmentItem]? = nil
    @State private var previewStart: Int = 0

    private struct ContentBlock {
        var images: [Data] = []            // 09-13：多图全画（之前只留最后一张）
        var fileNames: [String] = []       // CC 车道 file block / document 的名字
        var text: String = ""
    }

    private var parsed: ContentBlock {
        var block = ContentBlock()
        guard let data = content.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            block.text = content
            return block
        }
        for item in arr {
            let type = item["type"] as? String ?? ""
            if type == "image", let source = item["source"] as? [String: Any],
               let b64 = source["data"] as? String,
               let imgData = Data(base64Encoded: b64) {
                block.images.append(imgData)
            } else if type == "document" {
                block.fileNames.append(item["title"] as? String ?? "document.pdf")
            } else if type == "file" {
                block.fileNames.append(item["name"] as? String ?? "file")
            } else if type == "text" {
                block.text = item["text"] as? String ?? ""
            }
        }
        return block
    }

    var body: some View {
        let block = parsed
        VStack(alignment: .leading, spacing: 6) {
            if !block.images.isEmpty {
                // 一张：原样 200pt 宽；多张：九宫格 3 列，点哪张从哪张开始预览（09-13 兔兔真机 #8）
                // 09-20 兔兔：多图要「可滑动的一长条」——和附件条同一个零件（>3 张自动横滑 + 边缘渐隐），
                // 缩略图走 ThumbnailCache，不再每次 body 全尺寸解码（九张原图就是她说的那个卡死）
                let stripItems: [BubbleAttachmentItem] = block.images.enumerated().map { .image(name: "photo\($0.offset + 1).jpg", data: $0.element) }
                if stripItems.count == 1, let one = ThumbnailCache.thumbnail(for: block.images[0], maxPixel: 200) {
                    Image(uiImage: one)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        // 点开走她的 AttachmentPreviewSheet：全屏 + 保存到相册 + QuickLook
                        .onTapGesture { previewStart = 0; previewItems = stripItems }
                } else {
                    BubbleAttachmentStrip(items: stripItems, isUser: true)   // 多模态气泡只有 user 发
                }
            }
            ForEach(Array(block.fileNames.enumerated()), id: \.offset) { _, title in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red.opacity(0.8))
                    Text(title)
                        .font(FontManager.font(size: 13))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.textMuted.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !block.text.isEmpty {
                Text(block.text)
                    .font(FontManager.font(size: 13.5))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4 * (fontScale > 0 ? fontScale : 1.0) * lineSpacingScale)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { previewItems != nil },
            set: { if !$0 { previewItems = nil; previewStart = 0 } }
        )) {
            if let items = previewItems {
                AttachmentPreviewSheet(items: items, initialIndex: previewStart)
            }
        }
    }
}

// MARK: - Branch Info (value type passed to BubbleView)

struct BranchInfo {
    let displayedNodeId: String
    let branchNodeId: String
    let branchCount: Int
    let branchChildren: [(index: Int, node: MessageNode, isMainPath: Bool)]
}

// MARK: - Chat Bubble

struct BubbleView: View {
    /// 气泡模式总开关（设置→外观→消息显示）。关掉完全回到原渲染路径。
    ///
    /// 2026-08-28：这里原本是 @AppStorage，导致开关拨了却毫无变化——
    /// BubbleView 是 Equatable，SwiftUI 只在 == 返回 false 时才重建视图，
    /// 而 == 里比的十四项全是数据（node.id / content / isStreaming...），
    /// 没有任何外观项。@AppStorage 是内部状态、不参与 ==，
    /// 于是开关变了但每个气泡都判定「没变化」，拒绝重绘。
    /// 改为由父视图传入并加进 ==，值一变整列气泡才会跟着重画。
    let chatBubbleMode: Bool
    let node: MessageNode
    let hasBranches: Bool
    let branchInfo: BranchInfo?
    var isStreaming: Bool = false
    /// 流式时的实时文本——直接读 viewModel.streamingText，不经过 SwiftData
    var streamingContentText: String = ""
    /// True while the model is still generating reasoning_content (thinking phase)
    var isThinking: Bool = false
    /// Live reasoning tokens from ViewModel — only populated for the currently streaming node
    var streamingThinkingText: String = ""
    /// One-sentence summary generated after thinking phase ends; empty until summary arrives
    var thinkingSummary: String = ""
    var isHighlighted: Bool = false
    var isSearchMatch: Bool = false
    /// 当前对话路径的最后一条 assistant 消息。
    var isLastAssistant: Bool = false
    /// [search-ui] segments 分支的流式尾巴：streamingContentText 里减去 segments
    /// 已经包含的 .text 长度，只显示还没进 segments 的增量，防止双份显示。
    private func streamingTailAfterSegments(_ segs: [MessageSegment]) -> String {
        guard isStreaming, !streamingContentText.isEmpty else { return "" }
        var segTextCount = 0
        for seg in segs {
            if case .text(let t) = seg { segTextCount += t.count }
        }
        guard segTextCount < streamingContentText.count else { return "" }
        return String(streamingContentText.dropFirst(segTextCount))
    }

    /// 思考链预览（时钟 + 可展开）。segments / 纯文本两条渲染分支共用。
    /// 修复：带 segments 的消息（CC 标记式 / API 流式）此前完全不渲染 thinking。
    @ViewBuilder
    private func thinkingPreview(staticThinking: String) -> some View {
                    let liveThinking = isStreaming && !streamingThinkingText.isEmpty
                    let hasThinkingContent = liveThinking || !staticThinking.isEmpty
                    if hasThinkingContent && thinkingPreviewMode != "hidden" {
                        let displayThinking = liveThinking ? streamingThinkingText : staticThinking
                        let rawPreview = String(displayThinking.prefix(40)) + (displayThinking.count > 40 ? "…" : "")
                        let previewStr = thinkingPreviewMode == "prefix" ? rawPreview : (thinkingSummary.isEmpty ? rawPreview : thinkingSummary)
                        Button {
                            if thinkingSheetMode {
                                showThinkingSheet = true
                            } else {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    thinkingExpanded.toggle()
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                if liveThinking && isThinking {
                                    ThinkingBreathLabel()
                                } else {
                                    Text(previewStr)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer()
                                Image(systemName: thinkingExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9))
                            }
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 155/255.0, green: 142/255.0, blue: 126/255.0))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // 弹窗模式（thinkingSheetMode 开）：点标题弹全屏 sheet，复用 ThinkingPanelView
                        .sheet(isPresented: $showThinkingSheet) {
                            ThinkingPanelView(thinkingText: displayThinking, isThinking: liveThinking && isThinking)
                        }

                        // 内联展开区域（替代原 ThinkingPanelView sheet）
                        // 空白框 bug 修复：thinking 为空（trim 后）不渲染任何内容
                        if thinkingExpanded {
                            let thinkingText = liveThinking ? streamingThinkingText : staticThinking
                            if !thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                HStack(alignment: .top, spacing: 8) {
                                    Rectangle()
                                        .fill(Theme.textMuted.opacity(0.2))
                                        .frame(width: 2)

                                    VStack(alignment: .leading, spacing: 4) {
                                        let display = thinkingShowFull ? thinkingText : String(thinkingText.prefix(300))
                                        Text(display)
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textMuted)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        // 超过 300 字 → 渐变淡出 + Show more / Show less
                                        if thinkingText.count > 300 {
                                            Button(thinkingShowFull ? "Show less" : "Show more") {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    thinkingShowFull.toggle()
                                                }
                                            }
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.branchIndicator)
                                            .buttonStyle(.plain)
                                        }

                                        // Done 标记（非流式时）
                                        if !isThinking {
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark.circle")
                                                    .font(.system(size: 11))
                                                Text("Done")
                                                    .font(.system(size: 11))
                                            }
                                            .foregroundColor(Theme.textMuted.opacity(0.5))
                                        }
                                    }
                                }
                                .padding(.leading, 4)
                                .padding(.top, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
    }

    /// 轻提示（复制/收藏/钉住后的 toast）。BubbleView 拿不到 viewModel，
    /// 与 onToggleFavorite 等一样由父视图注入。
    var onNotice: ((String) -> Void)? = nil
    /// 删除二次确认（防误触——菜单里手滑一下消息就没了）
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onSoftDelete: () -> Void
    let onSwitchBranch: (String, Int) -> Void
    var onRegenerate: (() -> Void)? = nil
    var onEdit: ((String) -> Void)? = nil
    /// G3：群成员（长按「让 TA 接话」用）。单聊为空 → 菜单项不出现。
    var groupMembers: [(id: String, name: String)] = []
    var onGroupReply: ((String) -> Void)? = nil
    var regexScripts: [RegexScript] = []

    @Environment(\.modelContext) private var modelContext
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    @AppStorage("expandAllMessages") private var expandAllMessages = false
    // 气泡外观自定义（DisclosureGroup "气泡外观（高级）"）
    @AppStorage("bubbleCornerRadius") private var bubbleCornerRadius: Double = 16
    @AppStorage("bubblePaddingH") private var bubblePaddingH: Double = 18
    @AppStorage("bubblePaddingV") private var bubblePaddingV: Double = 15
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    @AppStorage("hideRoleName") private var hideRoleName: Bool = false
    @AppStorage("hideActionBar") private var hideActionBar: Bool = true
    @AppStorage("hideAssistantBubble") private var hideAssistantBubble: Bool = false
    @AppStorage("thinkingPreviewMode") private var thinkingPreviewMode: String = "summary"
    @AppStorage("bubbleModeCornerRadius") private var bubbleModeCornerRadius: Double = 23
    @State private var showBubbleThinking = false
    @State private var bubbleThinkingText = ""
    @State private var isExpanded = false
    @State private var showBranchPicker = false
    @State private var showFolderPicker = false
    @State private var thinkingExpanded = false
    @State private var thinkingShowFull = false  // "Show more" 控制
    @AppStorage("thinkingSheetMode") private var thinkingSheetMode = false  // 开=弹全屏 sheet，关=原地折叠
    @State private var showThinkingSheet = false
    @State private var showArtifactCanvas = false
    @State private var detectedArtifact: ArtifactContent? = nil
    @State private var messageWebViewHeight: CGFloat = 44

    /// 长按菜单样式：overlay（浮层，默认）/ system（原生）。设置→外观 可切；macOS 恒为原生
    @AppStorage("bubbleMenuStyle") private var bubbleMenuStyle: String = "overlay"
    private var useSystemBubbleMenu: Bool {
        #if os(macOS)
        return true
        #else
        // 09-15 兔兔 B 包：系统式长按「消息跟着旋转一圈」= 七月同款——lift 动画取的是源视图渲染，
        // 反转列表下源视图本身是翻的，自定义 preview 救不了。iOS 恒走浮层；缺的功能往浮层里补。
        return false
        #endif
    }

    /// 原生 contextMenu 的条目（与浮层 nodeMenuSpecs 同一份条件逻辑）
    @ViewBuilder private var systemMenuItems: some View {
                if isUser, onEdit != nil {
                    Button(action: {
                        editText = node.content
                        isEditing = true
                    }) {
                        Label("编辑", systemImage: "pencil")
                    }
                    Divider()
                }
                if !isUser, let onRegenerate, !isStreaming {
                    Button(action: onRegenerate) {
                        Label("重新生成", systemImage: "arrow.counterclockwise")
                    }
                    Divider()
                }
                if !isUser, !isStreaming {
                    Button {
                        SpeechService.shared.speak(nodeId: node.id, text: SpeechService.speakableText(from: node))
                    } label: {
                        Label("朗读", systemImage: "speaker.wave.2")
                    }
                    Button {
                        SpeechService.shared.stop()
                    } label: {
                        Label("停止朗读", systemImage: "speaker.slash")
                    }
                    Divider()
                }
                if !groupMembers.isEmpty, let onGroupReply, !isStreaming {
                    Menu {
                        ForEach(groupMembers, id: \.id) { member in
                            Button(member.name) { onGroupReply(member.id) }
                        }
                    } label: {
                        Label("让 TA 接话", systemImage: "bubble.left.and.bubble.right")
                    }
                    Divider()
                }
                Button(action: {
                    let willFav = !node.isFavorite
                    onToggleFavorite()
                    HapticService.shared.longPress()
                    onNotice?(willFav ? "已收藏" : "已取消收藏")
                }) {
                    Label(node.isFavorite ? "取消收藏" : "收藏", systemImage: node.isFavorite ? "star.slash" : "star")
                }
                Button(action: { showFolderPicker = true }) {
                    Label("收藏到文件夹...", systemImage: "folder.badge.plus")
                }
                Button(action: {
                    let willPin = !node.isPinned
                    onTogglePin()
                    HapticService.shared.longPress()
                    onNotice?(willPin ? "已钉住" : "已取消钉住")
                }) {
                    Label(node.isPinned ? "取消钉住" : "钉住", systemImage: node.isPinned ? "pin.slash" : "pin")
                }
                Divider()
                Button(action: {
                    UIPasteboard.general.string = ContentCleaner.clean(node.content, cacheKey: node.id)
                    // 2026-08-31：项目里早有 HapticService（含 copyText/deleteAction），
                    // 但气泡按钮一个都没接过——现成的轮子没用上。（自粟粟 07-11「气泡小按钮三连打磨」）
                    HapticService.shared.copyText()
                    onNotice?("已复制")
                }) {
                    Label("复制文本", systemImage: "doc.on.doc")
                }
                Button(action: { isSelectingText = true }) {
                    Label("选取文本", systemImage: "text.cursor")
                }
                Divider()
                Button(role: .destructive, action: {
                    // 兔兔 09-02 拍板：撤掉二次确认——app 里根本没有回收站入口，
                    // 弹窗说「可恢复」是空头支票；长按菜单本身已经是一道确认了。
                    HapticService.shared.deleteAction()
                    onSoftDelete()
                }) {
                    Label("删除", systemImage: "trash")
                }
    }

    // MARK: - [B·砖3] 长按菜单条目（Telegram 式浮层）——与 macOS .contextMenu 同一份条件逻辑
    private func nodeMenuSpecs() -> [MenuActionSpec] {
        var specs: [MenuActionSpec] = []
        if isUser, onEdit != nil {
            specs.append(MenuActionSpec(title: "编辑", systemImage: "pencil", dividerAfter: true) {
                editText = node.content
                isEditing = true
            })
        }
        if !isUser, let onRegenerate, !isStreaming {
            specs.append(MenuActionSpec(title: "重新生成", systemImage: "arrow.counterclockwise", dividerAfter: true, handler: onRegenerate))
        }
        if !isUser, !isStreaming {
            specs.append(MenuActionSpec(title: "朗读", systemImage: "speaker.wave.2") {
                SpeechService.shared.speak(nodeId: node.id, text: SpeechService.speakableText(from: node))
            })
            specs.append(MenuActionSpec(title: "停止朗读", systemImage: "speaker.slash", dividerAfter: true) {
                SpeechService.shared.stop()
            })
        }
        if !groupMembers.isEmpty, let onGroupReply, !isStreaming {
            // 浮层没有子菜单：一人一条「让 X 接话」
            for (i, member) in groupMembers.enumerated() {
                specs.append(MenuActionSpec(title: "让 \(member.name) 接话", systemImage: "bubble.left.and.bubble.right",
                                            dividerAfter: i == groupMembers.count - 1) { onGroupReply(member.id) })
            }
        }
        specs.append(MenuActionSpec(title: node.isFavorite ? "取消收藏" : "收藏", systemImage: node.isFavorite ? "star.slash" : "star") {
            let willFav = !node.isFavorite
            onToggleFavorite()
            HapticService.shared.longPress()
            onNotice?(willFav ? "已收藏" : "已取消收藏")
        })
        specs.append(MenuActionSpec(title: "收藏到文件夹...", systemImage: "folder.badge.plus") { showFolderPicker = true })
        specs.append(MenuActionSpec(title: node.isPinned ? "取消钉住" : "钉住", systemImage: node.isPinned ? "pin.slash" : "pin", dividerAfter: true) {
            let willPin = !node.isPinned
            onTogglePin()
            HapticService.shared.longPress()
            onNotice?(willPin ? "已钉住" : "已取消钉住")
        })
        specs.append(MenuActionSpec(title: "复制文本", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = ContentCleaner.clean(node.content, cacheKey: node.id)
            HapticService.shared.copyText()
            onNotice?("已复制")
        })
        specs.append(MenuActionSpec(title: "选取文本", systemImage: "text.cursor", dividerAfter: true) { isSelectingText = true })
        specs.append(MenuActionSpec(title: "删除", systemImage: "trash", isDestructive: true) {
            HapticService.shared.deleteAction()
            onSoftDelete()
        })
        return specs
    }
    @State private var isSelectingText = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var highlightOpacity: Double = 0
    private let truncateLength = 300

    var isUser: Bool { node.role == "user" }

    /// 群聊 V2：按发言者 id 稳定取色（确定性哈希，跨启动不变）。
    static func speakerColor(_ id: String?) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple]
        guard let id, !id.isEmpty else { return Theme.textMuted }
        let h = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[h % palette.count]
    }

    var body: some View {
        // 粟粟气泡模式整套搬运（2026-08-30）：顶层分流，气泡模式根本不进文章卡
        //（她的 CardFlowView innerBody 同款结构）。header 由 BubbleModeRow 自带。
        // multimodal_text 的图存在 content JSON 里（不是她那边的 .image 段），
        // 直接进她的 BubbleModeRow 会把整段 base64 当正文渲染——就是兔兔 08-31 实测的
        // 「特别长的白条 + 滑不到底」。老图片消息先回落文章路径（有 MultimodalUserBubble
        // 解包），新消息改写 .image 段是单独一刀（DEBT-MAP 已记）。
        if chatBubbleMode && node.contentType != "multimodal_text" {
            bubbleModeRowWired
        } else {
            articleBody
        }
    }

    /// 气泡模式接线（长按菜单 + 思考链入口）。
    /// 兔兔 2026-08-31 拍板：聊天软件里对面发来的是说出口的话，思考链不进对话流——
    /// 长按「他当时在想…」才看（灰泡由 bubbleInlineThinking 关掉，主人不白想，收进长按里）。
    private var bubbleModeRowWired: some View {
        Group {
            BubbleModeRow(
                node: node, isUser: isUser, isStreaming: isStreaming,
                // B6 A2'：弹泡数据源，只有流式中的 assistant 行才读
                streamingText: (!isUser && isStreaming) ? streamingContentText : nil,
                selectedFont: selectedFont, fontScale: fontScale,
                // 外观锁定 iMessage 固定值（她的注释：滑块只准普通模式调，字号仍可调）
                lineSpacingScale: BubbleModeRow.fixedLineSpacing,
                paragraphSpacingScale: BubbleModeRow.fixedParagraphSpacing,
                regexScripts: regexScripts,
                bubbleCornerRadius: bubbleModeCornerRadius,
                bubblePaddingH: BubbleModeRow.fixedPaddingH,
                bubblePaddingV: BubbleModeRow.fixedPaddingV,
                userName: userName,
                assistantName: node.senderName ?? assistantName,
                hideTimestamp: hideTimestamp, hideRoleName: hideRoleName,
                // 头像/入场弹泡/长按浮层：下一刀接线（entrancePending/popPending/blockMenuSpecs）
                showAvatar: false,
                avatars: .none,
                blockMenuSpecs: { block in bubbleMenuSpecs(quoteText: block) }
            )
        }
        .sheet(isPresented: $showBubbleThinking) {
            ThinkingSheet(text: bubbleThinkingText, nodeId: node.id, profileId: node.profileId)
        }
    }

    /// 气泡模式每个泡的长按菜单（结构照粟粟 bubbleMenuSpecs，动作接我们自己的）
    private func bubbleMenuSpecs(quoteText: String) -> [MenuActionSpec] {
        var specs: [MenuActionSpec] = []
        // 思考链入口放最上面：他当时在想…（兔兔的 A 方案）
        if !isUser {
            let segThinking = (node.segments ?? []).compactMap { seg -> String? in
                if case .thinking(text: let t, signature: _) = seg { return t } else { return nil }
            }.joined(separator: "\n\n")
            let thinking = ContentCleaner.extractThinking(from: node.content).thinking
                ?? node.ccThinking
                ?? (segThinking.isEmpty ? nil : segThinking)
            if let thinking, !thinking.isEmpty {
                specs.append(MenuActionSpec(title: "他当时在想…", systemImage: "cloud", dividerAfter: true) {
                    bubbleThinkingText = thinking
                    showBubbleThinking = true
                })
            }
        }
        if !isUser, let onRegenerate, !isStreaming {
            specs.append(MenuActionSpec(title: "重新生成", systemImage: "arrow.counterclockwise", dividerAfter: true, handler: onRegenerate))
        }
        specs.append(MenuActionSpec(title: node.isFavorite ? "取消收藏" : "收藏", systemImage: node.isFavorite ? "star.slash" : "star") {
            let willFav = !node.isFavorite
            onToggleFavorite()
            onNotice?(willFav ? "已收藏" : "已取消收藏")
        })
        specs.append(MenuActionSpec(title: "收藏到文件夹...", systemImage: "folder.badge.plus", dividerAfter: true) {
            showFolderPicker = true
        })
        specs.append(MenuActionSpec(title: "复制本段", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = quoteText
            onNotice?("已复制")
        })
        if !isUser {
            specs.append(MenuActionSpec(title: "朗读", systemImage: "speaker.wave.2") {
                SpeechService.shared.speak(nodeId: node.id, text: SpeechService.speakableText(from: node))
            })
            specs.append(MenuActionSpec(title: "停止朗读", systemImage: "speaker.slash", dividerAfter: true) {
                SpeechService.shared.stop()
            })
        }
        specs.append(MenuActionSpec(title: "删除", systemImage: "trash", isDestructive: true, handler: onSoftDelete))
        return specs
    }

    private var articleBody: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            // Role label + time（两个都隐藏时整行不 render，避免空 HStack 占位）
            if !hideRoleName || !hideTimestamp {
                HStack(spacing: 4) {
                    if !hideRoleName {
                        // 群聊 V2：名字标签优先用发言者名；颜色按发言者区分（单聊 senderName=nil 不变）
                        Text(isUser ? userName : (node.senderName ?? assistantName))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(node.senderName != nil ? Self.speakerColor(node.senderId) : Theme.textMuted)
                    }
                    if !hideTimestamp, let time = node.createTime {
                        Text(time.formatted(.dateTime.month().day().hour().minute()))
                            .font(.caption2)
                            .foregroundColor(Theme.textMuted.opacity(0.6))
                    }
                    if isUser { StyleChip(styleId: node.styleIdSnapshot) }
                }
                .padding(.horizontal, 4)
            }

            // Bubble（[B·砖3] iOS 包 BubbleMenuLiftWrapper：长按走自定义浮层，不用系统 contextMenu——
            // 反转列表下系统 lift 快照会颠倒（七月三雷之二）；浮层零件 592074d4 早已进仓，这里接线）
            BubbleMenuLiftWrapper(isUser: isUser, cornerRadius: chatBubbleMode ? bubbleModeCornerRadius : bubbleCornerRadius, actions: useSystemBubbleMenu ? [] : nodeMenuSpecs(),
                                  // round 11：浮层预览换 UITextView 可选字副本（MarkdownUI 不支持 textSelection）
                                  previewContent: {
                                      let raw = ContentCleaner.clean(node.content, cacheKey: node.id)
                                      let body = isUser ? raw : ContentCleaner.extractThinking(from: raw).content
                                      return AnyView(SelectableTextPreview(text: body, fontSize: 15 * (fontScale > 0 ? fontScale : 1.0),
                                                                           textColor: UIColor(Theme.textPrimary)))
                                  }) {
            VStack(alignment: .leading, spacing: 6) {
                // 流式优化：streaming 时直接读 streamingContentText（绕过 SwiftData），完成后读 node.content
                let sourceText = isStreaming && !streamingContentText.isEmpty ? streamingContentText : node.content
                let rawCleaned = ContentCleaner.clean(sourceText, cacheKey: "\(node.id)_\(sourceText.count)")
                let thinkingResult = isUser ? nil : ContentCleaner.extractThinking(from: rawCleaned)
                let cleaned = VoiceMessageWriter.strippedForDisplay(thinkingResult?.content ?? rawCleaned)
                // CC 思考链一律走 pendingThinking 正路：由 CCBridgeProvider / ConversationViewModel+Chat
                // 在 reply 到达时 consume 并嵌入该条自己的 content，再由下方 ThinkingBlockView 渲染。
                // 2026-08-24 拆除：这里原本挂 CCBridgeWebSocketClient.shared.latestThinking，
                // 那是 pendingThinking 之前的旧实现残骸（注释自称「向后兼容」），三重缺陷叠加——
                //   1. 背后的 thinkingBlocks 字典全项目只写不清
                //   2. latestThinking 取全局时间戳最大者，不区分对话 → 跨窗口串台
                //   3. isCCBridgeProvider 由非响应式 UserDefaults 裸读算出，切 provider 后滞后一轮
                // 症状：新回复等待期间，气泡里挂出「CC 思考过程」，点开是上一轮的内容。
                let shouldTruncate = !expandAllMessages && !isExpanded && cleaned.count > truncateLength

                if isUser {
                    if isEditing {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("编辑消息...", text: $editText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(FontManager.font(size: 13.5))
                                .lineLimit(1...10)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.mainBg)
                                )
                            HStack(spacing: 8) {
                                Button("取消") {
                                    isEditing = false
                                }
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                                .buttonStyle(.plain)

                                Button("提交") {
                                    let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !text.isEmpty {
                                        onEdit?(text)
                                    }
                                    isEditing = false
                                }
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.branchIndicator))
                                .buttonStyle(.plain)
                            }
                        }
                    } else if let segs = node.segments, segs.hasRenderableSegments {
                        // Claude v2 导入的 user 消息（通常只有 text + 末尾 attachment/file 段）
                        MessageSegmentsView(
                            segments: segs,
                            selectedFont: selectedFont,
                            fontScale: fontScale,
                            lineSpacingScale: lineSpacingScale,
                            paragraphSpacingScale: paragraphSpacingScale,
                            regexScripts: regexScripts,
                            isUser: true
                        )
                    } else if node.contentType == "multimodal_text" {
                        MultimodalUserBubble(
                            content: node.content,
                            fontScale: fontScale,
                            lineSpacingScale: lineSpacingScale
                        )
                    } else {
                        Text(shouldTruncate ? String(cleaned.prefix(truncateLength)) + "..." : cleaned)
                            .font(FontManager.font(size: 13.5))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(4 * (fontScale > 0 ? fontScale : 1.0) * lineSpacingScale)
                    }
                } else if let segs = node.segments, segs.hasRenderableSegments {
                    // 思考链兜底：segments 里没有 .thinking 段时（CC 标记式 / deepseek 流式），
                    // 用共用预览补渲染，否则思考链整体丢失。
                    let segsHaveThinking = segs.contains { seg in
                        if case .thinking = seg { return true } else { return false }
                    }
                    if !segsHaveThinking {
                        thinkingPreview(staticThinking: thinkingResult?.thinking ?? "")
                    }
                    // Claude v2 导入：按段渲染（每段独立折叠，顺序严格）
                    MessageSegmentsView(
                        segments: segs,
                        selectedFont: selectedFont,
                        fontScale: fontScale,
                        lineSpacingScale: lineSpacingScale,
                        paragraphSpacingScale: paragraphSpacingScale,
                        regexScripts: regexScripts
                    )
                    // [search-ui] 工具轮实时推送后本分支提前接管气泡；流式文本在
                    // 卡片下方继续显示。减去 segments 已含文本长度防双份
                    //（Anthropic 轮文本会进 segments，OpenAI 不会）。
                    let streamingTail = streamingTailAfterSegments(segs)
                    if !streamingTail.isEmpty {
                        Markdown(BubbleMarkdownSimplifier.simplify(streamingTail))
                            .markdownTheme(.memoryPalace(
                                fontName: selectedFont,
                                scale: fontScale > 0 ? fontScale : 1.0,
                                lineSpacingScale: lineSpacingScale,
                                paragraphSpacingScale: paragraphSpacingScale
                            ))
                            .textSelection(.enabled)
                    }
                } else {
                    thinkingPreview(staticThinking: thinkingResult?.thinking ?? "")

                    // Assistant content — 正则脚本渲染替换
                    let artifactForCard: ArtifactContent? = (!isUser && !isStreaming) ? ArtifactDetector.find(in: cleaned) : nil
                    let cleanedForDisplay = artifactForCard != nil ? ArtifactDetector.stripFirst(in: cleaned) : cleaned
                    let rawDisplay = shouldTruncate ? String(cleanedForDisplay.prefix(truncateLength)) + "\n\n..." : cleanedForDisplay
                    let displayText = node.role == "assistant" && !regexScripts.isEmpty
                        ? RegexEngine.apply(scripts: regexScripts, text: rawDisplay, messagePlacement: 2, isMarkdown: true)
                        : rawDisplay
                    if displayText.isEmpty && isStreaming {
                        TypingDotsView()
                    } else if !displayText.isEmpty {
                        // 三条路：WebView（原生画不了的：中文斜体/分割线/富文本里的标题引用代码块）
                        //        → 原生富文本（颜色/剧透/删除线的聊天体）→ MarkdownUI（普通文本）
                        let needsRich = RichBubbleText.needsRich(displayText)
                        let needsWebView = RichBubbleText.needsWebView(displayText, rich: needsRich)
                        if needsRich && !needsWebView {
                            // [B 计划·砖 1] 彩色字 / 剧透块原生渲染——不再各背一个 WebView
                            RichBubbleText(
                                text: displayText,
                                baseColor: Theme.textPrimary,
                                spoilerBg: Theme.textMuted,
                                font: .system(size: 13.5 * (fontScale > 0 ? fontScale : 1.0))
                            )
                        } else if needsWebView {
                            // 富文本 + 围栏代码块：暂留 WebView（原生 inline Markdown 画不了折叠代码块）
                            MessageContentWebView(
                                content: displayText,
                                themeColors: [
                                    "text-color": Theme.textPrimary.toHex(),
                                    "text-muted": Theme.textMuted.toHex(),
                                    "code-bg": Theme.mainBg.toHex(),
                                    "link-color": Theme.accent.toHex(),
                                    "spoiler-bg": Theme.textMuted.toHex(),
                                    "font-size": "\(13.5 * (fontScale > 0 ? fontScale : 1.0))px",
                                    "line-height": "\(1.5 * lineSpacingScale)"
                                ],
                                dynamicHeight: $messageWebViewHeight
                            )
                            .frame(height: messageWebViewHeight)
                        } else {
                            // 普通消息：MarkdownUI 渲染（纯 SwiftUI，零白屏）
                            // 抹平文档感（## 标题/嵌套列表/---）；只影响渲染，复制仍是 node.content 原文
                            // round 10：解析走缓存（窗口扩张时后台已预热；未命中就地解析一次）
                            Markdown(MarkdownParseCache.content(nodeId: node.id, text: isUser ? displayText : BubbleMarkdownSimplifier.simplify(displayText)))
                                .markdownTheme(
                                    .memoryPalace(
                                        fontName: selectedFont,
                                        scale: CGFloat(fontScale > 0 ? fontScale : 1.0),
                                        lineSpacingScale: CGFloat(lineSpacingScale),
                                        paragraphSpacingScale: CGFloat(paragraphSpacingScale)
                                    )
                                )
                                .textSelection(.enabled)
                        }
                    }
                }

                // 主人发来的图/文件（.image / .fileData 段）：文章模式原来只在气泡模式画附件条，
                // 这里补上——不然他 reply(file_path:) 发的文件只剩一行「📎 名字」（兔兔 09-20）
                if !chatBubbleMode, let segs = node.segments?.hydratedForDisplay(profileId: node.profileId) {
                    let items: [BubbleAttachmentItem] = segs.compactMap { seg in
                        if case .image(let n, _, let d) = seg { return .image(name: n, data: d) }
                        if case .fileData(let n, let m, let d) = seg { return .fileData(name: n, mime: m, data: d) }
                        return nil
                    }
                    if !items.isEmpty {
                        BubbleAttachmentStrip(items: items, isUser: isUser)
                            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                    }
                }
                // Artifact canvas card (assistant only, not during streaming)
                // 语音条胶囊（audioRef 不进 segments 渲染，这里单独画）
                // D4：气泡模式下语音已在 BubbleModeRow 里一条一泡，外侧胶囊不再画
                if !chatBubbleMode, let segs = node.segments {
                    let voiceSegs: [(path: String, duration: Double?)] = segs.compactMap { seg in
                        if case .audioRef(_, _, let p, let d, _) = seg { return (p, d) }
                        return nil
                    }
                    ForEach(voiceSegs, id: \.path) { v in
                        VoiceCapsuleView(path: v.path, duration: v.duration,
                                         nodeId: node.id, profileId: node.profileId, isUser: isUser)
                            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                    }
                }
                // 生成中：画同形胶囊的「成型态」，而不是让占位行以纯文字露脸
                if !isUser, VoiceMessageWriter.isPending(node: node) {
                    VoicePendingCapsuleView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !isUser && !isStreaming, let artifact = ArtifactDetector.find(in: cleaned) {
                    ArtifactCodeFoldView(
                        code: artifact.code,
                        language: artifact.type.label
                    )
                    ArtifactCardView(artifact: artifact) {
                        detectedArtifact = artifact
                        showArtifactCanvas = true
                    }
                }

                if !expandAllMessages && cleaned.count > truncateLength {
                    // 按钮出现时才挂 HStack，避免空 HStack 吃掉 VStack 的
                    // spacing: 6（上下共 12pt）造成气泡底部多一截留白。
                    HStack(spacing: 8) {
                        Button(isExpanded ? "收起" : "展开全文") {
                            isExpanded.toggle()
                        }
                        .font(.caption)
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.plain)
                    }
                }

                // Branch indicator
                if hasBranches, let info = branchInfo {
                    BranchIndicator(
                        info: info,
                        showPicker: $showBranchPicker,
                        onSwitchBranch: onSwitchBranch
                    )
                }

// PR(usage): 气泡底部 token 数字已移除（统计走 Token 统计页）
            }
            .padding(.horizontal, bubblePaddingH)
            .padding(.vertical, bubblePaddingV)
            .background(
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .fill(isUser ? Theme.userBubble : (hideAssistantBubble ? Color.clear : Theme.assistantBubble))
            )
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .fill(Theme.branchIndicator.opacity(0.2 * highlightOpacity))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCornerRadius)
                    .stroke(Theme.branchIndicator.opacity(isSearchMatch ? 0.6 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            )
            .overlay {
                if isSelectingText {
                    VStack(spacing: 0) {
                        HStack {
                            Text("选取文本")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                            Spacer()
                            Button("完成") { isSelectingText = false }
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                        SelectableTextOverlay(
                            text: ContentCleaner.clean(node.content, cacheKey: node.id),
                            font: .systemFont(ofSize: 13.5 * CGFloat(fontScale > 0 ? fontScale : 1.0)),
                            textColor: UIColor(Theme.textPrimary),
                            isActive: $isSelectingText
                        )
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.systemBackground).opacity(0.97))
                            .shadow(radius: 4)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.easeOut(duration: 0.2), value: isSelectingText)
                }
            }
            .onChange(of: isHighlighted) { _, highlighted in
                if highlighted {
                    withAnimation(.easeIn(duration: 0.3)) { highlightOpacity = 1 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeOut(duration: 0.5)) { highlightOpacity = 0 }
                    }
                }
            }
            }   // BubbleMenuLiftWrapper
            .if(isUser) { view in
                view.frame(maxWidth: 500, alignment: .trailing)
            }
            // 长按菜单样式（兔兔 09-13 B 包 #7：「能不能新旧可选」）：浮层 = Telegram 式（默认）；
            // 系统 = 原生 contextMenu，反转列表下自带 preview 画正的（不用系统快照，快照会颠倒）
            .if(useSystemBubbleMenu) { view in
                view.contextMenu(menuItems: { systemMenuItems }, preview: {
                    Text(ContentCleaner.clean(node.content, cacheKey: node.id).prefix(600))
                        .font(FontManager.font(size: 13.5))
                        .foregroundColor(Theme.textPrimary)
                        .padding(12)
                        .frame(maxWidth: 320, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.sidebarBg))
                })
            }

            // Hover action buttons — macOS only（iOS 用 context menu 代替）

            // iOS action bar: copy / TTS / regenerate (controlled by hideActionBar setting)
            if !hideActionBar {
                HStack(spacing: 16) {
                    // Copy
                    Button {
                        UIPasteboard.general.string = ContentCleaner.clean(node.content, cacheKey: node.id)
                        HapticService.shared.copyText()
                        onNotice?("已复制")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)

                    // Regenerate (assistant only, not streaming)
                    if !isUser, let onRegenerate, !isStreaming {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }

                    // Favorite
                    Button(action: onToggleFavorite) {
                        Image(systemName: node.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13))
                            .foregroundColor(node.isFavorite ? Theme.favorite : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            HapticService.shared.copyText()
        }
        // 注意：删了 .contentShape(Rectangle())。它会把 contextMenu 命中区扩到整 row 宽
        // (maxWidth: .infinity)，导致 row 空白区 (input bar 后渗 / home indicator 上方那带)
        // 点击都触发 contextMenu。删后命中区缩到气泡视觉本身（line 1238 的 RoundedRectangle），
        // 即 .contextMenu 自己附着的那个 view 的 frame。
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerSheet(node: node, profileId: node.profileId)
        }
        .sheet(isPresented: $showArtifactCanvas) {
            if let artifact = detectedArtifact {
                ArtifactCanvasSheet(artifact: artifact)
            }
        }
    }
}

// MARK: - BubbleView Equatable (B3 性能优化)
//
// 只比较影响渲染的**值输入**，排除每次 makeBubbleView 都新建的闭包
//（onToggleFavorite / onRegenerate…）。闭包行为稳定（同 node 同语义），不进 == 判据。
// node 的内容变化：流式走 streamingContentText / streamingThinkingText（每 token 变 → 该条
// 重渲染），finalize / 切分支 flip isStreaming / streamingNodeId（父 prop 变 → 重渲染），
// 编辑/重生成建新 node（ForEach id 变 → 新视图）。node.content 兜底真机可能的原地写。
// @AppStorage / @State（字体、展开态…）走独立 invalidation，不受 == 影响，照常更新。
extension BubbleView: Equatable {
    static func == (lhs: BubbleView, rhs: BubbleView) -> Bool {
        lhs.node.id == rhs.node.id
            && lhs.node.content == rhs.node.content
            && lhs.node.isPinned == rhs.node.isPinned
            && lhs.node.isFavorite == rhs.node.isFavorite
            && lhs.node.isTrashed == rhs.node.isTrashed
            && lhs.hasBranches == rhs.hasBranches
            && lhs.branchInfo?.branchNodeId == rhs.branchInfo?.branchNodeId
            && lhs.branchInfo?.branchCount == rhs.branchInfo?.branchCount
            && lhs.branchInfo?.displayedNodeId == rhs.branchInfo?.displayedNodeId
            && lhs.isStreaming == rhs.isStreaming
            && lhs.streamingContentText == rhs.streamingContentText
            && lhs.isThinking == rhs.isThinking
            && lhs.streamingThinkingText == rhs.streamingThinkingText
            && lhs.thinkingSummary == rhs.thinkingSummary
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.isSearchMatch == rhs.isSearchMatch
            && lhs.isLastAssistant == rhs.isLastAssistant
            && lhs.regexScripts.count == rhs.regexScripts.count
            && lhs.groupMembers.count == rhs.groupMembers.count
            && lhs.chatBubbleMode == rhs.chatBubbleMode
    }
}

// MARK: - Tag Picker Sheet

struct FolderPickerSheet: View {
    let node: MessageNode
    let profileId: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var tags: [ConversationTag]
    @State private var newTagName = ""

    init(node: MessageNode, profileId: String) {
        self.node = node
        self.profileId = profileId
        _tags = Query(
            filter: #Predicate<ConversationTag> { $0.profileId == profileId },
            sort: \ConversationTag.order
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("收藏到标签")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)

            if tags.isEmpty {
                Text("还没有标签，先创建一个吧")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(tags) { tag in
                            Button(action: {
                                let item = FavoriteItem(nodeId: node.id, conversationId: node.conversationId, tagId: tag.id, contentPreview: String(node.content.prefix(100)), profileId: profileId)
                                ConversationListStore.insertFavorite(item, context: modelContext)
                                dismiss()
                            }) {
                                HStack {
                                    Text(tag.emoji)
                                    Text(tag.name)
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.accent.opacity(0.3))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                .frame(maxHeight: 200)
            }

            Divider()

            HStack {
                TextField("新建标签名...", text: $newTagName)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.3)))

                Button("创建") {
                    guard !newTagName.isEmpty else { return }
                    let tag = ConversationTag(name: newTagName, order: tags.count, profileId: profileId)
                    ConversationListStore.insertTag(tag, context: modelContext)
                    newTagName = ""
                }
                .disabled(newTagName.isEmpty)
            }

            Button("取消") { dismiss() }
                .foregroundColor(Theme.textMuted)
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Conditional Modifier

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Branch Indicator

struct BranchIndicator: View {
    let info: BranchInfo
    @Binding var showPicker: Bool
    let onSwitchBranch: (String, Int) -> Void
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { showPicker.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text("\(info.branchCount) 条分支")
                        .font(.system(size: 11))
                }
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Theme.branchIndicator.opacity(0.12))
                )
            }
            .buttonStyle(.plain)

            if showPicker {
                VStack(spacing: 3) {
                    ForEach(info.branchChildren, id: \.index) { branch in
                        Button(action: {
                            onSwitchBranch(info.branchNodeId, branch.index)
                            showPicker = false
                        }) {
                            HStack(spacing: 6) {
                                if branch.isMainPath {
                                    Image(systemName: "star.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.favorite)
                                }

                                Text(branch.node.role == "user" ? userName : assistantName)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Theme.textSecondary)

                                Text(String(ContentCleaner.clean(branch.node.content, cacheKey: branch.node.id).prefix(60)))
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.accent.opacity(0.5))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - TagPickerPopover（聊天页 nav ⋯ Menu 的"改标签"sheet）
//
// 学 ModelPickerPopover 的结构：List 展示所有 tag，每项 tap toggle 当前对话的
// tag 归属。底层数据是 ConversationTag + FavoriteItem join（nodeId == nil 代表
// 对话级 tag，区别于 bubble 收藏）。

struct TagPickerPopover: View {
    let conversationId: String
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var tags: [ConversationTag]
    @Query private var favoriteItems: [FavoriteItem]

    init(conversationId: String, profileId: String) {
        self.conversationId = conversationId
        self.profileId = profileId
        _tags = Query(
            filter: #Predicate<ConversationTag> { $0.profileId == profileId },
            sort: \ConversationTag.order
        )
        _favoriteItems = Query(
            filter: #Predicate<FavoriteItem> {
                $0.profileId == profileId && $0.conversationId == conversationId && $0.nodeId == nil
            }
        )
    }

    private var activeTagIds: Set<String> {
        Set(favoriteItems.map(\.tagId))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("改标签")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if tags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tag.slash")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                    Text("还没有标签")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                    Text("去侧栏新建标签")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tags) { tag in
                            let isOn = activeTagIds.contains(tag.id)
                            Button {
                                toggleTag(tag, isOn: isOn)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(tag.emoji)
                                        .font(.system(size: 18))
                                    Text(tag.name)
                                        .font(.system(size: 15))
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    if isOn {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(Theme.branchIndicator)
                                    } else {
                                        Image(systemName: "circle")
                                            .font(.system(size: 18))
                                            .foregroundColor(Theme.textMuted.opacity(0.4))
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    private func toggleTag(_ tag: ConversationTag, isOn: Bool) {
        if isOn {
            // 删除该 tag 的 FavoriteItem
            for item in favoriteItems where item.tagId == tag.id {
                ConversationListStore.deleteFavorite(item, context: modelContext)
            }
        } else {
            // 插入新 FavoriteItem（对话级 tag，nodeId = nil）
            // preview 取对话标题；此处只有 conversationId，查一下
            let preview = ConversationListStore.conversation(id: conversationId, profileId: profileId, context: modelContext)?.title ?? ""
            let item = FavoriteItem(
                conversationId: conversationId,
                tagId: tag.id,
                contentPreview: preview,
                profileId: profileId
            )
            ConversationListStore.insertFavorite(item, context: modelContext)
        }
    }
}

// MARK: - Transient Notice Capsule (B20 part 2)

/// 极简临时提示胶囊（已切换到分支等）。挂在 chat page 顶部。
/// 透明度自驱：onAppear fade in，2s 后由 caller 清 viewModel.transientNotice。
private struct TransientNoticeCapsule: View {
    let text: String
    @State private var opacity: Double = 0

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Theme.mainBg.opacity(0.95))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Theme.textMuted.opacity(0.15), lineWidth: 0.5)
            )
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) { opacity = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeIn(duration: 0.32)) { opacity = 0 }
                }
            }
    }
}

// BubbleAttachmentItem 已随粟粟原文搬运挪到 Views/BubbleAttachmentStrip.swift（2026-08-30）
