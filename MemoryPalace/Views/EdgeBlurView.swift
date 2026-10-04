import SwiftUI
import VariableBlur

/// 顶部/底部的渐进模糊（10-04）。
/// 兔兔升 iOS 26 后，顶栏下方和输入条上方各出现一条**硬边的灰带**：VariableBlur 库走的是私有
/// variableBlur 滤镜，iOS 26 上它不再吃渐变遮罩，整块按满强度糊——于是 130pt 的模糊层变成一块硬边矩形。
/// iOS 26 起改用公开 API：毛玻璃材质 + 渐变遮罩（边缘自然淡出，没有硬边）；iOS 18 照旧用 VariableBlur。
struct EdgeBlurView: View {
    enum Edge { case top, bottom }
    let edge: Edge
    let maxBlurRadius: CGFloat

    var body: some View {
        if #available(iOS 26, *) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.85), location: 0.35),
                            .init(color: .black.opacity(0.35), location: 0.7),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: edge == .top ? .top : .bottom,
                        endPoint: edge == .top ? .bottom : .top
                    )
                )
                // 设置里的模糊强度滑条照旧生效（默认 1.3 ≈ 四成浓度，原先的柔化主要靠上层渐变色）
                .opacity(min(1, max(0, maxBlurRadius / 3)))
        } else {
            VariableBlurView(maxBlurRadius: maxBlurRadius,
                             direction: edge == .top ? .blurredTopClearBottom : .blurredBottomClearTop)
        }
    }
}
