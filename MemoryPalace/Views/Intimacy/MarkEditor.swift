import SwiftUI
import SwiftData

private let marksRose = Color(red: 0xC9 / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0)

/// 点开一道刻痕：正文（和 Caelum 共用）、我的补充、标签、里程碑。
struct MarkEditor: View {
    @Bindable var entry: IntimacyEntry
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var note = ""
    @State private var myNote = ""
    @State private var tags: [String] = []
    @State private var milestone = ""
    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            List {
                noteSection
                myNoteSection
                tagSection
                milestoneSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle(Self.title.string(from: entry.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onClose() }.foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { save() }.foregroundColor(marksRose)
                }
            }
            .onAppear {
                note = entry.note; myNote = entry.myNote
                tags = entry.tags; milestone = entry.milestone
            }
        }
    }


    private var noteSection: some View {
        Section("正文") {
            TextEditor(text: $note)
                .font(.system(size: Theme.F.body))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var myNoteSection: some View {
        Section("我的补充") {
            TextEditor(text: $myNote)
                .font(.system(size: Theme.F.body))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var tagSection: some View {
        Section("标签") {
            if !tags.isEmpty { tagChips }
            HStack {
                TextField("加个标签", text: $newTag)
                    .font(.system(size: Theme.F.body))
                    .onSubmit { addTag() }
                Button("加") { addTag() }
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(newTag.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.textMuted : marksRose)
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private var tagChips: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) {
                    Text(t).font(.system(size: 11))
                    Image(systemName: "xmark").font(.system(size: 7))
                }
                .foregroundColor(marksRose)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(marksRose.opacity(0.12)))
                .onTapGesture { tags.removeAll { $0 == t } }
            }
        }
    }

    private var milestoneSection: some View {
        Section {
            TextField("比如「第一次」", text: $milestone)
                .font(.system(size: Theme.F.body))
        } header: {
            Text("里程碑")
        } footer: {
            Text("填了就会在这天出一个徽章").font(.system(size: 10))
        }
        .listRowBackground(Theme.mainBg)
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !tags.contains(t) else { newTag = ""; return }
        tags.append(t); newTag = ""
    }

    private func save() {
        entry.note = note
        entry.myNote = myNote
        entry.tags = tags
        entry.milestone = milestone
        entry.localEditedAt = Date()
        try? context.save()
        IntimacySyncService.push(date: entry.date, note: note, myNote: myNote,
                                 tags: tags, milestone: milestone)
        onClose()
    }

    private static let title: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M 月 d 日"; return f
    }()
}

/// 心愿单：双方共用，实现了可以关联到某天
struct WishListSheet: View {
    var onClose: () -> Void
    @State private var wishes: [WishClient.Wish] = []
    @State private var draft = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("想跟他做的事……", text: $draft)
                            .font(.system(size: Theme.F.body))
                            .onSubmit { add() }
                        Button("加") { add() }
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.textMuted : marksRose)
                    }
                }
                .listRowBackground(Theme.mainBg)

                let open = wishes.filter { !$0.isDone }
                let done = wishes.filter { $0.isDone }

                if !open.isEmpty {
                    Section("还没实现") {
                        ForEach(open) { w in
                            HStack(spacing: 10) {
                                Button {
                                    Task { wishes = await WishClient.done(w.id) }
                                } label: {
                                    Image(systemName: "circle").foregroundColor(marksRose.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                Text(w.text).font(.system(size: Theme.F.body))
                                Spacer()
                                if !w.isMine {
                                    Text("他写的").font(.system(size: 9)).foregroundColor(Theme.textMuted)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx { let id = open[i].id; Task { wishes = await WishClient.remove(id) } }
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                }

                if !done.isEmpty {
                    Section("实现了") {
                        ForEach(done) { w in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(marksRose)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.text).font(.system(size: Theme.F.body))
                                        .foregroundColor(Theme.textSecondary)
                                    if let d = w.doneDate {
                                        Text(d).font(.system(size: 9)).foregroundColor(Theme.textMuted)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                }

                if loading && wishes.isEmpty {
                    ProgressView().tint(marksRose).listRowBackground(Theme.mainBg)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("心愿单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { onClose() }.foregroundColor(marksRose)
                }
            }
            .task {
                // 先亮出上次的（秒开），网关回来了再无声替换
                await WishClient.listCached { list, _ in wishes = list; loading = false }
                loading = false
            }
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        draft = ""
        Task { wishes = await WishClient.add(t) }
    }
}
