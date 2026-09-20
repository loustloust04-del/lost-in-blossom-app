import SwiftUI

/// 输入框全屏展开编辑（兔兔 2026-08-24 提，参照 ChatGPT App 的展开输入）。
///
/// 细输入框最多 6 行，写长消息时看不全前文。展开后占满屏，配大字号与充足行距，
/// 收起或发送都回到聊天页。文本与外层同一个 Binding，展开期间的编辑照常触发
/// 草稿落盘（onChange(of: text) 在 InputFieldContainer 那侧仍然生效）。
struct ExpandedInputSheet: View {
    @Binding var text: String
    /// 返回 true 表示已发出（外层负责清空并收起）
    let onSend: () -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: Bool
    @AppStorage("fontScale") private var fontScale = 1.2

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：收起 | 字数 | 发送
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(text.count) 字")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted.opacity(0.7))

                Spacer()

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(canSend ? .white : Theme.textMuted.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? Theme.branchIndicator : Color.clear))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 8)

            Divider().opacity(0.12)

            // 正文：占满剩余空间
            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 15 * fontScale))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        .background(Theme.mainBg.ignoresSafeArea())
        .onAppear { focused = true }
    }
}
