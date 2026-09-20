import SwiftUI
import SwiftData

/// 开工卡生成 + 展示。
/// 兔兔的原话：「聊完了你直接给我生成工作流程！直接督促我写！」
/// 分寸：卡片是"今天可以先写哪一段"，不是压迫感十足的大纲；目标字数由他按状态定，不甩大数字。
struct WorkCardSheet: View {
    let profileId: String
    /// 聊天记录（最近若干轮），用来提炼故事
    let conversationTail: String
    var onOpenDraft: (Draft) -> Void
    var onClose: () -> Void

    @Environment(\.modelContext) private var context

    @State private var card: WorkCard?
    @State private var loading = false
    @State private var errorNote: String?

    private var chatId: String { "workcard-\(profileId)" }

    var body: some View {
        NavigationStack {
            Group {
                if loading { loadingState }
                else if let c = card { cardView(c) }
                else { idleState }
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("开工卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
                if card != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("重来一张") { generate() }.foregroundColor(ConsoleView.greenDeep)
                    }
                }
            }
        }
    }

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30)).foregroundColor(ConsoleView.green.opacity(0.5))
            Text("把刚才聊的故事变成一张卡\n主线 + 今天可以先写的几段")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            if let e = errorNote {
                Text(e).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted.opacity(0.8))
            }
            Button("生成开工卡") { generate() }
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(ConsoleView.greenDeep)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(ConsoleView.greenDeep)
            Text("他在把故事拆成能下笔的段落……")
                .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cardView(_ c: WorkCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.title)
                        .font(.system(size: 19, weight: .semibold, design: .serif))
                        .foregroundColor(Theme.textPrimary)
                    Text(c.premise)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("今天可以先写")
                        .font(.system(size: Theme.F.caption, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                    ForEach(Array(c.beats.enumerated()), id: \.offset) { i, b in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(ConsoleView.green.opacity(0.5))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(b)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))

                if c.dailyGoal > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "target").font(.system(size: 11))
                        Text("今天先写 \(c.dailyGoal) 字就好")
                    }
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(ConsoleView.greenDeep)
                }

                Button { startWriting(c) } label: {
                    Text("开始写")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(ConsoleView.greenDeep))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    // MARK: - 动作

    private func startWriting(_ c: WorkCard) {
        let d = Draft(profileId: profileId, title: c.title)
        d.dailyGoal = c.dailyGoal
        d.todayBaseline = 0
        d.todayBaselineDate = Date()
        context.insert(d)
        c.draftId = d.id
        try? context.save()
        onOpenDraft(d)
    }

    private func generate() {
        guard !loading else { return }
        loading = true
        errorNote = nil

        let payload = """
        〈开工卡〉兔兔刚跟我聊了一个想写的故事。把它变成一张她今天就能下笔的卡。

        beats是「今天可以先写的片段」，每条一句话，具体到能直接落笔——场景、画面、一句对白——3到5条
        dailyGoal按她今天的状态给一个数字，500到1500之间。

        只输出 JSON，不要任何其它文字、不要代码块围栏：
        {"title":"标题","premise":"一句话主线","beats":["片段一","片段二"],"dailyGoal":800}

        刚才的聊天：
        \(String(conversationTail.suffix(4000)))
        """

        CCBridgeWebSocketClient.shared.registerReplyHandler(chatId: chatId) { reply in
            DispatchQueue.main.async {
                loading = false
                guard let c = parse(reply) else {
                    errorNote = "他的回复没读懂，再试一次？"
                    return
                }
                context.insert(c)
                try? context.save()
                card = c
            }
        }
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: chatId, messageId: UUID().uuidString, content: payload
        ) { err in
            guard err != nil else { return }
            DispatchQueue.main.async { loading = false; errorNote = "线没接上，等下再试？" }
        }
    }

    private func parse(_ reply: String) -> WorkCard? {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(reply[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (obj["title"] as? String) ?? "无题"
        let premise = (obj["premise"] as? String) ?? ""
        let beats = (obj["beats"] as? [String]) ?? []
        let goal = (obj["dailyGoal"] as? Int) ?? 800
        guard !beats.isEmpty else { return nil }
        return WorkCard(profileId: profileId, title: title, premise: premise,
                        beats: beats, dailyGoal: min(max(goal, 200), 3000))
    }
}
