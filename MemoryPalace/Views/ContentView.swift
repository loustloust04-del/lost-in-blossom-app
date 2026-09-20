import SwiftUI
import SwiftData
import UIKit
import VariableBlur

#if DEBUG
@MainActor enum PerfCounters {
    static var contentViewBody = 0
    static var chatInputBarBody = 0
    static var inputFieldBody = 0
    /// 上一次 ContentView.body 的订阅源快照，用于诊断 #N body 是哪个 source 变了
    static var lastContentViewSnapshot: [String: String] = [:]
}
#endif

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @State private var viewModel = ConversationViewModel()
    @Environment(GlobalWorldBookManager.self) private var globalWBManager: GlobalWorldBookManager?
    /// 路线 B 下 ContentView 订阅 ProfileManager 获取 currentProfile.id，用于给 @Query-backed
    /// sub-views (EmptyStateView 等) init(profileId:) 传值。由于 ProfileManager.switchTo
    /// 只改 currentProfile（container 不动），订阅 ProfileManager 触发的 body rebuild 不会
    /// 引发 SwiftData reset race，安全。原 master R1 revert 担心的是订阅 3 个 Manager 放大
    /// body 频次，这里只订阅 ProfileManager（currentProfile 变化频率极低）。
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    // ProviderManager / PresetManager 的 @Environment 订阅挪到
    // PagingContainerView（Representable 层），避免 ContentView.body 被这些 @Observable
    // Manager 的属性变化触发整体重算 + 被 updatePages 大锤放大到 ChatInputBar.body
    // （master R1 revert 原罪，见 docs/postmortem-kelivo-keyboard-wallpaper.md）。
    @Environment(RightPanelNavigator.self) private var rightPanelNavigator: RightPanelNavigator?
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var showTrash = false
    // 当前 iOS page：0=chat, 1=dashboard, 2=写作间（花房）。console/archive 两页 2026-08-12 删除（内容已并入主页/纯无用）。侧边栏走 ZStack overlay 不再是 paging page。@State 与 PagingContainerView.currentPage binding，
    // UIKit UIScrollView paging 完成后通过 binding 回写。
    @State private var iOSPage: Int = 0
    // iOSPageDragOffset removed — ScrollView handles drag natively
    @State private var isSidebarVisible = true
    /// Claude App 风格：侧边栏以 overlay 方式弹出，不再是 UIKit paging 的 page 0
    @State private var isSidebarOpen: Bool = false
    private let sidebarAnimation = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// 实时拖拽增量 (>0 = 向右拉开, <0 = 向左关闭)。@GestureState 在手势结束时自动归零。
    @GestureState private var sidebarLiveDrag: CGFloat = 0
    @State private var edgePanDrag: CGFloat = 0
    @State private var isRightPanelVisible = false
    /// 右滑页默认停在桌面（Console），而不是直接落进某个工具。
    /// 2026-08-24 兔兔定，对齐粟粟的 page2 逻辑：dock 最右 🏠 回桌面、平常停桌面。
    /// 「home」case 与 dock 键 07-09 afbec0f4 就做好了，只有这个默认值一直没改，
    /// 所以桌面态从来没被看见过。
    @State private var toolSelection = ToolSelection()
    @State private var stickerVM = StickerViewModel()
    @State private var isFullscreen = false
    @State private var isFullscreenTransitioning = false
    @State private var windowWidth: CGFloat = 1200
    @State private var suppressAutoCollapse = false
    @State private var isKeyboardVisible = false
    @State private var topSafeAreaInset: CGFloat = 59  // 默认 iPhone 常见值；onAppear 更新成 UIApplication 的真值
    // 聊天页 nav 菜单 / 重命名 / 改标签 状态
    @State private var showRenameAlert = false
    @State private var renameText: String = ""
    @State private var showChangeProjectSheet = false
    @State private var showContextSummarySheet = false
    @State private var showGroupMembersSheet = false
    // Pin Bar state（从 CardFlowView 挪上来，Phase 3 用）
    @State private var pinCurrentIndex: Int = 0
    @State private var pinBarHidden: Bool = false
    // 分支地图 sheet（B20 part 2 A3 反馈）
    @State private var showBranchMap = false
    @AppStorage("blurRadius") private var blurRadius = 1.3
    // pageIndicatorInZStack / debugPageIndicatorMode / @AppStorage debugPageIndicatorModeRaw
    // 全 dead code（pageIndicatorInZStack 无 call site）— 已删除以减少订阅 surface。
    @State private var calendarWidth: CGFloat = 300
    @State private var detailWidth: CGFloat = 600
    private let sidebarMinWidth: CGFloat = 250
    private let sidebarDefaultMaxWidth: CGFloat = 400
    private let contentMinWidth: CGFloat = 350
    private let calendarMinWidth: CGFloat = 250
    private let calendarPanelMaxWidth: CGFloat = 380
    private let dividerWidth: CGFloat = 8
    private let calendarCollapseThreshold: CGFloat = 900

    private var sidebarMaxWidth: CGFloat {
        guard isRightPanelVisible, !suppressAutoCollapse else { return sidebarDefaultMaxWidth }
        return min(
            sidebarDefaultMaxWidth,
            max(sidebarMinWidth, windowWidth - contentMinWidth - dividerWidth - calendarMinWidth)
        )
    }

    private var minimumDetailWidthForCalendar: CGFloat {
        contentMinWidth + dividerWidth + calendarMinWidth
    }

    /// 日历面板在当前可用空间下的最大宽度（确保内容区 >= 350）
    private func calendarMaxWidth(in availableWidth: CGFloat) -> CGFloat {
        min(calendarPanelMaxWidth, max(0, availableWidth - contentMinWidth - dividerWidth))
    }

    /// 日历面板的实际宽度
    private func effectiveCalendarWidth(in availableWidth: CGFloat) -> CGFloat? {
        let maxW = calendarMaxWidth(in: availableWidth)
        guard maxW >= calendarMinWidth else { return nil }
        return min(calendarWidth, maxW)
    }

    var body: some View {
        #if DEBUG
        // SwiftUI 暗器 _logChanges() — 让 SwiftUI runtime 自己 print "因为 X 改变所以重 eval"
        // （走 unified logging os_log，subsystem 大致是 com.apple.SwiftUI）。Hermes Q2 推荐
        // 用 newer variant 替代 _printChanges()。两者都是 underscore-prefixed 非 public API，
        // iOS 26 / macOS 14 deployment target 上 verified 可用，DEBUG only。
        // 若以后 Apple 改签名，build error → fallback Self._printChanges()。
        let _ = Self._printChanges()
        #endif
        let manager = themeManager ?? ThemeManager.shared
        let _ = manager.themeChangeID
        #if DEBUG
        // 订阅源 snapshot — 砍掉之前探针 observer effect 引入的字段（ContentView 生产代码
        // 不 read 这些 field，但探针 read 让 ContentView 订阅了它们 → 第三轮 log 看到的
        // sidebarRefresh / stickerCount 触发 body 是"假" hot path，是探针自己挑起的）。
        // 保留字段 = ContentView body 真实 read 的 source（grep 实证）：
        //   selectedConv / currentPath / isStreaming / pinnedNodes (= currentPath 衍生) /
        //   isEditingStickers / themeID / profileId / colorScheme + iOS-only iOSPage / isKeyboardVisible.
        // 删除（探针引入）：scrollToNode / highlightNode / streamingTextLen / sidebarRefresh /
        //   stickerCount / stickerSelected / stickerImporting / wbBooks / navTarget / bgMode(iOS).
        // 头号嫌疑根据 Hermes Q4 不再是 SwiftData @Model（per-keypath 应不 invalidate）。
        PerfCounters.contentViewBody += 1
        var _bodyProbeSnapshot: [String: String] = [
            "selectedConv": viewModel.selectedConversation?.id.prefix(8).description ?? "nil",
            "currentPath": "\(viewModel.currentPath.count)",
            "isStreaming": "\(viewModel.providerRouter.isStreaming)",
            "pinnedNodes": "\(viewModel.pinnedNodes.count)",
            "isEditingStickers": "\(stickerVM.isEditingStickers)",
            "themeID": manager.themeChangeID.uuidString.prefix(8).description,
            "profileId": profileManager?.currentProfile.id.prefix(8).description ?? "nil",
            "colorScheme": "\(colorScheme)",
        ]
        _bodyProbeSnapshot["iOSPage"] = "\(iOSPage)"
        _bodyProbeSnapshot["isKeyboardVisible"] = "\(isKeyboardVisible)"
        let _bodyProbeDiff = _bodyProbeSnapshot
            .filter { PerfCounters.lastContentViewSnapshot[$0.key] != $0.value }
            .map { "\($0.key): \(PerfCounters.lastContentViewSnapshot[$0.key] ?? "∅")→\($0.value)" }
            .sorted()
        PerfCounters.lastContentViewSnapshot = _bodyProbeSnapshot
        let _bodyProbeDiffStr = _bodyProbeDiff.isEmpty ? "(none — SwiftUI re-eval w/o source change?)" : _bodyProbeDiff.joined(separator: ", ")
        print(String(format: "[PERF] ContentView.body #%d t=%.3f Δ=%@",
                     PerfCounters.contentViewBody,
                     CFAbsoluteTimeGetCurrent(),
                     _bodyProbeDiffStr))
        #endif
        return ZStack {

            iOSLayout
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 路线 C：body.background 撤了。每页自己处理背景 + safe area 延伸：
        // - iOSListPage / iOSDashboardPage 各自 .background(color.ignoresSafeArea())
        // - iOSChatPage 内部 .background { ChatWallpaperBackdrop.ignoresSafeArea() } + topBar overlay
        // R1 revert (2026-04-19 perf)：原来这里有 scenePhase / profileManager 两个 onChange flush，
        // chat→sidebar 的 flush 已挪到 onChange(iOSPage) 里 (oldPage==1 && newPage==0 触发)。
        .overlay {
            // pageIndicator 挂 body overlay（Phase 2 v1 时在 iOSLayout 内，Phase 3 挪出来）。
            // 照搬 master：VStack+Spacer 推 HStack 到底，.ignoresSafeArea(.container, .bottom)
            // 漫到 home indicator 区，padding.bottom 15 让 HStack 落在 home indicator 中部。
            // 键盘弹出时隐藏避免贴键盘。
            if !isKeyboardVisible {
                VStack {
                    Spacer()
                    pageIndicatorDots
                        .padding(.bottom, 15)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showStickerLibrary)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                toolSelection.id = "sticker"
                isRightPanelVisible = true
            }
        }
        // 资源搜索点击 → SidebarView 设 navigator.pendingTarget → 这里协调打开右栏
        .onChange(of: rightPanelNavigator?.pendingTarget) { _, target in
            guard let t = target else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                toolSelection.id = t.tool
                iOSPage = 1
            }
        }
        .transaction { tx in
            tx.animation = nil
        }
        .onAppear {
            // CC Bridge: 启动时自动连接（baseURL 是内置常量 ws://127.0.0.1:7890/cc）
            if let url = URL(string: APIProvider.ccBridge.baseURL) {
                CCBridgeWebSocketClient.shared.connect(url: url)
            }
            manager.syncSystemColorScheme(colorScheme)
            let top = screenSafeAreaTop
            if top > 0 { topSafeAreaInset = top }

            #if DEBUG
            // [PROBE 贴纸] 自动选中 probe conversation + 进编辑模式（XCUITest 用）
            if ProbeStickerSeed.shouldAutoSelectProbeConv {
                PROBE("[PROBE 贴纸 ContentView.onAppear] auto-select probe conv")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let conv = ConversationListStore.conversation(id: "probe-sticker-conv-1", context: modelContext) {
                        viewModel.selectedConversation = conv
                        PROBE("[PROBE 贴纸 ContentView.onAppear] selected conv id=\(conv.id)")
                        // 等 5s 让 LazyVStack 渲染出 contentHeight，再进编辑模式
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            stickerVM.isEditingStickers = true
                            PROBE("[PROBE 贴纸 ContentView.onAppear] isEditingStickers=true")
                        }
                    } else {
                        PROBE("[PROBE 贴纸 ContentView.onAppear] probe conv NOT FOUND")
                    }
                }
            }
            #endif
        }
        .onChange(of: colorScheme) { _, newScheme in
            manager.syncSystemColorScheme(newScheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryPalaceRequestImport)) { _ in
            showImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestShowSettings)) { _ in
            showSettings = true
        }
        .sheet(isPresented: $showImporter) {
            ImportView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Theme.sidebarBg)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
    }

    // MARK: - iOS Layout：聊天+右栏 paging + Claude App 风格侧边栏 overlay
    private var iOSLayout: some View {
        let manager = themeManager ?? ThemeManager.shared
        let scheme = manager.activeScheme
        let style = manager.currentBackgroundStyle
        let wallpaperConfig = WallpaperConfig(
            fill: Theme.mainBg,
            imageURL: manager.currentBackgroundImageURL,
            saturation: 0.92,
            opacity: style.resolvedOpacity(for: scheme),
            offsetX: style.resolvedOffsetX,
            offsetY: style.resolvedOffsetY,
            gradientColors: wallpaperGradientColors(for: scheme)
        )

        return GeometryReader { geo in
            // 侧边栏宽度 = 屏宽 80%
            let sidebarWidth = geo.size.width * 0.8
            // 聊天界面最大右移距离 = 屏宽 78%
            let fullSlide: CGFloat = geo.size.width * 0.78
            // 当前聊天偏移（实时跟手）
            let targetOffset: CGFloat = isSidebarOpen ? fullSlide : 0
            let chatOffset = max(0, min(fullSlide, targetOffset + sidebarLiveDrag + edgePanDrag))
            // 插值比例 0…1
            let progress = fullSlide > 0 ? chatOffset / fullSlide : 0

            ZStack(alignment: .leading) {
                // ── 最底层：全屏背景色，填充聊天层缩小后露出的空白 ──
                Theme.sidebarBg
                    .ignoresSafeArea()

                // ── 底层：侧边栏（永远在这里，永远不动）──
                iOSListPage
                    .frame(width: sidebarWidth)

                // ── 上层：聊天界面（盖在侧边栏上面，向右推开露出侧边栏）──────────────
                ZStack {
                    PagingContainerView(
                        chatPage: AnyView(injectPagingEnv(iOSChatPage)),
                        dashPage: AnyView(injectPagingEnv(iOSDashboardPage)),
                        writingPage: AnyView(injectPagingEnv(iOSWritingPage)),
                        currentPage: $iOSPage,
                        disableScroll: stickerVM.isEditingStickers,
                        initialPage: 0,
                        wallpaper: wallpaperConfig,
                        isStreaming: viewModel.providerRouter.isStreaming,
                        pauseUpdates: progress > 0.01
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(progress < 0.1)
                    .onChange(of: iOSPage) { _, _ in HapticService.shared.navigation() }

                    // 聊天遮罩：侧边栏开时提示聊天区不可交互，点击关闭侧边栏
                    Color.black.opacity(0.28 * progress)
                        .ignoresSafeArea()
                        .allowsHitTesting(progress > 0.3)
                        .onTapGesture {
                            withAnimation(sidebarAnimation) { isSidebarOpen = false }
                        }
                }
                .background(Color(UIColor.systemBackground))
                // 核心视觉：缩小 + 圆角 + 右移，三者同步随 progress 插值
                .clipShape(RoundedRectangle(cornerRadius: 30 * progress))
                // 阴影挂在背景 shape 上而不是内容层：shape 阴影走 CA 解析快路径；
                // 原来 .shadow 直接作用于整棵聊天内容层 = 拖动每帧对全树高斯模糊（radius 20），
                // 聊天一长左滑就卡的另一半元凶。内容不透明，轮廓阴影视觉等效。
                .background(
                    RoundedRectangle(cornerRadius: 30 * progress)
                        .fill(Color(UIColor.systemBackground))
                        .shadow(color: .black.opacity(0.18 * progress), radius: 20, x: -6, y: 0)
                )
                .scaleEffect(1.0 - 0.08 * progress)
                .offset(x: chatOffset)
            }
            // spring 动画仅在 boolean 跳变时触发（手势跟手期间不添加动画）
            .animation(sidebarAnimation, value: isSidebarOpen)
            // 全局 toast（语音条生成提示等）：顶部居中，盖在所有页之上
            .overlay(alignment: .top) { GlobalToastOverlay() }
            // ── 手势：仅处理侧边栏已打开时的左滑关闭（打开由 UIScreenEdgePanGestureRecognizer 处理）
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .updating($sidebarLiveDrag) { value, state, _ in
                        guard isSidebarOpen else { return }
                        state = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard isSidebarOpen else { return }
                        let shouldClose = value.translation.width < -(sidebarWidth * 0.3)
                            || value.velocity.width < -500
                        if shouldClose {
                            withAnimation(sidebarAnimation) { isSidebarOpen = false }
                        }
                    }
            )
            .onReceive(NotificationCenter.default.publisher(for: .sidebarEdgePanChanged)) { notification in
                guard !isSidebarOpen,
                      let translation = notification.userInfo?["translation"] as? CGFloat else { return }
                edgePanDrag = max(0, translation)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sidebarEdgePanEnded)) { notification in
                guard let translation = notification.userInfo?["translation"] as? CGFloat,
                      let velocity = notification.userInfo?["velocity"] as? CGFloat else { return }
                let shouldOpen = !isSidebarOpen && (translation > sidebarWidth * 0.3 || velocity > 500)
                let shouldClose = isSidebarOpen && (translation < -(sidebarWidth * 0.3) || velocity < -500)
                withAnimation(sidebarAnimation) {
                    if shouldOpen { isSidebarOpen = true }
                    else if shouldClose { isSidebarOpen = false }
                    edgePanDrag = 0
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: iOSPage) { oldPage, newPage in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            // page 0 = chat, page 1 = dashboard (sidebar is ZStack overlay, not a paging page)
        }
        .onChange(of: isSidebarOpen) { _, open in
            // 从聊天切到侧边栏时立刻 flush 挂起的重排
            if open { viewModel.flushPendingRefresh() }
        }
        .onChange(of: stickerVM.isEditingStickers) { _, editing in
            setStickerEditScrollLock(editing)
        }
        .onChange(of: globalWBManager?.books.count) { _, _ in
            viewModel.globalWorldBookEntries = (globalWBManager?.enabledBooks ?? []).flatMap { $0.entries }
        }
        .onAppear {
            viewModel.globalWorldBookEntries = (globalWBManager?.enabledBooks ?? []).flatMap { $0.entries }
            autoCreateFirstConversationIfNeeded()
            // 冷启动点通知兜底：didReceive 的 post 可能早于本视图订阅，pending 里补跳转
            if let convId = LocalNotificationService.shared.consumePendingConversationId() {
                navigateToNotificationConversation(convId)
            }
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, newId in
            if newId != nil {
                withAnimation(sidebarAnimation) { isSidebarOpen = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationNavigationRequested)) { _ in
            if iOSPage != 0 { withAnimation { iOSPage = 0 } }
            withAnimation(sidebarAnimation) { isSidebarOpen = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notificationNavigationRequested)) { notification in
            guard let convId = notification.userInfo?["conversationId"] as? String else { return }
            _ = LocalNotificationService.shared.consumePendingConversationId()
            if let conv = ConversationListStore.conversation(id: convId, context: modelContext) {
                viewModel.selectedConversation = conv
                withAnimation { iOSPage = 0 }
                withAnimation(sidebarAnimation) { isSidebarOpen = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            CCBridgeWebSocketClient.shared.reconnectIfNeeded()
        }
    }

    /// UIViewControllerRepresentable 包的 UIHostingController 不自动继承 SwiftUI parent env，
    /// 显式把低频 env（modelContext / themeManager / globalWBManager）注入给每页。
    /// ProviderManager / ProfileManager / PresetManager 的注入**移到 PagingContainerView**
    /// 完成，避免 ContentView 订阅这 3 个 @Observable Manager 引起 body 全量重算。
    @ViewBuilder
    private func injectPagingEnv<V: View>(_ page: V) -> some View {
        let manager = themeManager ?? ThemeManager.shared
        if let wb = globalWBManager {
            page
                .environment(\.modelContext, modelContext)
                .environment(manager)
                .environment(wb)
                .environment(toolSelection)
        } else {
            page
                .environment(\.modelContext, modelContext)
                .environment(manager)
                .environment(toolSelection)
        }
    }

    /// 推送通知点击跳转：fetch 目标会话，完整加载消息树（loadConversation 会构建
    /// path / branch map；直接赋值 selectedConversation 会留下空白或上一会话的残留内容），
    /// 然后切到聊天页并收起侧边栏。
    private func navigateToNotificationConversation(_ convId: String) {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })
        guard let conv = try? modelContext.fetch(descriptor).first else { return }
        viewModel.loadConversation(conv, context: modelContext)
        withAnimation { iOSPage = 0 }
        withAnimation(sidebarAnimation) { isSidebarOpen = false }
    }

    /// Wallpaper overlay gradient 颜色（复刻 ChatWallpaperBackdrop.overlayColors），
    /// 按 colorScheme 区分明暗主题。SwiftUI ColorScheme → UIColor[]（UIKit 层消费）。
    private func wallpaperGradientColors(for scheme: ColorScheme) -> [UIColor] {
        if scheme == .dark {
            return [
                UIColor.black.withAlphaComponent(0.42),
                UIColor.black.withAlphaComponent(0.18),
                UIColor.black.withAlphaComponent(0.50)
            ]
        }
        return [
            UIColor.white.withAlphaComponent(0.18),
            UIColor.white.withAlphaComponent(0.04),
            UIColor.white.withAlphaComponent(0.24)
        ]
    }

    // MARK: - iOS Page indicator (debug-mode aware)

    /// 页面指示点：chat(0) / dashboard(1) / 花房(2)
    private var pageIndicatorDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(iOSPage == i ? Theme.branchIndicator : Theme.textMuted.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// 从 UIApplication 直接拿屏幕 key window 的 safe area bottom，
    /// 绕开「GeometryReader 在 safe area 内时 safeAreaInsets 归零」的坑。
    private var screenSafeAreaBottom: CGFloat {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return 0 }
        return window.safeAreaInsets.bottom
    }

    private var screenSafeAreaTop: CGFloat {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return 0 }
        return window.safeAreaInsets.top
    }

    // pageIndicatorInZStack(proxy:) 已删除 — dead code（无 call site）。
    // 同 删 @AppStorage debugPageIndicatorModeRaw / private var debugPageIndicatorMode。

    /// 聊天页顶栏：左箭头(page 0) + 中间 PinBar(有 pin 时) + 右侧加长胶囊(⋯ Menu + 右箭头 page 2)。
    /// 当前对话标题挪进 ⋯ Menu 的 header（原顶栏中间不再显示标题）。
    /// blur 层在 CardFlowView 的 overlay（z 顺序：blur < nav HStack < Menu popover）。
    private var iOSChatTopBar: some View {
        return ZStack(alignment: .top) {
            HStack(spacing: 8) {
                // 侧边栏按钮 → 打开 overlay 侧边栏
                Button {
                    withAnimation(sidebarAnimation) { isSidebarOpen = true }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .glassEffectCompat(tint: Color.white.opacity(0.15), interactive: true, in: Circle())
                }

                // 中间：PinBar（有 pin 时）或 Spacer。Phase 3 P3.9 会在这里挂 PinnedMessageBar。
                if viewModel.hasPinnedNodes, !pinBarHidden, viewModel.selectedConversation != nil {
                    PinnedMessageBar(
                        pinnedNodes: viewModel.pinnedNodes,
                        currentIndex: $pinCurrentIndex,
                        isHidden: $pinBarHidden,
                        onTap: handlePinBarTap,
                        onUnpinCurrent: handleUnpinCurrent,
                        onUnpinAll: {
                            viewModel.unpinAll()
                            pinCurrentIndex = 0
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    .animation(.easeInOut(duration: 0.25), value: viewModel.pinnedNodes.map(\.id))
                    .animation(.easeInOut(duration: 0.25), value: pinCurrentIndex)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    Spacer(minLength: 0)
                }

                // 右侧加长胶囊：[🌿N(可选)] + ⋯(Menu) + 右箭头(page 2)
                HStack(spacing: 0) {
                    // 分支地图按钮（B20 part 2 A3）：仅当对话有非主线分支时显示
                    if branchOffMainCount > 0 {
                        Button {
                            showBranchMap = true
                        } label: {
                            HStack(spacing: 3) {
                                Text("🌿")
                                    .font(.system(size: 13))
                                Text("\(branchOffMainCount)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .frame(height: 44)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                    }

                    Menu {
                        if let conv = viewModel.selectedConversation {
                            Section {
                                Text(conv.title)
                            }
                            if conv.kind == "group" {
                                Button {
                                    showGroupMembersSheet = true
                                } label: {
                                    Label("群成员", systemImage: "person.2")
                                }
                                if viewModel.assistantTurnInFlight {
                                    Button(role: .destructive) {
                                        viewModel.cancelAssistantTurn(context: modelContext)
                                    } label: {
                                        Label("停止回复", systemImage: "stop.circle")
                                    }
                                }
                            }
                            Button {
                                showChangeProjectSheet = true
                            } label: {
                                Label("改标签", systemImage: "tag")
                            }
                            Button {
                                conv.isFavorite.toggle()
                            } label: {
                                Label(conv.isFavorite ? "取消收藏" : "收藏",
                                      systemImage: conv.isFavorite ? "star.slash" : "star")
                            }
                            Button {
                                renameText = conv.title
                                showRenameAlert = true
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button {
                                showContextSummarySheet = true
                            } label: {
                                Label("上下文压缩", systemImage: "rectangle.compress.vertical")
                            }
                            Divider()
                            Button(role: .destructive) {
                                viewModel.softDeleteConversation(conv)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }

                    Button {
                        withAnimation { iOSPage = 1 }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .glassEffectCompat(tint: Color.white.opacity(0.15), interactive: true, in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .animation(.easeInOut(duration: 0.25), value: pinBarHidden)
        }
    }

    // MARK: - Pin Bar handlers（从 CardFlowView 挪上来，Phase 3）

    private func handlePinBarTap() {
        let pins = viewModel.pinnedNodes
        guard !pins.isEmpty else { return }
        let idx = min(pinCurrentIndex, pins.count - 1)
        let target = pins[idx]
        if viewModel.currentPath.contains(where: { $0.id == target.id }) {
            viewModel.scrollToNodeId = target.id
            viewModel.highlightedNodeId = target.id
            let targetId = target.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if viewModel.highlightedNodeId == targetId {
                    viewModel.highlightedNodeId = nil
                }
            }
        }
        pinCurrentIndex = (idx + 1) % pins.count
    }

    private func handleUnpinCurrent() {
        let pins = viewModel.pinnedNodes
        guard !pins.isEmpty else { return }
        let idx = min(pinCurrentIndex, pins.count - 1)
        let target = pins[idx]
        target.isPinned = false
        target.pinnedAt = nil
        if pinCurrentIndex >= pins.count - 1 {
            pinCurrentIndex = 0
        }
    }

    /// 侧边栏内容（overlay 版）：带背景色，整屏高度
    private var iOSListPage: some View {
        SidebarView(
            searchText: $searchText,
            showFavoritesOnly: $showFavoritesOnly,
            showTrash: $showTrash,
            showImporter: $showImporter,
            showSettings: $showSettings,
            viewModel: viewModel,
            profileId: profileManager?.currentProfile.id ?? ""
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebarBg.ignoresSafeArea())
    }

    private var iOSChatPage: some View {
        // wallpaper 已挪到 iOSLayout 外层（chat page child HC 之外）以避开键盘 safeArea 影响，
        // 这里不再挂 .background { ChatWallpaperBackdrop }。chat page ZStack 透明，让外层
        // wallpaper 透过来。
        ZStack(alignment: .top) {
            if viewModel.selectedConversation != nil {
                CardFlowView(viewModel: viewModel, stickerVM: stickerVM)
                    .transition(.opacity)
            } else {
                EmptyStateView(
                    showImporter: $showImporter,
                    profileId: profileManager?.currentProfile.id ?? "",
                    onCreateConversation: {
                        let pid = profileManager?.currentProfile.id ?? ""
                        let conv = viewModel.createNewConversation(title: "新对话", profileId: pid, context: modelContext)
                        viewModel.loadConversation(conv, context: modelContext)
                    }
                )
                .transition(.opacity)
            }
        }
        // 空状态 ↔ 聊天页 淡入淡出
        .animation(.easeInOut(duration: 0.25), value: viewModel.selectedConversation != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            iOSChatTopBar
        }
        // home indicator 区 hit shield 已挪到 UIKit 层（PagingViewController.homeIndicatorShield）。
        // SwiftUI overlay 在 child HC（clipsToBounds=true）+ chat 页 additionalSafeAreaInsets
        // 动态变化下命中条会漂，时灵时不灵。改 UIKit 顶层 UIView + window.safeAreaInsets.bottom
        // 命中链稳定。
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("确认") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let conv = viewModel.selectedConversation {
                    conv.title = trimmed
                    conv.updateTime = Date()
                    viewModel.markConversationDirty()
                }
            }
        }
        .sheet(isPresented: $showChangeProjectSheet) {
            if let conv = viewModel.selectedConversation {
                TagPickerPopover(
                    conversationId: conv.id,
                    profileId: profileManager?.currentProfile.id ?? ""
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.sidebarBg)
            }
        }
        .sheet(isPresented: $showContextSummarySheet) {
            ContextSummarySheet(viewModel: viewModel)
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showGroupMembersSheet) {
            if let conv = viewModel.selectedConversation {
                GroupMembersSheet(conversation: conv)
                    .presentationDetents([.large, .medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showBranchMap) {
            BranchMapSheet(
                viewModel: viewModel,
                onNavigateToNode: { nodeId in
                    if let conv = viewModel.selectedConversation {
                        viewModel.navigateToNode(nodeId: nodeId, conversation: conv, context: modelContext)
                    }
                }
            )
            .presentationBackground(Theme.sidebarBg)
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, _ in
            pinCurrentIndex = 0
            pinBarHidden = false
        }
    }

    /// 当前对话有多少条非主线分支（用于决定是否显示 🌿 按钮 + 角标 N）。
    /// 含嵌套分支（DFS 全树），跟 BranchMapSheet 显示口径一致。空则按钮隐藏。
    /// B20 part 2 A3 反馈 + 第二轮 1+2 修：count 跟 sheet list 自洽。
    private var branchOffMainCount: Int {
        // 读缓存而非每次 body 重跑 collectAllBranches() DFS（侧栏拖动每帧都会重算
        // ContentView.body，对话越长 DFS 越慢 = 左滑卡顿）。缓存在树结构变化处刷新。
        viewModel.cachedBranchOffMainCount
    }

    /// 右滑 page 2: 右栏插件系统
    private var iOSDashboardPage: some View {
        RightPanelView(viewModel: viewModel, stickerVM: stickerVM)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebarBg.ignoresSafeArea())
    }

    private var iOSWritingPage: some View {
        WritingRoomView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 编辑贴纸时彻底禁用所有滚动。路线 C 下水平 paging 已由 PagingContainerView.disableScroll
    /// 管（UIScrollView.isScrollEnabled），这里只管 chat page 内 CardFlowView 的竖直 ScrollView。
    /// （旧的 disableBounceInSubviews / findCollectionView 路线 C 下 TabView 没了，已删）
    private func setStickerEditScrollLock(_ editing: Bool) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        setAllScrollViewsEnabled(!editing, in: window)
    }

    private func setAllScrollViewsEnabled(_ enabled: Bool, in view: UIView) {
        if let scrollView = view as? UIScrollView {
            scrollView.isScrollEnabled = enabled
        }
        for subview in view.subviews {
            setAllScrollViewsEnabled(enabled, in: subview)
        }
    }

    /// 启动时若无任何对话则自动创建一条空对话，让用户直接进入聊天页面。
    private func autoCreateFirstConversationIfNeeded() {
        let pid = profileManager?.currentProfile.id ?? ""
        guard !pid.isEmpty else { return }
        guard !ConversationListStore.hasActiveConversations(profileId: pid, context: modelContext) else { return }
        let conv = viewModel.createNewConversation(title: "新对话", profileId: pid, context: modelContext)
        viewModel.loadConversation(conv, context: modelContext)
    }

    // MARK: - macOS Layout
    private var normalLayout: some View {
        NavigationSplitView {
            SidebarView(
                searchText: $searchText,
                showFavoritesOnly: $showFavoritesOnly,
                showTrash: $showTrash,
                showImporter: $showImporter,
                showSettings: $showSettings,
                viewModel: viewModel,
                profileId: profileManager?.currentProfile.id ?? ""
            )
            .navigationSplitViewColumnWidth(min: sidebarMinWidth, ideal: 300, max: sidebarMaxWidth)
        } detail: {
            detailContent
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, _ in }
    }

    private var detailContent: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if viewModel.selectedConversation != nil {
                    CardFlowView(viewModel: viewModel, stickerVM: stickerVM)
                } else {
                    EmptyStateView(showImporter: $showImporter, profileId: profileManager?.currentProfile.id ?? "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { detailWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in detailWidth = w }
            }
        )
    }

    private var rightPanelCornerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isRightPanelVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isRightPanelVisible ? Theme.branchIndicator : Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(Theme.mainBg.opacity(0.94))
                )
                .overlay(
                    Circle()
                        .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @Binding var showImporter: Bool
    let profileId: String
    /// iOS 专用：点击「开始新对话」时调用。macOS 下为 nil。
    var onCreateConversation: (() -> Void)? = nil
    @Query private var conversations: [Conversation]
    @AppStorage("userName") private var userName = "你"

    init(showImporter: Binding<Bool>, profileId: String, onCreateConversation: (() -> Void)? = nil) {
        self._showImporter = showImporter
        self.profileId = profileId
        self.onCreateConversation = onCreateConversation
        _conversations = Query(filter: #Predicate<Conversation> { $0.profileId == profileId })
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeGreet: String
        switch hour {
        case 0..<5:  timeGreet = "夜深了"
        case 5..<12: timeGreet = "早上好"
        case 12..<18: timeGreet = "下午好"
        default:     timeGreet = "晚上好"
        }
        return "\(timeGreet)，\(userName)"
    }

    @State private var greetingVisible = false

    var body: some View {
        // iOS：问候语设计（类 Claude App 空状态）
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Text("Lost in Blossom")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(greetingText)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.textSecondary)
                if let create = onCreateConversation {
                    Button(action: create) {
                        Text("开始新对话")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            // 问候语淡入 + 轻微上移
            .opacity(greetingVisible ? 1 : 0)
            .offset(y: greetingVisible ? 0 : 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                greetingVisible = true
            }
        }
        .onDisappear { greetingVisible = false }
    }
}

