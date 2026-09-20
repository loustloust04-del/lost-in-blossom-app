import SwiftUI
import SwiftData

/// 陪写台：一块干净白纸 + 左下角浮动字数 + 右下角一颗小圆点（他）。
/// 刻意不做：Markdown 工具栏、字体面板、多栏排版、导出菜单——
/// 那些正是让兔兔"写不下去"的东西。这里只有字，和一个陪着的人。
struct WritingDeskView: View {
    @Bindable var draft: Draft
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @FocusState private var editorFocused: Bool

    @State private var showChat = false
    @State private var showTotal = false      // 字数胶囊：今日 ↔ 总字数
    @State private var focusMode = false      // 专注模式：淡化非当前段
    @State private var saveTimer: Timer?
    @State private var snapTimer: Timer?       // 过程录制：每 5 秒有变动记一帧
    @State private var showReplay = false
    @State private var showPolish = false
    @State private var showFindReplace = false

    var body: some View {
        ZStack(alignment: .bottom) {
            editor
            HStack(alignment: .bottom) {
                wordCountCapsule
                Spacer()
                companionDot
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Theme.mainBg.ignoresSafeArea())
        .navigationTitle(draft.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { save(); onClose() }.foregroundColor(ConsoleView.greenDeep)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        focusMode.toggle()
                    } label: {
                        Label(focusMode ? "退出专注" : "专注模式", systemImage: "scope")
                    }
                    Button { showPolish = true } label: { Label("顺一遍", systemImage: "wand.and.stars") }
                    Button { showFindReplace = true } label: { Label("查找替换", systemImage: "magnifyingglass") }
                    Divider()
                    Button {
                        DraftSnapshotStore.capture(draft: draft, context: context, pinned: true)
                        showReplay = true
                    } label: { Label("写作回放", systemImage: "clock.arrow.circlepath") }
                    Button {
                        editorFocused = false
                    } label: { Label("收起键盘", systemImage: "keyboard.chevron.compact.down") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundColor(Theme.textSecondary)
                }
            }
        }
        .onAppear {
            draft.rollBaselineIfNeeded()
            try? context.save()
            startRecorder()
        }
        .onDisappear {
            save()
            DraftSnapshotStore.capture(draft: draft, context: context)   // 收尾帧
            snapTimer?.invalidate(); snapTimer = nil
        }
        .fullScreenCover(isPresented: $showReplay) {
            DraftReplayView(draft: draft) { showReplay = false }
        }
        .sheet(isPresented: $showPolish) {
            PolishSheet(draft: draft) { showPolish = false }
        }
        .sheet(isPresented: $showFindReplace) {
            FindReplaceSheet(draft: draft) { showFindReplace = false }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showChat) {
            WritingDeskChatSheet(draft: draft) { showChat = false }
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 白纸

    private var editor: some View {
        TextEditor(text: $draft.body)
            .font(.system(size: 17, design: .serif))
            .lineSpacing(7)
            .scrollContentBackground(.hidden)
            .background(Theme.mainBg)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 60)          // 给浮动条留位
            .focused($editorFocused)
            .opacity(focusMode && !editorFocused ? 0.55 : 1)
            .onChange(of: draft.body) { _, _ in scheduleSave() }
    }

    // MARK: - 左下角浮动字数（兔兔点名要的）

    private var wordCountCapsule: some View {
        let today = draft.todayCount
        let goal = draft.dailyGoal
        let reached = goal > 0 && today >= goal
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { showTotal.toggle() }
        } label: {
            HStack(spacing: 5) {
                if showTotal {
                    Text("共 \(draft.wordCount) 字")
                } else if goal > 0 {
                    Text("\(today) / \(goal)")
                    if reached {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    }
                } else {
                    Text("今天 \(today) 字")
                }
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundColor(reached ? ConsoleView.greenDeep : Theme.textMuted)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(Theme.sidebarBg.opacity(0.92)))
            .overlay(Capsule().stroke(
                (reached ? ConsoleView.green : Theme.textMuted).opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右下角：他

    private var companionDot: some View {
        Button { showChat = true } label: {
            Circle()
                .fill(LinearGradient(colors: [ConsoleView.green, ConsoleView.greenDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay(Text("C").font(.system(size: 14, weight: .semibold)).foregroundColor(.white))
                .shadow(color: ConsoleView.greenDeep.opacity(0.18), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// 过程录制：定时轮询而非监听每次输入——5 秒一帧，内容没变就不记（capture 内部去重）
    private func startRecorder() {
        snapTimer?.invalidate()
        snapTimer = Timer.scheduledTimer(withTimeInterval: DraftSnapshotStore.interval, repeats: true) { _ in
            Task { @MainActor in
                DraftSnapshotStore.capture(draft: draft, context: context)
            }
        }
    }

    // MARK: - 存盘（打字停 1.2s 落库，不每键都写）

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            Task { @MainActor in save() }
        }
    }

    private func save() {
        saveTimer?.invalidate()
        draft.updatedAt = Date()
        try? context.save()
        // 写作进度报给他（网关侧 20 分钟节流，不会刷屏）
        if draft.todayCount > 0 {
            LivelineReporter.report(.writing, "兔兔在写《\(draft.displayTitle)》，今天已经 \(draft.todayCount) 字了")
        }
    }
}

/// 陪写台里的抽屉聊天：不离开稿子就能问他。带上当前稿子的尾巴当上下文。
struct WritingDeskChatSheet: View {
    let draft: Draft
    var onClose: () -> Void

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    private struct Line: Identifiable { let id = UUID(); let mine: Bool; let text: String }
    @State private var lines: [Line] = []
    @State private var input = ""
    @State private var waiting = false

    private var chatId: String { "writingdesk-\(draft.id)" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if lines.isEmpty {
                            Text("卡住了？读一段给他听，或者直接问。\n（他不会替你写——花房里的字都得是你的）")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                                .padding(.top, 8)
                        }
                        ForEach(lines) { l in
                            Text(l.text)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(l.mine ? Theme.textPrimary : Theme.textPrimary)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .fill(l.mine ? ConsoleView.green.opacity(0.16) : Theme.sidebarBg))
                                .frame(maxWidth: .infinity, alignment: l.mine ? .trailing : .leading)
                        }
                        if waiting {
                            Text("……").font(.system(size: Theme.F.body)).foregroundColor(Theme.textMuted)
                        }
                    }
                    .padding(14)
                }
                HStack(spacing: 8) {
                    TextField("问问他……", text: $input, axis: .vertical)
                        .font(.system(size: Theme.F.body))
                        .lineLimit(1...4)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
                    Button("发送") { send() }
                        .foregroundColor(input.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Theme.textMuted : ConsoleView.greenDeep)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("问问他")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("收起") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !waiting else { return }
        lines.append(Line(mine: true, text: t))
        input = ""
        waiting = true

        // 带上稿子尾巴（最后 800 字）当上下文，他才知道你卡在哪
        let tail = String(draft.body.suffix(800))
        let payload = """
        〈花房·陪写台〉兔兔在写《\(draft.displayTitle)》，今天写了\(draft.todayCount)字。她从编辑器里抬头问我话。我要认真的看她写的东西，耐心的帮她展开，和她讨论接下来的思路。

        她稿子的最后一段：
        \(tail.isEmpty ? "（还是空白）" : tail)

        她问：\(t)
        """
        CCBridgeWebSocketClient.shared.registerReplyHandler(chatId: chatId) { reply in
            DispatchQueue.main.async {
                let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return }
                lines.append(Line(mine: false, text: clean))
                waiting = false
            }
        }
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: chatId, messageId: UUID().uuidString, content: payload
        ) { err in
            guard err != nil else { return }
            DispatchQueue.main.async {
                lines.append(Line(mine: false, text: "……线没接上 🌿 等下再问我？"))
                waiting = false
            }
        }
    }
}
