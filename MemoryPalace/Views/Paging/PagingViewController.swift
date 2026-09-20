import UIKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// UIKit 翻页容器：内嵌 `UIScrollView(.horizontal) + paging` + 3 个独立 `UIHostingController`。
///
/// 架构目的：解决 Phase 2 v1 里 SwiftUI `.ignoresSafeArea` extension 不跟 `.offset` 走的
/// 结构性 bug——每页一个独立 `UIHostingController`，每页的 `.ignoresSafeArea` scope 限在该 HC，
/// 翻页靠 UIScrollView 改 contentOffset 物理 translate page view，extension 作为 HC 内部 subview
/// 跟着走，相邻页的 safe area 区不会有 wallpaper 残影。
///
/// 设计要点：
/// - `isPagingEnabled = true` + `bouncesHorizontally = false`（iOS 17.4+），硬禁水平 bounce
/// - `contentInsetAdjustmentBehavior = .never`，不自动 adjust（防止 safe area insets 干扰 paging step）
/// - `decelerationRate = .fast`，paging snap 更利落
/// - 每页 `UIHostingController.view.frame = CGRect(x: i·pageW, y: 0, pageW, pageH)`，并通过
///   `addChild + didMove(toParent:)` 建立 VC hierarchy（让每页 HC 的 safe area 继承正常工作)
///
/// Wallpaper（Step 3）：壁纸挂 `view.insertSubview(wallpaperContainer, at: 0)` 底层，不走
/// SwiftUI `.background` layer。原因：A10 实测 SwiftUI `.background { .ignoresSafeArea() }`
/// 的 content frame 响应 keyboard safeArea 等比放大 13%（484×1051 vs 427×929），虽然
/// UIKit `view.bounds` 不变但 SwiftUI layer frame 变 → 视觉"背景跟着键盘动"。UIKit
/// UIImageView 的 frame 由 `viewDidLayoutSubviews` 控制，键盘弹起时 `viewDidLayoutSubviews`
/// 不 fire（实测 log 印证），根治。参考 `docs/research-wallpaper-uikit-layer.md`。
@MainActor
final class PagingViewController: UIViewController, UIScrollViewDelegate {
    /// 暴露给 iOSTabBarGestureBlocker 用的 weak ref：sidebar tab 栏横滑时让水平 paging 的
    /// scrollView.panGestureRecognizer require(toFail: tab 栏 blockerPan)。整个 app 只有一个
    /// PagingViewController 实例（外层 SwiftUI iOSLayout 创建），用 static 单例最简洁。
    static weak var sharedScrollView: UIScrollView?

    private let scrollView = UIScrollView()
    private var hostingControllers: [UIHostingController<AnyView>] = []
    private var currentPage: Int
    /// 记录上次 layout 时的 bounds.width。每次 bounds 变化要 re-sync contentOffset，
    /// 避免 SwiftUI representable 首次 layout 给瞬时过渡 bounds 导致 initial offset 错位。
    private var lastLaidOutWidth: CGFloat = 0

    /// 手动翻页（用户拖动松手）稳定后回写 SwiftUI binding。
    var onPageChanged: ((Int) -> Void)?

    // MARK: - Wallpaper (Step 3)

    private let wallpaperContainer = UIView()
    private let wallpaperImageView = UIImageView()
    private let wallpaperGradientLayer = CAGradientLayer()
    private var lastImageURL: URL?
    private var lastSaturation: CGFloat = 1.0

    /// 上次完整 apply 过的 wallpaper config。同 config 时跳过整个 applyWallpaper（含
    /// backgroundColor / alpha / transform / gradient setter），减少 idle / 切对话路径
    /// CALayer 多余 commit。WallpaperConfig 7 字段 Equatable，gradientColors 用 cgColor
    /// 比较（UIColor == 是 ref-compare，cgColor 是值）。
    /// 见 docs/plan-perf-2026-04-25.md 线 a + Hermes Q3：Apple 不保证 alpha/transform/
    /// colors/bgColor 任何 setter idempotent，hot path 自己 guard 是合理。
    private var lastAppliedWallpaperConfig: WallpaperConfig?

    // MARK: - Home Indicator Hit Shield
    /// home indicator 区透明 hit shield。挂在 PagingViewController.view 顶层（z 高于 scrollView），
    /// frame 由 viewDidLayoutSubviews + viewSafeAreaInsetsDidChange 同步，高度 = min(window
    /// safeAreaInsets.bottom, 40)。挂 UIKit 层 + 用 window 的 safeAreaInsets（不取 chat HC 的
    /// 因为 chat HC additionalSafeAreaInsets 会被键盘改），命中链稳定不漂。
    /// 可见性：currentPage == 0 (chat 页) && !disableScroll (非 sticker 编辑模式)。
    /// V3 SwiftUI overlay 时灵时不灵 → V4 改 UIKit 层（codex 建议 + Apple docs hitTest D3 / safeAreaInsets D2）。
    private let homeIndicatorShield = HomeIndicatorHitShieldUIView()
    private var shieldHiddenByCaller: Bool = false   // 外部（PagingContainerView）显式 hide
    private var edgePanGesture: UIGestureRecognizer?

    /// CIFilter 创建 GPU context 有开销，共享一个全局实例。
    /// xcdoc: /documentation/CoreImage/CIFilter-swift.class/colorControls()
    private static let sharedCIContext = CIContext()

    init(pages: [AnyView], initialPage: Int) {
        self.currentPage = initialPage
        super.init(nibName: nil, bundle: nil)
        for page in pages {
            hostingControllers.append(UIHostingController(rootView: page))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Wallpaper 底层（z 最低，在 scrollView 之前 add）
        wallpaperContainer.backgroundColor = .clear
        wallpaperContainer.clipsToBounds = true
        wallpaperContainer.isUserInteractionEnabled = false   // wallpaper 不拦截 hit test
        wallpaperImageView.contentMode = .scaleAspectFill
        wallpaperImageView.clipsToBounds = true
        wallpaperImageView.isUserInteractionEnabled = false
        wallpaperContainer.addSubview(wallpaperImageView)
        // Gradient 放在 wallpaperContainer.layer 的 sublayer 中，视觉叠在 imageView 之上
        wallpaperGradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        wallpaperGradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        wallpaperGradientLayer.locations = [0, 0.5, 1]
        wallpaperContainer.layer.addSublayer(wallpaperGradientLayer)
        view.insertSubview(wallpaperContainer, at: 0)

        scrollView.isPagingEnabled = true
        scrollView.bouncesHorizontally = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.delegate = self
        view.addSubview(scrollView)

        for hc in hostingControllers {
            addChild(hc)
            hc.view.backgroundColor = .clear
            hc.view.clipsToBounds = true   // 防止 SwiftUI .ignoresSafeArea extension 溢出到相邻 page
            scrollView.addSubview(hc.view)
            hc.didMove(toParent: self)
        }

        Self.sharedScrollView = scrollView   // 给 iOSTabBarGestureBlocker 拿水平 paging pan 用

        // Home indicator hit shield — 挂 PagingViewController.view 上方（z 高于 scrollView 及其
        // child HCs），UIKit 顶层命中。viewDidLayoutSubviews / viewSafeAreaInsetsDidChange 同步 frame。
        homeIndicatorShield.backgroundColor = .clear
        homeIndicatorShield.isUserInteractionEnabled = true
        homeIndicatorShield.isHidden = (currentPage != 0) || shieldHiddenByCaller
        view.addSubview(homeIndicatorShield)
        let shieldTap = UITapGestureRecognizer(target: homeIndicatorShield, action: #selector(HomeIndicatorHitShieldUIView.absorbGesture))
        homeIndicatorShield.addGestureRecognizer(shieldTap)
        let shieldLP = UILongPressGestureRecognizer(target: homeIndicatorShield, action: #selector(HomeIndicatorHitShieldUIView.absorbGesture))
        shieldLP.minimumPressDuration = 0.1
        homeIndicatorShield.addGestureRecognizer(shieldLP)

        // Left-edge pan (60pt) — attached directly to view with delegate restricting to x < 60,
        // avoiding a blocking UIView that would shadow SwiftUI buttons in the same zone.
        let edgePan = UIPanGestureRecognizer(target: self, action: #selector(handleSidebarEdgePan(_:)))
        edgePan.delegate = self
        view.addGestureRecognizer(edgePan)
        self.edgePanGesture = edgePan
        scrollView.panGestureRecognizer.require(toFail: edgePan)

        // 键盘避让：嵌套 child HC 在 UIKit PagingViewController 下，SwiftUI 默认的
        // UIHostingController keyboard avoidance 机制失灵（实测 [PROBE kbd A/B] 无
        // changed to）——必须手动给 chat page child HC 注入 keyboard safe area inset。
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard hostingControllers.count > 1,
              let frameEnd = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let chatHC = hostingControllers[0]
        // keyboardFrameEnd 是 screen coords，转 chat HC view 坐标系算 overlap
        let frameInChat = chatHC.view.convert(frameEnd, from: nil)
        let overlap = max(0, chatHC.view.bounds.maxY - frameInChat.minY)
        // 扣掉系统 bottom safe area（home indicator 等），避免 double count。
        // view.safeAreaInsets.bottom = systemBottom + additionalSafeAreaInsets.bottom
        let currentBottom = chatHC.view.safeAreaInsets.bottom
        let currentExtra = chatHC.additionalSafeAreaInsets.bottom
        let systemBottom = max(0, currentBottom - currentExtra)
        let extra = max(0, overlap - systemBottom)
        chatHC.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: extra, right: 0)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard hostingControllers.count > 1 else { return }
        hostingControllers[0].additionalSafeAreaInsets = .zero
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        let w = view.bounds.width
        let h = view.bounds.height

        // Wallpaper 同步 frame（CAGradientLayer 动画默认有 implicit action，关掉避免
        // view.bounds 初始 layout 时 gradient 渐变动画闪一下）
        wallpaperContainer.frame = view.bounds
        wallpaperImageView.frame = wallpaperContainer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperGradientLayer.frame = wallpaperContainer.bounds
        CATransaction.commit()

        guard w > 0, h > 0 else { return }

        for (i, hc) in hostingControllers.enumerated() {
            hc.view.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
        scrollView.contentSize = CGSize(width: w * CGFloat(hostingControllers.count), height: h)

        layoutHomeIndicatorShield()

        #if DEBUG
        if hostingControllers.count > 1 {
            let chatHC = hostingControllers[0]
            PROBE("[PROBE shield] viewDidLayoutSubviews bounds=\(view.bounds) shield=\(homeIndicatorShield.frame) hidden=\(homeIndicatorShield.isHidden) currentPage=\(currentPage) view.safeAreaInsets.bottom=\(view.safeAreaInsets.bottom) window.safeAreaInsets.bottom=\(view.window?.safeAreaInsets.bottom ?? -1) chatHC.frame=\(chatHC.view.frame) chatHC.safeAreaInsets.bottom=\(chatHC.view.safeAreaInsets.bottom) chatHC.additional.bottom=\(chatHC.additionalSafeAreaInsets.bottom)")
        }
        #endif

        // bounds.width 变化时 re-sync contentOffset 到 currentPage：
        // SwiftUI representable 首次 layout 可能给一个瞬时过渡 width（比 final 小），
        // 不 re-sync 会让 offset 卡在旧值 × currentPage（错位，看见两页各半）。
        if abs(lastLaidOutWidth - w) > 0.5 {
            if !scrollView.isDragging && !scrollView.isDecelerating {
                scrollView.setContentOffset(CGPoint(x: CGFloat(currentPage) * w, y: 0), animated: false)
            }
            lastLaidOutWidth = w
        }
    }

    @objc private func handleSidebarEdgePan(_ gesture: UIPanGestureRecognizer) {
        let pageWidth = scrollView.frame.width
        let currentPage = Int(round(scrollView.contentOffset.x / max(pageWidth, 1)))
        guard currentPage == 0 else { return }
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        switch gesture.state {
        case .changed:
            NotificationCenter.default.post(
                name: .sidebarEdgePanChanged,
                object: nil,
                userInfo: ["translation": translation]
            )
        case .ended, .cancelled, .failed:
            NotificationCenter.default.post(
                name: .sidebarEdgePanEnded,
                object: nil,
                userInfo: ["translation": translation, "velocity": velocity]
            )
        default:
            break
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutHomeIndicatorShield()
        #if DEBUG
        PROBE("[PROBE shield] viewSafeAreaInsetsDidChange shield=\(homeIndicatorShield.frame) view.safeAreaInsets.bottom=\(view.safeAreaInsets.bottom) window.safeAreaInsets.bottom=\(view.window?.safeAreaInsets.bottom ?? -1)")
        #endif
    }

    /// shield frame：底部贴边、宽 = view.bounds.width、高 = min(window.safeAreaInsets.bottom, 40)。
    /// 用 window.safeAreaInsets.bottom 而非 view.safeAreaInsets.bottom，因为 chat HC 的
    /// additionalSafeAreaInsets 会被键盘改 → view.safeAreaInsets 跟着浮动。window 的
    /// safeAreaInsets 是设备本身的（home indicator），不被 keyboard inset 污染。
    /// (Apple xcdoc: /documentation/uikit/uiview/safeareainsets — "Custom view subclasses
    /// can use this property to determine which areas are safe to lay out content in.")
    private func layoutHomeIndicatorShield() {
        let windowBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        let shieldH = min(max(0, windowBottom), 40)
        let frame = CGRect(
            x: 0,
            y: view.bounds.maxY - shieldH,
            width: view.bounds.width,
            height: shieldH
        )
        homeIndicatorShield.frame = frame
        // 维持最高 z（每次 layout 后 bring 回来，updatePages / addSubview 等可能搅 z）
        view.bringSubviewToFront(homeIndicatorShield)
    }

    // MARK: - Public API

    /// 当前页缓存，给 representable 判断要不要触发 scrollToPage。
    var programmaticCurrentPage: Int { currentPage }

    func scrollToPage(_ page: Int, animated: Bool) {
        currentPage = page
        updateShieldVisibility()
        guard isViewLoaded, scrollView.bounds.width > 0 else {
            // 还没 layout 好，currentPage 已更新，viewDidLayoutSubviews 会用新值对齐 offset
            return
        }
        let x = CGFloat(page) * scrollView.bounds.width
        scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    }

    func setScrollEnabled(_ enabled: Bool) {
        scrollView.isScrollEnabled = enabled
    }

    /// 由 PagingContainerView 在 sticker 编辑模式 / 其他需要让出 home indicator 区时调用。
    /// hidden=true 时 shield 被 force-hide（编辑贴纸时 StickerKeyboardPanel 会延伸到 home indicator）。
    func setShieldHiddenByCaller(_ hidden: Bool) {
        guard shieldHiddenByCaller != hidden else { return }
        shieldHiddenByCaller = hidden
        updateShieldVisibility()
    }

    private func updateShieldVisibility() {
        guard isViewLoaded else { return }
        // shield 仅在 chat 页（page 0）+ 非外部 hide 时可见
        homeIndicatorShield.isHidden = (currentPage != 0) || shieldHiddenByCaller
        view.bringSubviewToFront(homeIndicatorShield)
        #if DEBUG
        PROBE("[PROBE shield] updateShieldVisibility currentPage=\(currentPage) shieldHiddenByCaller=\(shieldHiddenByCaller) → isHidden=\(homeIndicatorShield.isHidden)")
        #endif
    }

    /// 替换各页 SwiftUI rootView，让 SwiftUI state 变化 propagate 进每页。
    func updatePages(_ pages: [AnyView]) {
        for (i, page) in pages.enumerated() where i < hostingControllers.count {
            hostingControllers[i].rootView = page
        }
    }

    /// 应用 wallpaper 配置。SwiftUI 侧每次 state 变化触发 `updateUIViewController` 调用。
    /// - 线 a (2026-04-25)：同 config 整体短路（避免 4 个 layer setter + CATransaction commit）。
    /// - 同 imageURL + 同 saturation 时跳过重 decode + filter（避免每次 binding tick 重算）
    /// - gradient / opacity / offset 每次更新（开销小）
    func applyWallpaper(_ config: WallpaperConfig) {
        // 线 a (2026-04-25)：同 config 短路。Apple 不保证 alpha/transform/colors/bgColor
        // 任何 setter idempotent（Hermes Q3 verified）。每次 ContentView.body re-eval 都
        // 走一遍 4 个 setter + CATransaction commit 是浪费；这里在最外层一次拦掉。
        // WallpaperConfig 7 字段 Equatable（PagingViewController.swift L362-381），
        // gradientColors 用 cgColor 比较（UIColor == 是 ref，cgColor 是值），覆盖完整。
        guard config != lastAppliedWallpaperConfig else {
            #if DEBUG
            print("[PERF] applyWallpaper skip (config unchanged) t=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent()))")
            #endif
            return
        }
        defer { lastAppliedWallpaperConfig = config }

        wallpaperContainer.backgroundColor = UIColor(config.fill)

        let needsImageRefresh = (config.imageURL != lastImageURL) || (config.saturation != lastSaturation)
        if needsImageRefresh {
            lastImageURL = config.imageURL
            lastSaturation = config.saturation
            if let url = config.imageURL,
               let raw = UIImage(contentsOfFile: url.path) {
                wallpaperImageView.image = applySaturation(config.saturation, to: raw)
                wallpaperImageView.isHidden = false
            } else {
                wallpaperImageView.image = nil
                wallpaperImageView.isHidden = true
            }
        }

        wallpaperImageView.alpha = config.opacity
        wallpaperImageView.transform = CGAffineTransform(translationX: config.offsetX, y: config.offsetY)

        // Gradient 颜色更新（关动画 implicit action 避免重绘闪烁）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperGradientLayer.colors = config.gradientColors.map { $0.cgColor }
        CATransaction.commit()
    }

    /// CIFilter.colorControls 的 saturation 预处理。saturation == 1.0 时跳过返回原图。
    /// xcdoc: /documentation/CoreImage/CIFilter-swift.class/colorControls()
    private func applySaturation(_ saturation: CGFloat, to image: UIImage) -> UIImage {
        guard abs(saturation - 1.0) > 0.001,
              let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.saturation = Float(saturation)
        guard let output = filter.outputImage,
              let cg = Self.sharedCIContext.createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        syncPageFromOffset(scrollView)
    }

    /// 慢速拖动在页边界停稳后松手 → willDecelerate=false → DidEndDecelerating 永不触发，
    /// currentPage 卡在旧值。之后任意 SwiftUI 重算走 updateUIViewController 的
    /// scrollToPage(stale) / viewDidLayoutSubviews 的 offset re-sync，页面被拽回旧页
    /// （真机 bug：右滑页点一下屏幕就跳回聊天页）。DidEndDragging/DidEndDecelerating
    /// 是标准配对，必须两个都实现。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { syncPageFromOffset(scrollView) }
    }

    private func syncPageFromOffset(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        guard page != currentPage else { return }
        currentPage = page
        updateShieldVisibility()
        onPageChanged?(page)
    }
}

/// home indicator 区透明 hit shield 的 UIView 子类。
///
/// 关键：`point(inside:)` 让 UIView 在 frame 内永远成为 deepest hit-test target，
/// UIKit 不会向 chat HC 内部的气泡 UIView 派发该 touch，bubble 的 UIContextMenuInteraction
/// 永远观察不到。挂的 UITap + UILongPress recognizer 各一个空 absorb action 吃掉手势。
///
/// xcdoc: /documentation/uikit/uiview/hittest(_:with:) — "Returns the farthest descendant
///        of the receiver in the view hierarchy (including itself) that contains a specified
///        point."
/// xcdoc: /documentation/uikit/adding-context-menus-in-your-app
@MainActor
final class HomeIndicatorHitShieldUIView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let inside = self.bounds.contains(point)
        #if DEBUG
        PROBE("[PROBE shield] point(inside:) point=\(point) bounds=\(bounds) inside=\(inside) isHidden=\(isHidden) windowSafeBottom=\(window?.safeAreaInsets.bottom ?? -1)")
        #endif
        return inside
    }
    @objc func absorbGesture() { /* 吃掉手势，不做任何事 */ }
}

// MARK: - UIGestureRecognizerDelegate

extension PagingViewController: UIGestureRecognizerDelegate {
    /// Restrict edge pan to the leading 60pt zone. Returning false here transitions
    /// the recognizer to .failed immediately, so scrollView.panGestureRecognizer
    /// (which require(toFail:) edgePan) isn't blocked for touches outside that zone.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgePanGesture else { return true }
        guard gestureRecognizer.location(in: view).x < 60 else { return false }
        // Only intercept horizontal right-swipe, let long-press and vertical scroll through
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }
}

// MARK: - Notification Names for Sidebar Edge Pan
extension Notification.Name {
    static let sidebarEdgePanChanged = Notification.Name("mp.sidebarEdgePanChanged")
    static let sidebarEdgePanEnded = Notification.Name("mp.sidebarEdgePanEnded")
}

/// Wallpaper 显示配置。SwiftUI 侧构造，UIKit 侧应用。
/// Equatable 让 PagingContainerView 可以在 updateUIViewController 里 diff 避免多余 apply。
struct WallpaperConfig: Equatable {
    let fill: Color
    let imageURL: URL?
    let saturation: CGFloat
    let opacity: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let gradientColors: [UIColor]

    // UIColor Equatable 比较（cgColor 层面）
    static func == (lhs: WallpaperConfig, rhs: WallpaperConfig) -> Bool {
        lhs.fill == rhs.fill
            && lhs.imageURL == rhs.imageURL
            && lhs.saturation == rhs.saturation
            && lhs.opacity == rhs.opacity
            && lhs.offsetX == rhs.offsetX
            && lhs.offsetY == rhs.offsetY
            && lhs.gradientColors.map { $0.cgColor } == rhs.gradientColors.map { $0.cgColor }
    }
}
