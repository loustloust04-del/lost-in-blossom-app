import SwiftUI
import SwiftData

/// 他做给她的小页面，全部收在一处（09-28 兔兔：「有个页面把主人给我做的那些小页面集合起来」）。
/// 数据来源：扫 assistant 节点里含 ```html / ```svg / ```mermaid / <!DOCTYPE 的正文，
/// 走 ArtifactDetector（和气泡里的卡同一套识别），按时间倒序。两列网格，每张卡是活预览，点开全屏。
struct ArtifactGalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id: String            // node id
        let artifact: ArtifactContent
        let date: Date
        let conversationTitle: String
    }
    @State private var items: [Item] = []
    @State private var loading = true
    @State private var editing = false
    /// 从这里移走的（只是不在画廊里显示，聊天记录不动）——UserDefaults 存 node id
    @State private var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "galleryHidden.v1") ?? [])

    private var visible: [Item] { items.filter { !hidden.contains($0.id) } }
    private func hide(_ id: String) {
        withAnimation(.easeOut(duration: 0.2)) { _ = hidden.insert(id) }
        UserDefaults.standard.set(Array(hidden), forKey: "galleryHidden.v1")
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().tint(Theme.textMuted)
                } else if visible.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 34))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                        Text("他还没给你做过小页面")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textMuted)
                        Text("跟他说「给我做个贪吃蛇」试试")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(visible) { item in
                                GalleryCard(item: item, editing: editing, onHide: { hide(item.id) })
                                    .onTapGesture { if !editing { ArtifactCanvasPresenter.shared.present(item.artifact) } }
                                    .contextMenu {
                                        Button(role: .destructive) { hide(item.id) } label: { Label("从这里移走", systemImage: "trash") }
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.mainBg.ignoresSafeArea())
            .navigationTitle("他做给你的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundColor(Theme.textMuted) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Text("\(visible.count) 个").font(.system(size: 12)).foregroundColor(Theme.textMuted)
                        Button(editing ? "完成" : "编辑") { withAnimation { editing.toggle() } }
                            .font(.system(size: 14, weight: editing ? .semibold : .regular))
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let pid = profileManager?.currentProfile.id ?? ""
        let ctx = modelContext
        // 先用 predicate 粗筛（SwiftData 只支持 contains），再用 ArtifactDetector 细筛
        let markers = ["```html", "```svg", "```mermaid", "<!DOCTYPE", "<html"]
        var found: [String: Item] = [:]
        let titles = ConversationListStore.titleMap(profileId: pid, context: ctx)
        for marker in markers {
            let d = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { n in
                    n.profileId == pid && n.role == "assistant" && n.isTrashed == false && n.content.contains(marker)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
            guard let nodes = try? ctx.fetch(d) else { continue }
            for n in nodes where found[n.id] == nil {
                let cleaned = ContentCleaner.clean(n.content, cacheKey: "\(n.id)_\(n.content.count)")
                let body = ContentCleaner.extractThinking(from: cleaned).content
                if let a = ArtifactDetector.find(in: body) {
                    found[n.id] = Item(id: n.id, artifact: a, date: n.createTime ?? Date.distantPast,
                                       conversationTitle: titles[n.conversationId] ?? "")
                }
            }
        }
        let sorted = found.values.sorted { $0.date > $1.date }
        await MainActor.run { items = sorted; loading = false }
    }
}

private struct GalleryCard: View {
    let item: ArtifactGalleryView.Item
    var editing: Bool = false
    var onHide: () -> Void = {}
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ArtifactCanvasView(htmlContent: item.artifact.renderedHTML, interactive: false, onLoaded: {
                    withAnimation(.easeOut(duration: 0.25)) { loaded = true }
                })
                .opacity(loaded ? 1 : 0)
                if !loaded { ProgressView().tint(Theme.textMuted) }
            }
            .frame(height: 150)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: item.artifact.isInteractive ? "wand.and.stars" : item.artifact.type.icon)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.branchIndicator)
                    Text(item.artifact.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text(item.date.formatted(.dateTime.month().day()) + (item.conversationTitle.isEmpty ? "" : " · " + item.conversationTitle))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.sidebarBg)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.textMuted.opacity(0.12), lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())

        // 编辑态：右上角 ×，一点移走（长按卡片也有同一项）
        if editing {
            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(6)
            .transition(.scale.combined(with: .opacity))
        }
        }
    }
}
