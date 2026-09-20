// 从 SidebarView.swift 拆出：会话/收藏/回收站列表行 + 过滤 Chip

import SwiftUI
import SwiftData
import UniformTypeIdentifiers


// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    var showDivider: Bool = true
    var isFirst: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if conversation.kind == "group" {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                Text(conversation.title)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if conversation.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.favorite)
                }

                Text(conversation.updateTime.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                    .fixedSize()

                if conversation.nodeCount > 0 {
                    Text("\(conversation.nodeCount)")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.45) : Color.clear)
            )
            .padding(.horizontal, 4)

            if showDivider && !isSelected {
                Divider().opacity(0.15).padding(.leading, 16)
            }
        }
    }
}


// MARK: - Favorited Bubble Row

struct FavoritedBubbleRow: View {
    let node: MessageNode
    let convTitle: String
    let isSelected: Bool
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "Caelum"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: Theme.F.badge))
                .foregroundColor(Theme.favorite)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(convTitle)
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)

                Text(node.content.prefix(80).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }

            Spacer()

            Text(node.role == "user" ? userName : assistantName)
                .font(.caption2)
                .foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
        )
        .padding(.horizontal, 8)
    }
}


// MARK: - Deleted Bubble Row

struct DeletedBubbleRow: View {
    let node: MessageNode
    let convTitle: String
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "Caelum"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: Theme.F.badge))
                .foregroundColor(Theme.textMuted.opacity(0.6))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(convTitle)
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)

                Text(node.content.prefix(80).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }

            Spacer()

            Text(node.role == "user" ? userName : assistantName)
                .font(.caption2)
                .foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}
