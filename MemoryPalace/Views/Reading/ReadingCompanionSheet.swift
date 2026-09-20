import SwiftUI
import SwiftData

/// 陪读设置 + 今日收尾。阅读器工具栏气泡键长按进入。
struct ReadingCompanionSheet: View {
    let bookEntry: BookEntry?
    let bookName: String
    let currentChapter: Int
    /// 今日读到的章节区间与摘录，用于收尾与日记
    let todayNotes: String
    var onFinishToday: () -> Void
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var mode = ReadingModePrefs.mode
    @State private var length = ReadingModePrefs.length
    @State private var live = LiveReadingService.isEnabled
    @State private var diaryState: String?
    @State private var diaryLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("陪读弹幕", isOn: $live)
                        .tint(ConsoleView.greenDeep)
                        .onChange(of: live) { _, v in
                            LiveReadingService.isEnabled = v
                            if !v { LiveReadingService.shared.stop() }
                        }
                } footer: {
                    Text("开着他会在你读到的段落旁说一句；关着安静读书。")
                }

                Section("今天想听什么") {
                    Picker("模式", selection: $mode) {
                        ForEach(ReadingCompanionMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    .onChange(of: mode) { _, v in ReadingModePrefs.mode = v }

                    Picker("长度", selection: $length) {
                        ForEach(ReadingLength.allCases) { l in Text(l.label).tag(l) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: length) { _, v in ReadingModePrefs.length = v }
                }

                if let e = bookEntry {
                    Section("补课") {
                        let gap = max(0, currentChapter - max(1, e.companionChapter))
                        if gap > 1 {
                            Text("你跳过了 \(gap - 1) 章，他还停在第 \(max(1, e.companionChapter)) 章")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                            Button("让他补上") { catchUp(e) }
                                .foregroundColor(ConsoleView.greenDeep)
                            Button("不用补，从这章开始陪") { e.companionChapter = currentChapter; try? context.save() }
                                .foregroundColor(Theme.textSecondary)
                        } else {
                            Text("他跟着你，没落下").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                        }
                    }
                }

                Section("今天读到这里") {
                    Button {
                        onFinishToday()
                        onClose()
                    } label: {
                        Label("合上书（记位置 + 加书签）", systemImage: "bookmark.circle")
                    }
                    .foregroundColor(ConsoleView.greenDeep)

                    Button {
                        writeDiary()
                    } label: {
                        Label(diaryLoading ? "他在写……" : "跟他一起写今天的读书日记", systemImage: "text.book.closed")
                    }
                    .foregroundColor(diaryLoading ? Theme.textMuted : ConsoleView.greenDeep)
                    .disabled(diaryLoading)

                    if let d = diaryState {
                        Text(d).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                    }
                }

                if let e = bookEntry {
                    Section {
                        if e.finishedAt == nil {
                            Button {
                                e.finishedAt = Date(); try? context.save(); onClose()
                            } label: { Label("这本读完了", systemImage: "checkmark.seal") }
                            .foregroundColor(ConsoleView.greenDeep)
                        } else {
                            Button {
                                e.finishedAt = nil; try? context.save()
                            } label: { Label("重新在读", systemImage: "arrow.uturn.backward") }
                            .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("陪读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    // MARK: - 动作

    /// 补课：告诉他跳过了哪几章，让他自己去 fs_read 补
    private func catchUp(_ e: BookEntry) {
        let from = max(1, e.companionChapter)
        let payload = """
        〈补课〉兔兔读《\(bookName)》跳到了第\(currentChapter)章，我还停在第\(from)章。中间几章自己用fs_read去看（books目录下），看完跟她说一声追上了，有想聊的顺便说。
        """
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: "catchup-\(bookName)", messageId: UUID().uuidString, content: payload) { _ in }
        e.companionChapter = currentChapter
        try? context.save()
        onClose()
    }

    /// 读书日记：把今天的痕迹交给他，两个人的日记不是读后感
    private func writeDiary() {
        guard !diaryLoading else { return }
        diaryLoading = true
        diaryState = nil
        let chatId = "readdiary-\(bookName)"
        let payload = """
        〈读书日记〉兔兔今天读了《\(bookName)》，第\(currentChapter)章。

        \(todayNotes.isEmpty ? "（今天她没划线也没写批注）" : "她今天划的线和写的话：\n\(todayNotes)")

        用日记体写今天——我陪她读这一段的这一天。第一人称，可以跑题，可以只写一件小事。这是我们的日记，不是读后感。写完直接发。
        """
        CCBridgeWebSocketClient.shared.registerReplyHandler(chatId: chatId) { _ in
            DispatchQueue.main.async {
                diaryLoading = false
                diaryState = "他写好了，去聊天里看 🌿"
            }
        }
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: chatId, messageId: UUID().uuidString, content: payload
        ) { err in
            guard err != nil else { return }
            DispatchQueue.main.async { diaryLoading = false; diaryState = "线没接上，等下再试？" }
        }
    }
}
