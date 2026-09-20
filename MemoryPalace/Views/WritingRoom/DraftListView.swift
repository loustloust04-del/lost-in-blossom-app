import SwiftUI
import SwiftData

/// 我的稿子：列表 + 新建。极简到只有标题、字数、最后写的时间。
struct DraftListView: View {
    let profileId: String
    var onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var allDrafts: [Draft]
    @State private var opened: Draft?

    private var drafts: [Draft] {
        allDrafts.filter { $0.profileId == profileId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 30))
                            .foregroundColor(ConsoleView.green.opacity(0.5))
                        Text("还没有稿子\n开一张白纸吧")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                        Button("开一张白纸") { newDraft() }
                            .font(.system(size: Theme.F.body, weight: .medium))
                            .foregroundColor(ConsoleView.greenDeep)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(drafts) { d in
                            Button { opened = d } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(d.displayTitle)
                                        .font(.system(size: Theme.F.body, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                    HStack(spacing: 8) {
                                        Text("\(d.wordCount) 字")
                                        Text(Self.stamp.string(from: d.updatedAt))
                                        if d.todayCount > 0 {
                                            Text("今天 +\(d.todayCount)")
                                                .foregroundColor(ConsoleView.greenDeep.opacity(0.8))
                                        }
                                    }
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.mainBg)
                        }
                        .onDelete { idx in
                            for i in idx { context.delete(drafts[i]) }
                            try? context.save()
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("我的稿子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newDraft() } label: { Image(systemName: "square.and.pencil") }
                        .foregroundColor(ConsoleView.greenDeep)
                }
            }
            .navigationDestination(item: $opened) { d in
                WritingDeskView(draft: d) { opened = nil }
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    private func newDraft() {
        let d = Draft(profileId: profileId)
        context.insert(d)
        try? context.save()
        opened = d
    }
}
