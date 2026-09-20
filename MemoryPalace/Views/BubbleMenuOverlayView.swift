#if os(iOS)
import SwiftUI
import UIKit

// Telegram 式长按浮层（docs/plan-contextmenu-telegram-style.md M2）：
// 活副本预览（可选字）+ 菜单卡片包同一个 ScrollView 一起滚；超长消息打开时先滚到底
// （气泡尾+菜单可见，Telegram 行为）；矮内容钉在原位（clamp 进安全边距，Stream 式）。
// 入场 Stream 级原位浮现（scale 0.96→1 spring），不做飞行状态机。

/// 浮层左上角在 window 坐标系的位置（delta 校准用）。
/// 聊天页在分页器 child HC 里，SwiftUI .global ≠ window 坐标，不能直接用 originFrameInWindow。
private struct WindowOriginReader: UIViewRepresentable {
    let onChange: (CGPoint) -> Void

    final class ProbeView: UIView {
        var onChange: ((CGPoint) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }
        private func report() {
            guard let window else { return }
            onChange?(convert(CGPoint.zero, to: window))
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.onChange = onChange
        return v
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }
}

/// 部分强度模糊（UIViewPropertyAnimator 暂停在 fractionComplete 的经典技巧）：
/// 系统 Material 模糊半径固定且带白化，压在暖奶白聊天页上直接糊成一块奶灰，
/// 外面的字全没了（粟粟真机反馈）。小强度真模糊 = 字影隐约可见的 Telegram 档。
private struct SoftBlurView: UIViewRepresentable {
    var intensity: CGFloat

    final class Coordinator {
        var animator: UIViewPropertyAnimator?
        deinit {
            animator?.stopAnimation(true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            view.effect = UIBlurEffect(style: .regular)
        }
        animator.fractionComplete = intensity
        context.coordinator.animator = animator
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        context.coordinator.animator?.fractionComplete = intensity
    }
}

/// window 层浮层宿主：浮层必须压住页级 chrome（顶部玻璃按钮等在 chatHC 之外），
/// 且材质要采样到真实内容层（壁纸/背景沉在 UIKit 层，chatHC 内的 SwiftUI 材质
/// 采不到 → 奶糊一片、菜单玻璃失效——粟粟真机三连报的共同根因）。
@MainActor
final class BubbleMenuOverlayPresenter {
    static let shared = BubbleMenuOverlayPresenter()
    private var host: UIHostingController<BubbleMenuOverlayView>?

    func present(model: BubbleMenuOverlayModel, in window: UIWindow) {
        guard host == nil else { return }
        let hc = UIHostingController(rootView: BubbleMenuOverlayView(model: model))
        hc.view.backgroundColor = .clear
        hc.view.clipsToBounds = true
        hc.view.frame = window.bounds
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(hc.view)
        host = hc
    }

    func dismissHost() {
        host?.view.removeFromSuperview()
        host = nil
    }
}

/// 裁剪区按方向外扩的矩形：水平/垂直各自留 bleed，让画在 frame 外的气泡尾巴不被剃
private struct BleedRect: Shape {
    var horizontal: CGFloat
    var vertical: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX - horizontal,
            y: rect.minY - vertical,
            width: rect.width + horizontal * 2,
            height: rect.height + vertical * 2
        ))
    }
}

/// 原生菜单行的按压态：按住时整行浅高亮（系统 UIMenu 同款反馈）
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
    }
}

struct BubbleMenuOverlayView: View {
    @ObservedObject var model: BubbleMenuOverlayModel

    var body: some View {
        if let session = model.session {
            BubbleMenuOverlayContent(session: session, model: model)
                .ignoresSafeArea()
        }
    }
}


private struct BubbleMenuOverlayContent: View {
    let session: BubbleMenuSession
    let model: BubbleMenuOverlayModel

    @State private var appeared = false
    @State private var dismissing = false
    @State private var windowOrigin: CGPoint = .zero
    /// 活副本的自然高度（框内实测）
    @State private var previewNaturalHeight: CGFloat = 0

    private let edgeMargin: CGFloat = 16
    private let topMargin: CGFloat = 70      // 状态栏下缘呼吸位
    private let bottomMargin: CGFloat = 44   // home indicator 带上缘
    private let columnSpacing: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let origin = CGRect(
                x: session.originFrameInWindow.minX - windowOrigin.x,
                y: session.originFrameInWindow.minY - windowOrigin.y,
                width: session.originFrameInWindow.width,
                height: session.originFrameInWindow.height
            )

            ZStack(alignment: .topLeading) {
                // 轻量真模糊 + 轻压暗：外面的字影隐约可见（Telegram 感），别糊死
                SoftBlurView(intensity: 0.35)
                    .overlay(Color.black.opacity(0.12))
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .opacity(appeared ? 1 : 0)

                column(origin: origin, in: geo)
                    .padding(.top, clampedTop(origin: origin, in: geo))
            }
            .background(WindowOriginReader { windowOrigin = $0 })
        }
    }

    // MARK: - 内容列（预览框 + 原生菜单锚点；长内容在框内滚，菜单永远完整可见）

    /// 菜单高度确定性推算（不实测）：行高 40 + 组界（10+线+10 ≈ 21）+ 卡上下 padding 12
    /// + 底部提示行（线 21 + 两行小字 ≈ 50）
    private var estimatedMenuHeight: CGFloat {
        let groupCount = session.specs.filter(\.dividerAfter).count + 1
        return CGFloat(session.specs.count) * 40 + CGFloat(max(groupCount - 1, 0)) * 21 + 12 + 71
    }

    /// 预览框最大高度 = 屏幕可用区扣掉菜单和边距，短消息卡片式钉原位的体量
    private func maxPreviewHeight(in geo: GeometryProxy) -> CGFloat {
        max(geo.size.height - topMargin - bottomMargin - estimatedMenuHeight - columnSpacing, 120)
    }

    private func displayedColumnHeight(in geo: GeometryProxy) -> CGFloat {
        min(previewNaturalHeight, maxPreviewHeight(in: geo)) + columnSpacing + estimatedMenuHeight
    }

    private func column(origin: CGRect, in geo: GeometryProxy) -> some View {
        VStack(alignment: session.isUser ? .trailing : .leading, spacing: columnSpacing) {
            previewBox(origin: origin, in: geo)
            // 自绘菜单按原生 UIMenu 规格逐项对齐（Telegram 路线：菜单归自己管才能和
            // 预览滚动/选字共存不打架——真原生 UIMenu 的"碰外面就收"没有开关，已实测判死）
            menuCard
                .scaleEffect(
                    appeared ? 1 : 0.4,
                    anchor: UnitPoint(x: session.isUser ? 0.85 : 0.15, y: 0)
                )
        }
        .padding(.leading, session.isUser ? edgeMargin : max(origin.minX, edgeMargin))
        .padding(.trailing, session.isUser ? max(geo.size.width - origin.maxX, edgeMargin) : edgeMargin)
        .frame(maxWidth: .infinity, alignment: session.isUser ? .trailing : .leading)
        .scaleEffect(appeared ? 1 : 0.96, anchor: session.isUser ? .topTrailing : .topLeading)
        .opacity(appeared ? 1 : 0)
    }

    /// 预览框：永远同一个 ScrollView 容器只变 frame 高度——fork MarkdownView 异步 parse，
    /// 若按高度切换 if/else 分支会换视图 identity → MarkdownView 重建回空壳 → 高度测量
    /// 50↔727 无限振荡（探针实录）。identity 稳定后：短内容框高=自然高（不滚），
    /// 长内容框高=上限，小滚动条在框内（粟粟原始需求：框里滚，不是整列滚）。
    private func previewBox(origin: CGRect, in geo: GeometryProxy) -> some View {
        let maxH = maxPreviewHeight(in: geo)
        let scrolls = previewNaturalHeight > maxH
        let boxHeight: CGFloat? = previewNaturalHeight > 0 ? min(previewNaturalHeight, maxH) : nil
        return ScrollView(.vertical, showsIndicators: true) {
            session.preview
                .frame(width: origin.width)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    previewNaturalHeight = newHeight
                    if !appeared && !dismissing {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appeared = true }
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: origin.width)
        .frame(height: boxHeight)
        // 无条件白底卡：AI 气泡透明底时活副本是裸文字，会和背景融掉（粟粟点名元凶）；
        // 气泡自身颜色照常渲染在白卡上。气泡模式白卡用带尾巴的气泡形状——
        // 透明底气泡的尾巴靠白卡顶出来（粟粟：透明气泡没有尾巴）
        .background(backdropShape.fill(Color.white))
        // Telegram 从不裁尾巴（粟粟基准）：尾巴画在气泡 frame 外，任何按边界的裁剪都会剃掉它。
        // 不滚动 = 四向全放开（等于不裁）；滚动 = 只裁窗口上下沿（防长内容漏出框），
        // 左右全放开 + 底部留 6pt 让尾巴探出
        .scrollClipDisabled()
        .clipShape(BleedRect(horizontal: 80, vertical: scrolls ? 6 : 80))
        // 投影立起来：气泡底色和暖奶白背景太接近，不分层就融成一片（粟粟真机反馈）
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
    }

    /// 白底卡形状：气泡模式带尾巴（BubbleTailShape），文章模式圆角矩形
    private var backdropShape: AnyShape {
        if session.tailBackdrop {
            AnyShape(BubbleTailShape(isUser: session.isUser, radius: session.cornerRadius, hasTail: true))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: session.cornerRadius, style: .continuous))
        }
    }

    /// 钉在原位 y，clamp 进 [topMargin, 底边距] 区间，菜单始终完整在屏内
    private func clampedTop(origin: CGRect, in geo: GeometryProxy) -> CGFloat {
        let maxTop = geo.size.height - bottomMargin - displayedColumnHeight(in: geo)
        return min(max(origin.minY, topMargin), max(maxTop, topMargin))
    }

    // MARK: - 菜单（自绘，按原生 UIMenu 规格：宽 250 / 行高 44 / 字号 17 / 边距 16 /
    // 发丝行分隔 / 8pt 组间带 / 圆角 13 连续曲率 / 按压高亮 / Liquid Glass）

    private var specGroups: [[Int]] {
        var groups: [[Int]] = [[]]
        for i in session.specs.indices {
            groups[groups.count - 1].append(i)
            if session.specs[i].dividerAfter { groups.append([]) }
        }
        return groups.filter { !$0.isEmpty }
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            ForEach(specGroups.indices, id: \.self) { gi in
                ForEach(specGroups[gi], id: \.self) { i in
                    menuRow(session.specs[i])
                    // 组内行之间无分隔线（iOS 26 原生：只有组界有线，粟粟并排图基准）
                }
                if gi < specGroups.count - 1 {
                    // 组界 = 中间一小段发丝线（两端缩进不顶边，粟粟基准）+ 上下呼吸位
                    Divider()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
            // 底部提示行（Swiftgram 式）：非交互小字，教选字手势
            Divider()
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            HStack(spacing: 14) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 15))
                    .frame(width: 24)
                Text("按住文字再拖动光标，可以选中一段复制或引用。")
                    .font(.system(size: 12))
                    .lineSpacing(2)
                Spacer(minLength: 8)
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 6)
        .frame(width: 235)
        // Liquid Glass 加在卡容器上——glassEffect 直接套 Button 会吞 hit test
        // （feedback_ios26_glass_button），行按钮用自定义 style 坐玻璃卡上
        .glassEffectCompat(tint: .clear, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 28, y: 10)
    }

    private func menuRow(_ spec: MenuActionSpec) -> some View {
        Button {
            dismiss(then: spec.handler)
        } label: {
            HStack(spacing: 14) {
                // iOS 26 原生菜单图标在前（粟粟并排图基准），固定槽宽让文字列对齐
                Image(systemName: spec.systemImage)
                    .font(.system(size: 15))
                    .frame(width: 24)
                Text(spec.title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(spec.isDestructive ? Color.red : Theme.textPrimary)
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - dismiss

    private func dismiss(then handler: (() -> Void)? = nil) {
        guard !dismissing else { return }
        dismissing = true
        // 动画起始帧即恢复原气泡：浮层预览与原位像素重合，无闪白空窗
        session.onRestore()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            appeared = false
        } completion: {
            model.session = nil
            BubbleMenuOverlayPresenter.shared.dismissHost()
            handler?()
        }
    }
}
#endif
