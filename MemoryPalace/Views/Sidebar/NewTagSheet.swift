// 从 SidebarView.swift 拆出：标签新建 Sheet + 标签拖拽排序

import SwiftUI
import SwiftData
import UniformTypeIdentifiers


// MARK: - New Tag Sheet

struct NewTagSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    let profileId: String
    @Query private var tags: [ConversationTag]
    @State private var name = ""
    @State private var emoji = "🏷"

    init(profileId: String) {
        self.profileId = profileId
        _tags = Query(
            filter: #Predicate<ConversationTag> { $0.profileId == profileId },
            sort: \ConversationTag.order
        )
    }

    private let emojis = ["🏷", "⭐", "❤️", "💡", "🎯", "📝", "🔖", "💎", "🌸", "🎪", "🏠", "🌙"]

    var body: some View {
        VStack(spacing: 16) {
            Text("新建标签")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                ForEach(emojis, id: \.self) { e in
                    Button(action: { emoji = e }) {
                        Text(e)
                            .font(.title3)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(emoji == e ? Theme.accent : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            TextField("标签名称", text: $name)
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.3)))

            HStack {
                Button("取消") { dismiss() }
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button("创建") {
                    guard !name.isEmpty else { return }
                    let tag = ConversationTag(name: name, emoji: emoji, order: tags.count, profileId: profileId)
                    ConversationListStore.insertTag(tag, context: modelContext)
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}


// MARK: - Tag Reorder Drop Delegate

struct TagReorderDropDelegate: DropDelegate {
    let targetTagId: String
    let tags: [ConversationTag]
    let modelContext: ModelContext
    @Binding var draggingTagId: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingTagId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let fromId = draggingTagId, fromId != targetTagId else { return }
        reorder(fromId: fromId, toId: targetTagId)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool { true }

    private func reorder(fromId: String, toId: String) {
        var sorted = tags.sorted { $0.order < $1.order }
        guard let fromIdx = sorted.firstIndex(where: { $0.id == fromId }),
              let toIdx = sorted.firstIndex(where: { $0.id == toId }) else { return }
        let moving = sorted.remove(at: fromIdx)
        sorted.insert(moving, at: toIdx)
        for (i, tag) in sorted.enumerated() {
            tag.order = i
        }
        ConversationListStore.persist(context: modelContext)
    }
}
