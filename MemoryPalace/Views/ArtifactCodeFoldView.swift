import SwiftUI

/// 可折叠的代码块展示。默认折叠，点击标题栏展开查看代码。
/// 用于 Artifact 检测到代码块后，在 ArtifactCardView 上方显示。
struct ArtifactCodeFoldView: View {
    let code: String
    let language: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏：点击折叠/展开
            Button(action: { withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(language.isEmpty ? "代码" : language)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(isExpanded ? "收起" : "\(code.components(separatedBy: "\n").count) 行")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.systemGray6).opacity(0.6))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            // 代码内容（折叠时隐藏）
            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 300)
                .background(Color(.systemGray6).opacity(0.3))
                .cornerRadius(0)
                .clipShape(
                    .rect(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
