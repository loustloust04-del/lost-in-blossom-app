import SwiftUI

/// 置顶消息条（10-05，照 Telegram / 粟粟 09-xx）：聊天页顶栏下面一条，显示钉住的消息；
/// 点一下跳过去，再点换更早的那条，循环。左边竖着的小段数表示一共钉了几条、现在是第几条。
struct PinnedBar: View {
    let pinned: [MessageNode]          // 按时间顺序（旧 → 新）
    let assistantName: String
    let onJump: (MessageNode) -> Void
    /// 现在显示第几条（0 = 最新的那条）
    @State private var cursor = 0

    private var current: MessageNode? {
        guard !pinned.isEmpty else { return nil }
        let i = min(cursor, pinned.count - 1)
        return pinned[pinned.count - 1 - i]
    }

    var body: some View {
        if let n = current {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onJump(n)
                withAnimation(.easeOut(duration: 0.2)) { cursor = (cursor + 1) % max(1, pinned.count) }
            } label: {
                HStack(spacing: 10) {
                    // 段数指示：最多画 4 段，当前段高亮
                    VStack(spacing: 2) {
                        let segs = min(4, pinned.count)
                        ForEach(0..<segs, id: \.self) { k in
                            Capsule()
                                .fill(k == (min(cursor, pinned.count - 1) % segs) ? Theme.branchIndicator : Theme.textMuted.opacity(0.3))
                                .frame(width: 2.5)
                        }
                    }
                    .frame(height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pinned.count > 1 ? "置顶消息 \(pinned.count - min(cursor, pinned.count - 1))/\(pinned.count)" : "置顶消息")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.branchIndicator)
                        Text(snippet(n))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pin.fill").font(.system(size: 11)).foregroundColor(Theme.textMuted).rotationEffect(.degrees(30))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.textMuted.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onChange(of: pinned.count) { _, _ in cursor = 0 }
        }
    }

    private func snippet(_ n: MessageNode) -> String {
        let raw = ContentCleaner.clean(String(n.content.prefix(300)))
        let body = n.role == "assistant" ? ContentCleaner.extractThinking(from: raw).content : raw
        let line = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (n.role == "assistant" ? "\(assistantName)：" : "我：") + line
    }
}
