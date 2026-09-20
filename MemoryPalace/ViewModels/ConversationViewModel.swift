import Foundation
import SwiftData
import SwiftUI

/// 临时提示（fade-out toast）。每条新提示 id 必须新生成，
/// CardFlowView 用 .id() 做 overlay 重置触发。
struct TransientNotice: Equatable {
    let id: UUID
    let text: String
    init(_ text: String) {
        self.id = UUID()
        self.text = text
    }
}

@Observable
final class ConversationViewModel {
    /// CC 桥选择卡挂起中（非 nil = sheet 呈现）。详见 ConversationViewModel+AskUser.swift
    var pendingCCQuestion: PendingCCQuestion? = nil
    var pendingAPIQuestion: PendingAPIQuestion? = nil

    var selectedConversation: Conversation?
    /// CC→记忆 反向提取用：installCCFollowUpHandler 从 loadConversation 注册时拿不到
    /// providerManager（那条路径没有）。存一份最近一次可用的，让 CC proactive 回复也能提取。
    var ccProviderManager: ProviderManager?
    var currentPath: [MessageNode] = []   // The currently displayed path of cards

    /// CC 消息来得比路径重建快时的待插队列。
    /// 不排队直接插的话，parentId=nil 会让这条消息成为新根，整条历史被绕过
    /// ——兔兔实测「聊天记录被整个吞掉」就是这么来的。loadConversation 完成后消费。
    var pendingCCMessages: [(chatId: String, content: String, contentType: String)] = []

    /// 渲染窗口：只画尾部这么多条，往上滑再扩。
    /// 此前 ForEach 直接吃整条 currentPath——聊到上千条时每条都要参与布局与几何测量，
    /// 于是白屏、左右滑卡死、连打字都卡（兔兔实测）。LazyVStack 只省绘制不省布局。
    /// round 9（B）：一次补 60 条 = 60 个 Markdown 气泡在同一帧里生成，就是上滑时那一下「加载感」。
    /// 改 24：一屏多一点，滑到顶再补，每次都轻。
    static let renderWindowStep = 24
    /// 打开对话时先画多少条。兔兔 09-12：「点开长对话明显卡顿、白、划不动」——打开那一下
    /// 要同步生成整个窗口的气泡（Markdown 排版，有的带 WebView），60 条是主线程上几百毫秒
    /// 到一两秒。24 条稳稳超过一屏，打开成本先砍一大半；上滑到顶再按 step 补。
    static let initialRenderWindow = 24
    /// 窗口**起点**（currentPath 下标），不是窗口长度。
    /// 之前记的是长度 `suffix(60)`：每发一条（尾部 +2）顶上就被挤掉 2 条——正在被布局的
    /// 列表同帧一头长一头缩，钉底锚点跟不上，屏幕露出没画的区域＝兔兔说的「发完消息整页
    /// 空白，往下划一下才回来」，长对话（>60 条）才有这一挤所以更明显。改记起点后追加
    /// 消息只让窗口自然变长，顶上不动；起点只在切对话（reset）和上滑扩窗（expand）时变。
    var renderStart: Int = 0

    /// 实际交给 ForEach 的那一段
    var visiblePath: [MessageNode] {
        // 起点越界（路径被重建得比起点还短）时整条给出去，宁可多画也不能画空
        guard renderStart > 0, renderStart < currentPath.count else { return currentPath }
        return Array(currentPath[renderStart...])
    }

    var hasMoreAbove: Bool { renderStart > 0 && renderStart < currentPath.count }

    /// 往上滑到顶时扩窗
    func expandRenderWindow() {
        guard hasMoreAbove else { return }
        renderStart = max(0, renderStart - Self.renderWindowStep)
    }

    /// 切对话 / 重建路径时收回窗口（按当时的 currentPath 算，须在 currentPath 赋值之后调）
    func resetRenderWindow() { renderStart = max(0, currentPath.count - Self.initialRenderWindow) }
    var branchChoices: [String: Int] = [:] // nodeId -> chosen child index
    var isLoading: Bool = false

    /// 当前选中对话是否正在加载。isLoading 全局单值，切对话时会泄漏到别的对话。
    /// UI 用这个 computed property 隔离。
    var isCurrentConvLoading: Bool {
        isLoading && selectedConversation != nil
    }
    /// 正在流式生成的节点 id —— 跨对话/分支精确判定打字气泡与思考链归属（防泄漏）
    var streamingNodeId: String? = nil
    /// 正在流式生成的对话 id —— 输入栏发送/停止按钮只在所属对话变红（防全局泄漏）
    var streamingConversationId: String? = nil

    // MARK: - 发送排队（照搬 SusuPalace pendingSends 方案，全局串行单流）
    //
    // providerRouter.isStreaming 是 provider 级状态：Provider 内部工具循环的空窗期它
    // 短暂为 false；且三个 provider 实例各持单 task，并发第二条流会 resetState 掐死
    // 前一条（气泡永远卡空）。turn 级状态 assistantTurnInFlight 从发送起到
    // onComplete/onError/cancel 全程 true，期间任何 sendMessage 一律进 pendingSends
    // 排队，turn 结束自动补发。参照 SusuPalace docs/plan-consecutive-user-turns-fix.md

    /// 当前 assistant turn（含 Provider 内部工具循环 / 群聊整轮）是否进行中。
    /// 只管 **API 车道**（openAI/anthropic），CC 车道见下。
    var assistantTurnInFlight = false
    /// 群聊插话信号：轮次进行中用户又发了消息 → 循环下一圈重置发言预算，
    /// 让成员围绕新消息再回（否则名额用尽时插话会没人理）。
    var groupInterjectionPending = false
    /// 群聊轮次级取消：cancelAPI 只能掐当前一条流，掐不掉选人循环——循环每圈查它。
    var groupRoundCancelled = false
    /// in-flight 期间用户发的消息排队，turn 结束（或回到原对话时）自动补发
    var pendingSends: [PendingSend] = []

    // CC 豁免：CC 走 Hub/tmux 线路，和 API providers 物理隔离，互不排队。
    // 但 CCBridgeProvider 是单实例（replyTimer/isStreaming 单份），CC 车道内部
    // 仍然串行：已有 CC turn 等待时，新 CC 消息排队。
    /// 正在等 CC 回复的对话 id（nil = CC 车道空闲）
    var ccTurnConversationId: String? = nil
    /// 等 CC 回复的 placeholder 节点 id（打字气泡 + 停止闭合定位用）
    var ccTurnNodeId: String? = nil

    /// 当前**选中对话**是否正在等 AI 回复（两条车道取或）。
    /// turn 状态是全局单值，UI（输入栏 stop/send 三态）必须按对话 id 隔离，
    /// 否则切到别的对话也显示停止按钮，骗用户以为那个对话也在跑。
    var isCurrentConvResponding: Bool {
        (assistantTurnInFlight && streamingConversationId == selectedConversation?.id)
            || (ccTurnConversationId != nil && ccTurnConversationId == selectedConversation?.id)
    }

    struct PendingSend: Identifiable {
        let id = UUID()
        let text: String
        let imageData: Data?
        let fileData: Data?
        let fileName: String?
        var attachments: [PendingChatAttachment] = []   // 多附件（09-12）
        let model: ProviderModel
        let profile: Profile
        let preset: Preset
        let providerManager: ProviderManager
        let context: ModelContext
        let conversationId: String
    }
    /// 多附件草稿按对话暂存（09-12）：切对话不丢；App 生命周期内有效，跨重启持久化另做
    var draftAttachments: [String: [PendingChatAttachment]] = [:]
    var scrollToNodeId: String? = nil
    var pendingScrollNodeId: String? = nil
    var highlightedNodeId: String? = nil
    var sidebarRefreshTrigger: Int = 0
    var globalWorldBookEntries: [WorldBookEntry] = []  // View 层从 GlobalWorldBookManager 注入

    // In-conversation search
    var inConvSearchKeyword: String = ""
    var inConvMatches: [String] = []   // matched node IDs
    var inConvMatchIndex: Int = -1

    /// 临时提示文案（如"已切换到分支"），CardFlowView overlay 监听显示，
    /// id 变化触发自动 fade out。设新文案时 id 必须新生成。
    var transientNotice: TransientNotice? = nil

    /// 搜索点击去抖：300ms 内同 nodeId 重复点击直接吃掉。
    /// 不放 SidebarView 是因为它是 struct view，state 在 reload 间易丢。
    var lastNavigateNodeId: String? = nil
    var lastNavigateAt: Date? = nil

    /// Maps a displayed node id → the actual branching node id (for invisible branch points)
    var bubbledBranches: [String: String] = [:]

    /// Precomputed branch info for each node in currentPath (avoids redundant computation during rendering)
    var branchInfoMap: [String: BranchInfo] = [:]

    /// 缓存 collectAllBranches().count（🌿 角标）。ContentView.iOSChatTopBar 每次 body 都会读它，
    /// 而侧栏拖动 / 键盘 / 流式都会高频重算 ContentView.body——直接调 collectAllBranches() 会
    /// 每帧 DFS 整棵树，对话越长越卡（左滑卡顿主凶之一）。只在树结构变化处刷新此缓存。
    var cachedBranchOffMainCount: Int = 0

    /// 树结构变化后刷新 🌿 计数缓存。只在 applyTreeData / rebuildPath / regenerate /
    /// editAndResend 这几个改动分支结构的地方调用。
    func refreshBranchOffMainCount() {
        cachedBranchOffMainCount = collectAllBranches().count
    }

    var nodeMap: [String: MessageNode] = [:]
    var mainPathIds: Set<String> = []
    var cachedRootId: String?

    // MARK: - Profile Switch Race Defense
    //
    // 切楼层时（ProfileManager.switchTo）会换 modelContainer，旧 Conversation /
    // MessageNode 实例被 SwiftData reset。但路线 C（UIKit PagingContainerView 嵌套
    // UIHostingController）下，旧 SwiftUI view tree 的 dismount 时序不和主 tree
    // 原子对齐，旧 CardFlowView.body 可能在 reset 后还跑一次读 selectedConversation.id
    // → fatal。Master 用 SwiftUI 原生 TabView 无此问题（同 commit phase 原子）。
    //
    // 修法：切楼层前 post .profileWillSwitch，这里 observer 把 VM 持有的所有
    // SwiftData 实例 ref 清空。旧 view body 再跑时读到 nil，不访问已 destroy 实例。
    /// profileWillSwitch observer 的 token。addObserver(forName:...:queue:using:) 返回
    /// 的是 token 不是 self，removeObserver(self) 对 block-based observer 不生效 ——
    /// 必须存 token 显式 remove。
    /// xcdoc: /documentation/foundation/notificationcenter/addobserver(forname:object:queue:using:)
    private var profileSwitchObserver: NSObjectProtocol?

    init() {
        // queue: nil → block 同步在 posting 线程（switchTo 跑在 main）跑，post() 返回时
        // clear 已经执行完，随后 currentProfile / container flip 时旧 VM 已无 SwiftData ref。
        profileSwitchObserver = NotificationCenter.default.addObserver(
            forName: .profileWillSwitch, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.selectedConversation = nil
            self.currentPath = []
            self.nodeMap.removeAll()
            self.mainPathIds.removeAll()
            self.cachedRootId = nil
            self.branchChoices.removeAll()
            self.bubbledBranches.removeAll()
            self.branchInfoMap.removeAll()
            self.effectiveChildrenMap.removeAll()
            self.scrollToNodeId = nil
            self.pendingScrollNodeId = nil
            self.highlightedNodeId = nil
            self.inConvMatches = []
            self.inConvMatchIndex = -1
            self.inConvSearchKeyword = ""
            self.pendingRefreshTask?.cancel()
            self.pendingRefreshTask = nil
            // 发送排队：不清的话 assistantTurnInFlight 卡 true，新楼层永远发不出消息；
            // pendingSends 持有旧楼层 ModelContext ref，必须一起丢
            self.assistantTurnInFlight = false
            self.pendingSends = []
            self.streamingNodeId = nil
            self.streamingConversationId = nil
            self.ccTurnConversationId = nil
            self.ccTurnNodeId = nil
        }
    }

    deinit {
        if let observer = profileSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Sidebar 重排 debounce
    /// 内容改动（发消息 / rename / 贴纸加删）后，连续 3 秒无新改动才触发一次 sidebar 重排。
    /// 目的：浏览/快速互动时列表不抖动；点击对话本身不触发（见 loadConversation）。
    /// 下拉刷新 / 切楼层 / 进后台 / 从聊天页切回 sidebar 时立即 flush。
    private var pendingRefreshTask: Task<Void, Never>?
    private let refreshDebounceNanoseconds: UInt64 = 3_000_000_000

    /// 标记有对话内容已改动，触发（或重置）3 秒 debounce。
    func markConversationDirty() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.refreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushPendingRefresh()
        }
    }

    /// 立刻触发 sidebar re-fetch，取消挂起的 debounce。
    func flushPendingRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        sidebarRefreshTrigger += 1
    }

    /// Effective children for each node — rebuilt from actual parent-child relationships
    var effectiveChildrenMap: [String: [String]] = [:]

    // MARK: - Chat (API) stored properties

    var providerRouter = ProviderRouter()
    let memoryStore: MemoryStore = SwiftDataMemoryStore()
    /// Content being streamed for the current assistant response
    var streamingText = ""
    /// Reasoning content being streamed (DeepSeek / models with reasoning_content)
    var streamingThinkingText: String = ""
    /// True while reasoning_content is arriving and before regular content starts
    var isThinking: Bool = false
    /// One-sentence summary generated after thinking completes; cleared on next send
    var thinkingSummary: String = ""
    /// Recent messages to send for memory extraction
    let memoryExtractWindow = 5

    // MARK: - Budget (保险闸)
    /// 被拦截时 UI 层通过这个显示 alert；UI 消掉后置 nil
    var budgetBlockedMessage: String? = nil
    /// Pre-send 的估算额度，发送完没 usage 时兜底扣费
    var pendingEstimatedCost: Double = 0
    /// 上一轮主对话的 token 用量（含 cache 命中数），S1 检查器显示用
    var lastTurnUsage: TokenUsage? = nil
    var turnStartTime: Date? = nil   // PR: Token 统计——记一轮耗时
}
