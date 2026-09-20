import SwiftUI
import SwiftData

// MARK: - Right Panel (Tool-based Container)

struct RightPanelView: View {
    // 09-03：@Binding 换 env。selectedToolId 的所有权从 ContentView 搬到 ToolSelection，
    // 订阅落在 dash HC 内部，切工具只失效本视图一棵，不再引爆三页大锤。
    @Environment(ToolSelection.self) private var toolSel: ToolSelection?

    /// 只读投影；env 缺失时兜底 "home"（同仓库其它 @Environment 的防御性 optional 写法）
    private var selectedToolId: String { toolSel?.id ?? "home" }
    /// 常驻白名单：切走后仍值得付内存房租的「现场持有者」
    private static let residentWhitelist: Set<String> = ["browser", "ccTerminal"]

    /// 画面名单 = 白名单驻民 + 当前（当前若非驻民，切走即拆——粟粟式）
    private var displayIds: [String] {
        let cur = selectedToolId
        return visitedToolIds.contains(cur) ? visitedToolIds : visitedToolIds + [cur]
    }

    /// 静默门：isActive=false 时恒等（SwiftUI 跳过子树 diff），active 恒不等（正常更新）。
    /// 09-03：content 从 `AnyView` 改成**惰性闭包**。旧版 `AnyView(panelView(id))` 是构造
    /// 参数，在造 gate 那一刻就求值了——`.equatable()` 只能短路 body，短路不了参数构造，
    /// 于是每次 body 跑都把 7 个面板全 init 一遍（ConsoleView 带 7 个 @Query）。
    /// 改闭包后：短路 ⇒ body 不跑 ⇒ 闭包不调用 ⇒ panelView(id) 根本不执行。
    /// 对照组：粟粟 upstream/master 裸 switch 每次只构造 1 个面板，所以她不卡。
    private struct CachedPanelGate<Content: View>: View, Equatable {
        let id: String
        let isActive: Bool
        let content: () -> Content

        init(id: String, isActive: Bool, @ViewBuilder content: @escaping () -> Content) {
            self.id = id
            self.isActive = isActive
            self.content = content
        }

        static func == (l: Self, r: Self) -> Bool { !l.isActive && !r.isActive && l.id == r.id }
        var body: some View { content() }
    }

    /// 冷启动缓存：去过的面板 id（首帧种子在 onAppear 里种）
    @State private var visitedToolIds: [String] = []
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        // 2026-08-24 兔兔定：工具 bar 从顶部移到底部当 dock（照粟粟 06-06 那刀）。
        // 拇指够得着，且顶部让给内容。
        // 用 safeAreaInset(.bottom) 而非把 ToolBarView 放进 VStack 末尾——
        // inset 会把安全区让给面板内容，内容滚到底时不会被 dock 盖住。
        //
        // 同时去掉切工具时的 phaseAnimator 回弹（连同 bounceTrigger）：
        // 那个 scaleEffect 0.995 会在缩放瞬间露出背景、且切换手感发卡，
        // 粟粟同刀也删了它，原话「缩放露背景+卡」。
        // ── 六渡（09-02，五渡侦察定罪）────────────────────────────────
        // 探针铁证：切一次工具 i+1 a+1（整棵重建+重新出现）、c/t 恒 0（onChange 从未跑）、
        // 绿豆不动（@State 每次归零）。真凶：safeAreaInset 挂在 switch(ConditionalContent)
        // 上，换枝时连同 inset 内容整体 remount——四种动画机制全靠的「上一帧记忆」每次
        // 都被清空。唯一会动的「影子」是 onAppear 补飞（40ms 后错位归位），所以怪。
        // 修：拿 ZStack 当身份稳定的底座包住 switch——换枝发生在 ZStack **里面**，
        // inset 的 ToolBarView 从此常驻不再重建。粟粟同款结构能动，就是这一层的差别。
        ZStack {
            ForEach(displayIds, id: \.self) { id in
                // 兔兔 09-02 二报：养了几个面板后回聊天页打字卡——每次键击 ContentView
                // 重算→rootView 重挂→所有活面板陪跑 diff。静默门：隐藏面板等价短路
                // （Equatable 恒等→SwiftUI 跳过其子树 diff），键击成本回到单面板级。
                CachedPanelGate(id: id, isActive: id == selectedToolId) { panelView(id) }
                    .equatable()
                    .opacity(id == selectedToolId ? 1 : 0)
                    .allowsHitTesting(id == selectedToolId)
            }
        }
        .onChange(of: selectedToolId) { _, new in
            // 兔兔 09-03 终局口供「512 完全体仍打字卡」→ 重新定案：刀1刀2 已把计算
            // 成本砍到底还卡 = 凶手是**内存**。7 个重面板全常驻（浏览器内核上百兆）
            // 把 iOS 18 老机的 RAM 塞爆，键盘一来系统拆墙。回看她最早的口供
            // 「加载过就不卡」——那时还是裸架构！暖的是**服务层缓存**（不随视图拆），
            // 房间重盖本就毫秒级。正解=选择性保命：只有真持有「现场」的两位
            // （浏览器网页/终端会话）值得付房租，其余回归粟粟式切走即拆。
            if Self.residentWhitelist.contains(new), !visitedToolIds.contains(new) {
                visitedToolIds.append(new)
            }
        }
        .onAppear {
            if visitedToolIds.isEmpty, Self.residentWhitelist.contains(selectedToolId) {
                visitedToolIds = [selectedToolId]
            }
        }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ToolBarView(selectedToolId: Binding(
                    get: { toolSel?.id ?? "home" },
                    set: { toolSel?.id = $0 }
                ))
                    .background(Theme.sidebarBg)
                    .zIndex(selectedToolId == "calendar" ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebarBg)
    }

    /// 兔兔 09-02 亲手定位的冷启动惩罚：面板切走就拆、切回重盖，重面板
    /// （浏览器/音乐/刻痕）首次构建的几百毫秒里动画卡、点击被吞——「都加载过
    /// 就不卡了」。解法照她说的：**去过的面板留着**（visited 缓存 + 透明度切换），
    /// 每个面板一生只冷启动一次；切换从「拆盖」变「淡入淡出」，顺带永久加固
    /// 六渡的身份稳定。代价：常驻内存随去过的面板数上涨，浏览器/终端保活反而是福利。
    @ViewBuilder
    private func panelView(_ id: String) -> some View {
        switch id {
        case "home":
            ConsoleView()
        case "calendar":
            CalendarPanelView(viewModel: viewModel, profileId: profileManager?.currentProfile.id ?? "")
        case "memory":
            // PR-3: 本地记忆 / 网关记忆 双轨容器（MemoryPanelView 本体未改）
            MemoryDualTrackView(viewModel: viewModel)
        case "worldBook":
            WorldBookPanelView()
        case "cardLibrary":
            CardLibraryPanelView()
        case "sticker":
            StickerLibraryView(viewModel: viewModel, stickerVM: stickerVM)
        case "prompt":
            PersonaSettingsTab(useSheetNavigation: true)
        case "ccTerminal":
            CCTerminalPanelView(viewModel: viewModel)
        case "fileLibrary":
            FileLibraryPanelView()
        case "browser":
            BrowserView()
        case "reading":
            ReadingPanelView()
        case "health":
            HealthPanelView(profileId: profileManager?.currentProfile.id ?? "")
        case "music":
            MusicPanelView(profileId: profileManager?.currentProfile.id ?? "")
        case "marks":
            MarksPanelView(profileId: profileManager?.currentProfile.id ?? "")
        default:
            Text("未知工具")
                .foregroundColor(Theme.textMuted)
        }
    }
}

// MARK: - Memory Panel

struct MemoryPanelView: View {
    var viewModel: ConversationViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    @State private var memories: [Memory] = []
    @State private var showAddInput = false
    @State private var newMemoryText = ""
    @State private var newMemoryCategory = "fact"
    @State private var highlightedId: String? = nil

    private let store = SwiftDataMemoryStore()
    private let categories = [
        ("fact", "事实"), ("preference", "偏好"), ("relationship", "关系"),
        ("goal", "目标"), ("context", "情境")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Stats header
            memoryHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)

            // Memory list
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    let grouped = groupedMemories
                    if !grouped.hot.isEmpty {
                        sectionHeader("活跃", count: grouped.hot.count, color: Color(hex: 0xD4A574))
                        ForEach(grouped.hot, id: \.id) { mem in
                            memoryRowWithHighlight(mem)
                        }
                    }
                    if !grouped.warm.isEmpty {
                        sectionHeader("休眠", count: grouped.warm.count, color: Theme.branchIndicator)
                            .padding(.top, grouped.hot.isEmpty ? 0 : 8)
                        ForEach(grouped.warm, id: \.id) { mem in
                            memoryRowWithHighlight(mem)
                        }
                    }
                    if !grouped.cold.isEmpty {
                        sectionHeader("将忘", count: grouped.cold.count, color: Color(red: 0.6, green: 0.65, blue: 0.7))
                            .padding(.top, (grouped.hot.isEmpty && grouped.warm.isEmpty) ? 0 : 8)
                        ForEach(grouped.cold, id: \.id) { mem in
                            memoryRowWithHighlight(mem)
                        }
                    }

                    if memories.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "brain")
                                .font(.system(size: 24))
                                .foregroundColor(Theme.textMuted.opacity(0.4))
                            Text("还没有记忆")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textMuted)
                            Text("和{{char}}聊天时会自动记住重要的事".expandingMacros(profile: profileManager?.currentProfile))
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .onAppear { consumeTarget(navigator?.pendingTarget, proxy: proxy) }
            .onChange(of: navigator?.pendingTarget) { _, target in
                consumeTarget(target, proxy: proxy)
            }
            } // end ScrollViewReader

            Spacer(minLength: 0)

            // Add memory input
            if showAddInput {
                addMemoryInput
            }

            // Bottom: add button + token bar
            VStack(spacing: 6) {
                if !showAddInput {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showAddInput = true } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text("添加记忆")
                                .font(.system(size: Theme.F.secondary))
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(.plain)
                }

                tokenBudgetBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { refreshMemories() }
        // 切楼层前清空 memories，避免 @State 里持有旧 store 的 Memory 实例让 body
        // 在 container reset 后访问失效实例。Plan: docs/plan-profile-switch-atomic.md
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            memories = []
        }
    }

    // MARK: - Header

    private var memoryHeader: some View {
        HStack(spacing: 8) {
            let grouped = groupedMemories
            HStack(spacing: 4) {
                Circle().fill(Color(hex: 0xD4A574)).frame(width: 6, height: 6)
                Text("\(grouped.hot.count)")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Theme.branchIndicator).frame(width: 6, height: 6)
                Text("\(grouped.warm.count)")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color(red: 0.6, green: 0.65, blue: 0.7)).frame(width: 6, height: 6)
                Text("\(grouped.cold.count)")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Text("\(memories.count) 条")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - Navigation Target Consumer

    private func consumeTarget(_ target: RightPanelNavigator.Target?, proxy: ScrollViewProxy) {
        guard let t = target, t.tool == "memory" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(t.id, anchor: .center)
            }
        }
        highlightedId = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlightedId == t.id { highlightedId = nil }
        }
        navigator?.pendingTarget = nil
    }

    // MARK: - Memory Row With Highlight

    @ViewBuilder
    private func memoryRowWithHighlight(_ mem: Memory) -> some View {
        let idStr = mem.id.uuidString
        MemoryCardView(
            memory: mem,
            effectiveWeight: effectiveWeight(mem),
            onPin: { togglePin(mem) },
            onDelete: { deleteMemory(mem) },
            onRevive: mem.supersededAt != nil ? { reviveMemory(mem) } : nil,
            onJumpToSource: mem.sourceConversationId != nil ? { jumpToSource(mem) } : nil
        )
        .id(idStr)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(highlightedId == idStr ? Theme.branchIndicator.opacity(0.35) : Color.clear)
                .animation(.easeInOut(duration: 0.35), value: highlightedId)
        )
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Token Budget

    private var tokenBudgetBar: some View {
        let totalTokens = memories.filter { effectiveWeight($0) >= 0.3 || $0.isUserExplicit }
            .reduce(0) { $0 + $1.tokenCount }
        let budget = 2000
        let ratio = min(1.0, Double(totalTokens) / Double(budget))

        return VStack(spacing: 2) {
            HStack {
                Text("\(totalTokens) / \(budget) tokens")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.3))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.branchIndicator.opacity(0.6))
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: - Add Memory

    private var addMemoryInput: some View {
        VStack(spacing: 6) {
            TextField("输入要记住的事...", text: $newMemoryText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.body))
                .lineLimit(4)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.mainBg)
                )

            HStack(spacing: 6) {
                Picker("", selection: $newMemoryCategory) {
                    ForEach(categories, id: \.0) { cat in
                        Text(cat.1).tag(cat.0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: Theme.F.secondary))

                Spacer()

                Button("取消") {
                    withAnimation { showAddInput = false; newMemoryText = "" }
                }
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
                .buttonStyle(.plain)

                Button("添加") {
                    addMemory()
                }
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.mainBg.opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.accent.opacity(0.72), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 1)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Data

    private var groupedMemories: (hot: [Memory], warm: [Memory], cold: [Memory]) {
        var hot: [Memory] = []
        var warm: [Memory] = []
        var cold: [Memory] = []
        for mem in memories {
            let w = effectiveWeight(mem)
            if mem.isUserExplicit || w >= 0.3 {
                hot.append(mem)
            } else if w >= 0.05 {
                warm.append(mem)
            } else {
                cold.append(mem)
            }
        }
        return (hot, warm, cold)
    }

    private func effectiveWeight(_ memory: Memory) -> Double {
        DecayEngine.effectiveWeight(memory)
    }

    private func refreshMemories() {
        let profileId = profileManager?.currentProfile.id ?? ""
        memories = (try? store.listAll(profileId: profileId, context: modelContext)) ?? []
    }

    private func togglePin(_ memory: Memory) {
        store.togglePin(memory, touchUpdatedAt: true, context: modelContext)
        refreshMemories()
    }

    private func deleteMemory(_ memory: Memory) {
        store.delete(memory, context: modelContext)
        refreshMemories()
    }

    private func reviveMemory(_ memory: Memory) {
        store.revive(memory, context: modelContext)
        refreshMemories()
    }

    /// 出处跳转（SC-B2 v1）：跳到源对话，不定位消息（消息级定位等 B23 修好一起做）
    private func jumpToSource(_ memory: Memory) {
        guard let cid = memory.sourceConversationId else { return }
        let pid = profileManager?.currentProfile.id ?? ""
        if let conv = ConversationListStore.conversation(id: cid, profileId: pid, context: modelContext) {
            viewModel.loadConversation(conv, context: modelContext)
        }
    }

    private func addMemory() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let profileId = profileManager?.currentProfile.id ?? ""
        store.addUserPinned(
            content: text,
            category: newMemoryCategory,
            keywords: text.components(separatedBy: .whitespaces).filter { $0.count > 1 },
            profileId: profileId,
            context: modelContext
        )

        newMemoryText = ""
        withAnimation { showAddInput = false }
        refreshMemories()
    }
}

// MARK: - Memory Card

struct MemoryCardView: View {
    let memory: Memory
    let effectiveWeight: Double
    var isFlashing: Bool = false
    var onPin: () -> Void
    var onDelete: () -> Void
    var onRevive: (() -> Void)? = nil          // 已失效记忆的复活（SC-B2）
    var onJumpToSource: (() -> Void)? = nil    // 出处跳转源对话（SC-B2）

    @State private var isHovering = false
    @State private var breathPhase: Double = 0
    @State private var flashOpacity: Double = 0

    private let categoryLabels: [String: String] = [
        "preference": "偏好", "fact": "事实", "relationship": "关系",
        "goal": "目标", "context": "情境"
    ]

    // Opacity: 0.25 (dead) to 1.0 (fresh)；已失效统一灰显
    private var baseOpacity: Double {
        if memory.supersededAt != nil { return 0.45 }
        return memory.isUserExplicit ? 1.0 : (0.25 + 0.75 * effectiveWeight)
    }

    // Breath: stronger memories breathe faster and more visibly
    private var breathAmplitude: Double { 0.03 * effectiveWeight }
    private var breathPeriod: Double { 3.0 + (1.0 - effectiveWeight) * 4.0 }

    // Border color: warm amber(1.0) → mint(0.5) → cool grey(0.0)
    private var borderColor: Color {
        if memory.isUserExplicit { return Color(hex: 0xD4A574) }
        if effectiveWeight > 0.5 {
            let t = (effectiveWeight - 0.5) * 2  // 0→1
            return blend(Theme.branchIndicator, Color(hex: 0xD4A574), t: t)
        } else {
            let t = effectiveWeight * 2  // 0→1
            return blend(Color(red: 0.6, green: 0.65, blue: 0.7), Theme.branchIndicator, t: t)
        }
    }

    private var borderWidth: CGFloat {
        if effectiveWeight > 0.3 { return 3 }
        if effectiveWeight > 0.05 { return 2 }
        return 1
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left border
            RoundedRectangle(cornerRadius: 1.5)
                .fill(borderColor)
                .frame(width: borderWidth)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                // Content
                Text(memory.content)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(4)

                // 出处行（SC-B2）：有 quote 显示，可点跳源对话（v1 跳对话不定位消息）
                if let quote = memory.sourceQuote {
                    Button { onJumpToSource?() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 7))
                            Text(quote)
                                .font(.system(size: Theme.F.caption))
                                .lineLimit(1)
                        }
                        .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(onJumpToSource == nil)
                }

                // Meta row
                HStack(spacing: 6) {
                    // Category tag
                    Text(categoryLabels[memory.category] ?? memory.category)
                        .font(.system(size: Theme.F.badge, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Theme.branchIndicator.opacity(0.12))
                        )

                    // Access info
                    Text("\(memory.accessCount)次")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)

                    Text(relativeDate(memory.lastAccessedAt))
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)

                    Spacer()

                    // 已失效标记（SC-B2）
                    if memory.supersededAt != nil {
                        Text("已失效")
                            .font(.system(size: Theme.F.badge))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().stroke(Theme.textMuted.opacity(0.5), lineWidth: 0.5))
                    }

                    // Pin icon
                    if memory.isUserExplicit {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Color(hex: 0xD4A574))
                    }

                    Menu {
                        Button(memory.isUserExplicit ? "取消钉住" : "钉住", action: onPin)
                        if memory.supersededAt != nil, let onRevive {
                            Button("复活", action: onRevive)
                        }
                        Button("删除", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }

                // Decay bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.accent.opacity(0.2))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(borderColor.opacity(0.5))
                            .frame(width: geo.size.width * effectiveWeight)
                    }
                }
                .frame(height: 2)
            }
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.mainBg.opacity(0.6))
        )
        // Phosphor flash overlay
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0xD4A574).opacity(flashOpacity))
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(baseOpacity + breathAmplitude * breathPhase)
        .blur(radius: effectiveWeight < 0.1 && !memory.isUserExplicit ? 1.5 : 0)
        .onHover { isHovering = $0 }
        .onAppear {
            withAnimation(
                .easeInOut(duration: breathPeriod)
                .repeatForever(autoreverses: true)
            ) {
                breathPhase = 1
            }
        }
        .onChange(of: isFlashing) { _, flashing in
            if flashing {
                withAnimation(.easeIn(duration: 0.2)) { flashOpacity = 0.4 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.6)) { flashOpacity = 0 }
                }
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let days = Int(-date.timeIntervalSinceNow / 86400)
        if days == 0 { return "今天" }
        if days == 1 { return "昨天" }
        if days < 30 { return "\(days)天前" }
        return "\(days / 30)月前"
    }

    /// Simple color blend between two colors
    private func blend(_ a: Color, _ b: Color, t: Double) -> Color {
        // Use opacity-based approximation since Color doesn't expose components easily
        // At t=0 → a, at t=1 → b
        return t > 0.5 ? b.opacity(1.0) : a.opacity(1.0)
    }
}
