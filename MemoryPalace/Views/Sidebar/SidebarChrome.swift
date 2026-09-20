// 从 SidebarView.swift 拆出：左栏卡片形状/反圆角装饰

import SwiftUI
import SwiftData
import UniformTypeIdentifiers


// MARK: - Inverse Tab Corner（Chrome 反向圆角）

struct InverseTabCorner: View {
    let radius: CGFloat
    let flipped: Bool

    var body: some View {
        InverseTabCornerShape()
            .fill(Theme.mainBg)
            .frame(width: radius, height: radius)
            .scaleEffect(x: flipped ? -1 : 1, anchor: .center)
            .offset(x: flipped ? -radius : radius)
    }
}


struct InverseTabCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height)
        // 填 mainBg 的区域：左下角 + 凹弧
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addLine(to: CGPoint(x: r, y: r))
        path.addArc(
            center: CGPoint(x: r, y: 0),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}


// MARK: - Sidebar Card Shape（Chrome 风格：选中 tab 下方 topLeading 清零连上 tab）

private struct SidebarCardShape: ViewModifier {
    let tab: SidebarTab

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
    }

    /// iOS 下 tab bar 已隐藏，四角统一圆角；macOS tab bar 常显，全部标签下左上角贴边。
    private var topLeadingRadius: CGFloat {
        16
    }

    private var horizontalPadding: CGFloat {
        20
    }
}


extension View {
    /// 左栏内容卡：Theme.mainBg 底 + 跟随选中 tab 的 UnevenRoundedRectangle + 水平 padding。
    /// 搜索结果卡、空结果卡、正常列表卡、贴纸搜索卡 5 处统一走这条。
    func sidebarCardShape(for tab: SidebarTab) -> some View {
        modifier(SidebarCardShape(tab: tab))
    }
}
