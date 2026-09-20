import SwiftUI

/// R4 批注就地小窗：点正文划线 → 底部弹出（BookChatDrawer 同款 detents 手感），
/// 不用去左侧抽屉翻档案。重叠段命中多条就列多条；reply 串缩进跟随。
/// 删除守「不可删对方笔迹」（AI 卡无删除；含 AI reply 的串保护在父级 UI 挡）。
struct NoteQuickLookSheet: View {
    let noteIds: [String]
    let allNotes: [BookStore.Note]
    let assistantName: String

    var onReply: (BookStore.Note, String) -> Void
    var onDelete: (BookStore.Note) -> Void
    var onShowChat: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var replyingTo: BookStore.Note? = nil
    @State private var replyText = ""

    private var hitNotes: [BookStore.Note] {
        allNotes.filter { noteIds.contains($0.id) && $0.replyTo == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func replies(of note: BookStore.Note) -> [BookStore.Note] {
        allNotes.filter { $0.replyTo == note.id }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hitNotes, id: \.id) { note in
                    noteCard(note)
                    ForEach(replies(of: note), id: \.id) { reply in
                        replyRow(reply)
                            .padding(.leading, 16)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.mainBg)
        .presentationDetents([.height(360), .medium])
        .presentationDragIndicator(.visible)
        .alert("回复批注", isPresented: Binding(
            get: { replyingTo != nil },
            set: { if !$0 { replyingTo = nil } }
        )) {
            TextField("写点什么…", text: $replyText)
            Button("取消", role: .cancel) { replyingTo = nil }
            Button("回复") {
                let content = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parent = replyingTo, !content.isEmpty {
                    onReply(parent, content)
                }
                replyingTo = nil
            }
        }
    }

    // MARK: - 批注卡

    private func noteCard(_ note: BookStore.Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: kindIcon(note))
                    .font(.system(size: 11))
                    .foregroundColor(note.role == "ai" ? Color(hex: 0xC98A8A) : Theme.branchIndicator)
                Text(note.role == "ai" ? assistantName : kindLabel(note))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }

            if !note.anchorText.isEmpty {
                Text("「\(note.anchorText.prefix(100))\(note.anchorText.count > 100 ? "…" : "")」")
                    .font(.system(size: 12).italic())
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(4)
            }

            if note.kind != "highlight", !note.content.isEmpty {
                Text(note.content)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
            }

            HStack(spacing: 14) {
                smallButton("回复", icon: "arrowshape.turn.up.left") {
                    replyText = ""
                    replyingTo = note
                }
                if note.kind == "aiBubble", let mid = note.messageId, !mid.isEmpty {
                    smallButton("看完整对话", icon: "bubble.right") {
                        dismiss()
                        onShowChat(mid)
                    }
                }
                if note.role != "ai" {
                    smallButton("删除", icon: "trash", tint: Theme.danger) {
                        // 串里有 AI reply 的保护：有 → 不给删（同抽屉规则）
                        if replies(of: note).contains(where: { $0.role == "ai" }) { return }
                        onDelete(note)
                        dismiss()
                    }
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private func replyRow(_ note: BookStore.Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted)
                Text(note.role == "ai" ? assistantName : "你")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            Text(note.content)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.mainBg.opacity(0.8))
        )
    }

    private func smallButton(_ label: String, icon: String, tint: Color = Theme.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(tint)
        }
        .buttonStyle(.plain)
    }

    private func kindIcon(_ note: BookStore.Note) -> String {
        switch note.kind {
        case "highlight": return "highlighter"
        case "aiBubble":  return "bubble.left.fill"
        default:          return "note.text"
        }
    }

    private func kindLabel(_ note: BookStore.Note) -> String {
        note.kind == "highlight" ? "你的高亮" : "你的笔记"
    }
}
