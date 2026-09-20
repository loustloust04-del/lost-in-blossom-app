import SwiftUI
import SwiftData

/// 灵感盒（flomo 式无压记录）：一个输入框 + 倒序卡片流 + #标签筛选。
/// 刻意不做的：标题、分类、排版工具、富文本——记录要像呼吸一样没有阻力。
/// 我们比 flomo 多的：每张卡片落库后推给服务器笔记本，Caelum 随时能读能引用。
struct InspirationBoxView: View {
    let profileId: String
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var allNotes: [InspirationNote]

    @State private var draft = ""
    @State private var activeTag: String? = nil
    @State private var editing: InspirationNote? = nil
    @FocusState private var inputFocused: Bool

    private var notes: [InspirationNote] {
        allNotes
            .filter { $0.profileId == profileId }
            .filter { activeTag == nil || $0.tags.contains(activeTag!) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 出现过的标签，按使用频次降序（高频的先给你点）
    private var tagChips: [String] {
        var count: [String: Int] = [:]
        for n in allNotes where n.profileId == profileId {
            for t in n.tags { count[t, default: 0] += 1 }
        }
        return count.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                composer
                if !tagChips.isEmpty { tagRow }
                cardList
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("灵感盒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
            .sheet(item: $editing) { note in
                InspirationEditSheet(note: note) { editing = nil }
            }
        }
    }

    // MARK: - 无压输入

    private var composer: some View {
        VStack(spacing: 8) {
            TextField("随手记点什么…… 打 # 可以加标签", text: $draft, axis: .vertical)
                .font(.system(size: Theme.F.body))
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(ConsoleView.green.opacity(inputFocused ? 0.35 : 0.15), lineWidth: 1))

            HStack {
                Text(draft.isEmpty ? "写完按「记下」，不用起标题" : "\(draft.count) 字")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button("记下") { save() }
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Theme.textMuted : ConsoleView.greenDeep)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 标签行

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", active: activeTag == nil) { activeTag = nil }
                ForEach(tagChips, id: \.self) { t in
                    chip(title: "#\(t)", active: activeTag == t) {
                        activeTag = (activeTag == t) ? nil : t
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 10)
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(active ? .white : Theme.textSecondary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(active ? ConsoleView.greenDeep : Theme.mainBg))
                .overlay(Capsule().stroke(ConsoleView.green.opacity(active ? 0 : 0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 卡片流

    private var cardList: some View {
        Group {
            if notes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 30))
                        .foregroundColor(ConsoleView.green.opacity(0.5))
                    Text(activeTag == nil ? "还没有碎念\n想到什么就往上面丢一句" : "这个标签下还没有")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(notes) { n in card(n) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func card(_ n: InspirationNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(n.text)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(Self.stamp.string(from: n.createdAt))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                if n.syncedAt != nil {
                    Image(systemName: "leaf")
                        .font(.system(size: 9))
                        .foregroundColor(ConsoleView.green.opacity(0.7))
                }
                Spacer()
                ForEach(n.tags.prefix(3), id: \.self) { t in
                    Text("#\(t)")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(ConsoleView.greenDeep.opacity(0.75))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
        .contentShape(Rectangle())
        .onTapGesture { editing = n }
        .contextMenu {
            Button { editing = n } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) {
                context.delete(n); try? context.save()
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    // MARK: - 动作

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let note = InspirationNote(profileId: profileId, text: t)
        context.insert(note)
        try? context.save()
        draft = ""
        inputFocused = false
        Task { await InspirationSync.push(note: note, context: context) }
        LivelineReporter.report(.note, "兔兔在灵感盒记了一条：\(t.prefix(60))")
    }
}

/// 卡片编辑（改正文即重算标签）
struct InspirationEditSheet: View {
    @Bindable var note: InspirationNote
    var onClose: () -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $note.text)
                    .font(.system(size: Theme.F.body))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
                    .padding(14)
                Spacer()
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("编辑碎念")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        note.tags = InspirationNote.parseTags(from: note.text)
                        note.updatedAt = Date()
                        note.syncedAt = nil          // 改过就重推，笔记本里保持最新
                        try? context.save()
                        Task { await InspirationSync.push(note: note, context: context) }
                        onClose()
                    }
                    .foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }
}
