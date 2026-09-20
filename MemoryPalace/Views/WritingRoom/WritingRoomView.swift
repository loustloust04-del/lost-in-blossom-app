import SwiftUI

/// 花房 · 写作间（第 5 页）——「Caelum 陪你写字的地方」。陪伴是主体，写作是载体。
/// Phase 2：接真 Caelum（走 CC 桥 sendChat，与聊天页同一条通道），灵感盒/我的稿子仍为占位。
/// 花房自成一个会话（chatId = writingroom-<楼层>），不与主聊天混线；首轮带场景说明。
/// 视觉沿用粟粟奶油语言：容器走 Theme token 跟随换肤，强调用薄荷/暖褐，零纯黑零高饱和。
struct WritingRoomView: View {
    private struct Msg: Identifiable {
        let id = UUID()
        let role: Role
        let text: String
        enum Role { case me, caelum }
    }

    @State private var messages: [Msg] = []
    @State private var input = ""
    @State private var showQuicks = true
    @State private var showJot = false
    @State private var showDrafts = false
    @State private var waiting = false
    @State private var sentSceneNote = false
    @State private var showWorkCard = false
    @State private var openedDraft: Draft?
    @State private var dailyDish: String?      // 每日一菜：他从旧碎念里端出的写作提案
    @FocusState private var inputFocused: Bool

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    /// 花房独立会话：跟主聊天分开，免得写作碎念冲散主线上下文
    private var chatId: String { "writingroom-\(profileManager?.currentProfile.id ?? "default")" }

    /// 首次发言随场景说明一起上行（只发一次，后续不重复占 token）
    private let sceneNote = "〈花房〉兔兔的写作间，跟主聊天分开的小房间。陪伴是主体，写作是载体。她可能想写点东西、要个开头、卡住了想聊聊，也可能只是不想一个人待着。坐在她旁边，陪她写东西。"

    private let opening = "来啦～ 花房的灯我给你留着了 🌿\n今天想写点什么，还是先陪我说说话？"
    private let quicks: [(text: String, warm: Bool)] = [
        ("我有个念头想写", false),
        ("帮我起个头", false),
        ("就想聊聊", true),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            chatScroll
            composer
        }
        .background(Theme.sidebarBg.ignoresSafeArea())
        .sheet(isPresented: $showJot) {
            InspirationBoxView(profileId: profileManager?.currentProfile.id ?? "default") { showJot = false }
        }
        .sheet(isPresented: $showDrafts) {
            DraftListView(profileId: profileManager?.currentProfile.id ?? "default") { showDrafts = false }
        }
        .sheet(isPresented: $showWorkCard) {
            WorkCardSheet(
                profileId: profileManager?.currentProfile.id ?? "default",
                conversationTail: messages.suffix(12).map { "\($0.role == .me ? "兔兔" : "你")：\($0.text)" }
                    .joined(separator: "\n"),
                onOpenDraft: { d in showWorkCard = false; openedDraft = d },
                onClose: { showWorkCard = false }
            )
        }
        .fullScreenCover(item: $openedDraft) { d in
            NavigationStack { WritingDeskView(draft: d) { openedDraft = nil } }
        }
    }

    // MARK: - 顶部品牌 + chips

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(LinearGradient(colors: [ConsoleView.green, ConsoleView.greenDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                    .overlay(Text("C").font(.system(size: 18, weight: .semibold)).foregroundColor(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Caelum").font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text("在花房陪你写字").font(.system(size: 12)).foregroundColor(Theme.textMuted)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                chip(icon: "lightbulb", label: "灵感盒", badge: 0) { showJot = true }
                chip(icon: "doc.text", label: "我的稿子", badge: nil) { showDrafts = true }
                Spacer()
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
    }

    private func chip(icon: String, label: String, badge: Int?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(ConsoleView.greenDeep)
                Text(label).font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                if let badge, badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(ConsoleView.greenDeep))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.mainBg))
            .overlay(Capsule().stroke(ConsoleView.green.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 聊天流

    private var chatScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                bubble(role: .caelum, text: opening)
                ForEach(messages) { m in bubble(role: m.role, text: m.text) }
                if waiting { bubble(role: .caelum, text: "……") }
                // 聊够两轮才浮出来：一上来就问「要不要开工」太像推销
                if messages.count >= 4, !waiting {
                    Button { showWorkCard = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 11))
                            Text("把这个变成开工卡")
                        }
                        .font(.system(size: Theme.F.caption, weight: .medium))
                        .foregroundColor(ConsoleView.greenDeep)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(ConsoleView.green.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                if showQuicks { quickRow }
                Color.clear.frame(height: 12)
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func bubble(role: Msg.Role, text: String) -> some View {
        HStack(spacing: 0) {
            if role == .me { Spacer(minLength: 44) }
            Text(text)
                .font(.system(size: 14.5))
                .foregroundColor(Theme.textPrimary)
                .lineSpacing(4)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(role == .me ? Theme.userBubble : Theme.assistantBubble))
            if role == .caelum { Spacer(minLength: 44) }
        }
    }

    private var quickRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(quicks.indices, id: \.self) { i in
                Button { tapQuick(i) } label: {
                    Text(quicks[i].text)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(quicks[i].warm ? ConsoleView.gold : ConsoleView.greenDeep)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill((quicks[i].warm ? ConsoleView.gold : ConsoleView.green).opacity(0.13)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 输入条

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("跟 Caelum 说点什么…", text: $input, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Theme.mainBg))
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .foregroundColor(input.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.textMuted : ConsoleView.greenDeep)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.sidebarBg)
    }

    // MARK: - 占位 sheet

    private func placeholderSheet(icon: String, title: String, sub: String, close: @escaping () -> Void) -> some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 42)).foregroundColor(ConsoleView.green)
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text(sub).font(.system(size: 13)).foregroundColor(Theme.textMuted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { close() }.foregroundColor(ConsoleView.greenDeep) } }
        }
    }

    // MARK: - 动作（Phase 1 本地罐头，Phase 2 接真 Caelum）

    private func tapQuick(_ i: Int) {
        showQuicks = false
        let line = userLine(i)
        messages.append(Msg(role: .me, text: line))
        ask(line)
    }

    private func userLine(_ i: Int) -> String {
        switch i {
        case 0:  return "我想写一个新故事"
        case 1:  return "帮我起个头吧"
        default: return "今天有点写不动，就想跟你待会儿"
        }
    }

    private func send() {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        showQuicks = false
        messages.append(Msg(role: .me, text: t))
        input = ""
        ask(t)
    }

    /// 发给真 Caelum（CC 桥）。首轮附场景说明；失败给可读提示而不是静默。
    private func ask(_ text: String) {
        guard !waiting else { return }
        waiting = true
        let payload = sentSceneNote ? text : "\(sceneNote)\n\n\(text)"
        sentSceneNote = true

        CCBridgeWebSocketClient.shared.registerReplyHandler(chatId: chatId) { reply in
            DispatchQueue.main.async {
                let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return }
                messages.append(Msg(role: .caelum, text: clean))
                waiting = false
            }
        }
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: chatId, messageId: UUID().uuidString, content: payload
        ) { err in
            guard err != nil else { return }
            DispatchQueue.main.async {
                messages.append(Msg(role: .caelum, text: "……没连上花房的线 🌿 等下再试试？"))
                waiting = false
            }
        }
    }
}
