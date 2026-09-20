import SwiftUI

/// 便签导出专用 View — 用于 ImageRenderer 渲染成 PNG
/// 和 StickerView 的 noteStickerContent 样式一致，但：
/// - 字体放大到 24pt（导出高清）
/// - glass 样式用不透明深灰底（PNG 不支持半透明背景预览）
/// - 不带画布上的 scale/rotation
struct NoteExportView: View {
    let content: String
    let style: String

    var body: some View {
        Text(content)
            .font(.system(size: 24))
            .foregroundColor(textColor)
            .padding(20)
            .frame(minWidth: 160, maxWidth: 400, minHeight: 80)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var background: Color {
        switch style {
        case "pink_rounded":
            return Color(red: 1, green: 0.85, blue: 0.88)
        case "glass":
            return Color(red: 0.25, green: 0.25, blue: 0.28) // 不透明深灰替代毛玻璃
        case "torn_paper":
            return Color(red: 0.97, green: 0.97, blue: 0.96)
        default: // yellow_square
            return Color(red: 1, green: 0.96, blue: 0.75)
        }
    }

    private var textColor: Color {
        switch style {
        case "glass": return .white
        default: return Color(red: 0.15, green: 0.15, blue: 0.15)
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case "pink_rounded": return 24
        case "torn_paper": return 4
        default: return 8
        }
    }
}
