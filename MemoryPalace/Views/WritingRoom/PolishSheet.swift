import SwiftUI
import SwiftData

/// 顺一遍：把稿子交给 Caelum 校对，返回逐条建议，每条单独采纳/忽略。
/// 铁律：**不允许一键覆盖全文**，也不做风格改写或续写——
/// 花房里的字必须是兔兔自己的，他只挑错别字、标点、重复用词、明显病句。
struct PolishSheet: View {
    @Bindable var draft: Draft
    var onClose: () -> Void

    @Environment(\.modelContext) private var context

    struct Fix: Identifiable, Codable {
        var id: String { original + "→" + suggestion }
        let original: String       // 原文片段（用于定位替换）
        let suggestion: String     // 改成什么
        let why: String            // 一句话理由
        let kind: String           // 错别字 / 标点 / 重复 / 病句
    }

    @State private var fixes: [Fix] = []
    @State private var applied: Set<String> = []
    @State private var ignored: Set<String> = []
    @State private var loading = false
    @State private var errorNote: String?

    private var chatId: String { "polish-\(draft.id)" }
    private var pending: [Fix] { fixes.filter { !applied.contains($0.id) && !ignored.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if loading { loadingState }
                else if let e = errorNote { errorState(e) }
                else if fixes.isEmpty { idleState }
                else { list }
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("顺一遍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
                if !fixes.isEmpty && !loading {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("再顺一遍") { run() }.foregroundColor(ConsoleView.greenDeep)
                    }
                }
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 30)).foregroundColor(ConsoleView.green.opacity(0.5))
            Text("让他挑一遍错别字、标点和重复用词\n每条你自己决定改不改")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button("开始") { run() }
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(ConsoleView.greenDeep)
                .padding(.top, 4)
            Text("他不会改你的写法，只挑硬伤")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted.opacity(0.7))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(ConsoleView.greenDeep)
            Text("他在读你的稿子……").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ e: String) -> some View {
        VStack(spacing: 10) {
            Text(e).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
            Button("再试一次") { run() }.foregroundColor(ConsoleView.greenDeep)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            if pending.isEmpty {
                Text("都处理完啦 🌿")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            }
            ForEach(pending) { f in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(f.kind)
                            .font(.system(size: 10))
                            .foregroundColor(ConsoleView.greenDeep)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(ConsoleView.green.opacity(0.16)))
                        Spacer()
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Text(f.original)
                            .strikethrough(color: .red.opacity(0.5))
                            .foregroundColor(Theme.textMuted)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(Theme.textMuted)
                        Text(f.suggestion).foregroundColor(Theme.textPrimary)
                    }
                    .font(.system(size: Theme.F.body))
                    if !f.why.isEmpty {
                        Text(f.why).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                    }
                    HStack(spacing: 14) {
                        Button("采纳") { apply(f) }
                            .font(.system(size: Theme.F.caption, weight: .medium))
                            .foregroundColor(ConsoleView.greenDeep)
                        Button("忽略") { ignored.insert(f.id) }
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.mainBg)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 动作

    private func apply(_ f: Fix) {
        guard let r = draft.body.range(of: f.original) else {
            ignored.insert(f.id)          // 原文已变，跳过
            return
        }
        draft.body.replaceSubrange(r, with: f.suggestion)
        draft.updatedAt = Date()
        try? context.save()
        applied.insert(f.id)
        // 采纳即记一帧，回放里能看到"这里顺过一遍"
        DraftSnapshotStore.capture(draft: draft, context: context, pinned: true)
    }

    private func run() {
        guard !loading else { return }
        let text = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { errorNote = "稿子还是空的"; return }
        loading = true
        errorNote = nil
        fixes = []; applied = []; ignored = []

        let payload = """
        〈校对〉兔兔的稿子。只挑硬伤：错别字、标点误用、语法错误。我只抓错。

        只输出一个 JSON 数组，不要任何其它文字、不要代码块围栏：
        [{"original":"原文片段","suggestion":"改成","why":"一句话理由","kind":"错别字|标点|重复|病句"}]
        original 必须是稿子里**一字不差**能找到的短片段（尽量短，10 字以内最好），否则无法定位。
        没有硬伤就输出[]。

        稿子：
        \(String(text.prefix(6000)))
        """

        CCBridgeWebSocketClient.shared.registerReplyHandler(chatId: chatId) { reply in
            DispatchQueue.main.async {
                loading = false
                guard let parsed = parse(reply) else {
                    errorNote = "他的回复没读懂，再试一次？"
                    return
                }
                fixes = parsed
                if parsed.isEmpty { errorNote = "没挑出硬伤，写得挺干净 🌿" }
            }
        }
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: chatId, messageId: UUID().uuidString, content: payload
        ) { err in
            guard err != nil else { return }
            DispatchQueue.main.async { loading = false; errorNote = "线没接上，等下再试？" }
        }
    }

    /// 从回复里抠出 JSON 数组（容忍前后废话和 ``` 围栏）
    private func parse(_ reply: String) -> [Fix]? {
        guard let start = reply.firstIndex(of: "["),
              let end = reply.lastIndex(of: "]"), start < end else { return nil }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Fix].self, from: data)
    }
}

/// 查找替换：常规工具，但支持"整篇换人名"这种一次到位的操作
struct FindReplaceSheet: View {
    @Bindable var draft: Draft
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var find = ""
    @State private var replace = ""
    @State private var done: Int?

    private var hits: Int {
        guard !find.isEmpty else { return 0 }
        return draft.body.components(separatedBy: find).count - 1
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("查找", text: $find)
                    TextField("替换为", text: $replace)
                } footer: {
                    Text(find.isEmpty ? "整篇替换，比如把人名一次改掉" : "找到 \(hits) 处")
                        .font(.system(size: Theme.F.caption))
                }
                Section {
                    Button("全部替换") { runReplace() }
                        .foregroundColor(hits > 0 ? ConsoleView.greenDeep : Theme.textMuted)
                        .disabled(hits == 0)
                    if let d = done {
                        Text("已替换 \(d) 处").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("查找替换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    private func runReplace() {
        let n = hits
        guard n > 0 else { return }
        DraftSnapshotStore.capture(draft: draft, context: context, pinned: true)  // 替换前留一帧，可回溯
        draft.body = draft.body.replacingOccurrences(of: find, with: replace)
        draft.updatedAt = Date()
        try? context.save()
        DraftSnapshotStore.capture(draft: draft, context: context, pinned: true)
        done = n
    }
}
