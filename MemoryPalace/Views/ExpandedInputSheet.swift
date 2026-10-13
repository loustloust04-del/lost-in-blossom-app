import SwiftUI
import UIKit

/// 输入框「放大」全屏写（10-07 照粟粟 InputExpandSheet 对齐）：
/// 顶栏 × + 标题 + 右上角缩小钮（和输入框里放大钮同一个位置——点开在哪、收起也在哪）；
/// 正文用自持 UITextView：组字（拼音没上屏）时不回写 binding——粟粟 09-09 定罪 TextEditor 是 IME 竞态位，
/// 「整句打完选字变回拼音」就是它；底部右下角发送。
struct ExpandedInputSheet: View {
    @Binding var text: String
    let onSend: () -> Void
    let onDismiss: () -> Void
    @AppStorage("fontScale") private var fontScale = 1.2

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("写长一点").font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textPrimary)
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.textMuted.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            IMESafeTextView(text: $text, font: .systemFont(ofSize: 15 * fontScale))
                .padding(.horizontal, 12)

            HStack {
                Text("\(text.count) 字").font(.system(size: 12)).foregroundColor(Theme.textMuted.opacity(0.7))
                Spacer()
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(canSend ? .white : Theme.textMuted.opacity(0.55))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Theme.branchIndicator : Theme.textMuted.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.mainBg.ignoresSafeArea())
    }
}

/// 组字安全的多行输入：拼音还在组（markedTextRange != nil）时不把半截写回 binding，
/// 外部改 text 时也不在组字中途覆盖
struct IMESafeTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = font
        tv.backgroundColor = .clear
        tv.textColor = UIColor(Theme.textPrimary)
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        tv.delegate = context.coordinator
        tv.text = text
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        DispatchQueue.main.async { tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        guard tv.markedTextRange == nil, tv.text != text else { return }
        tv.text = text
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IMESafeTextView
        init(_ p: IMESafeTextView) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            guard tv.markedTextRange == nil else { return }   // 组字中不回写
            if parent.text != tv.text { parent.text = tv.text }
        }
        func textViewDidEndEditing(_ tv: UITextView) {
            if parent.text != tv.text { parent.text = tv.text }
        }
    }
}
