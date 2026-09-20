import SwiftUI

/// SwiftUI 包装 `PagingViewController` 的 representable。
///
/// 用法：外层给 `.ignoresSafeArea()` 让 PagingContainerView 占满屏（含 safe area），
/// 这样每页 `UIHostingController.view` 的 bounds 也覆盖整屏，各页内部 `.ignoresSafeArea()`
/// 能正确延伸到 status bar / home indicator 区域。
///
/// Wallpaper：通过 `wallpaper: WallpaperConfig` 参数传入，PagingViewController 在 UIKit
/// 层 UIImageView + CAGradientLayer 渲染，绕开 SwiftUI `.background` 在 child HC +
/// keyboard safeArea 下的 frame 响应坑（见 docs/research-wallpaper-uikit-layer.md）。
///
/// Env 注入：child HC 不继承 parent SwiftUI env，ChatInputBar 消费的
/// ProviderManager / ProfileManager / PresetManager 在**这里**订阅 + 转注给每页 rootView，
/// 避免 ContentView 订阅这 3 个 @Observable Manager 引起 body 全量重算（master R1
/// revert 原罪防复活，见 docs/postmortem-kelivo-keyboard-wallpaper.md）。
/// themeManager / globalWBManager / modelContext 由外层 ContentView.injectPagingEnv 注入
/// 后作为 `*Page: AnyView` 传入，这里再叠加 3 个 Manager 的注入。
struct PagingContainerView: UIViewControllerRepresentable {
    let chatPage: AnyView
    let dashPage: AnyView
    let writingPage: AnyView
    @Binding var currentPage: Int
    let disableScroll: Bool
    let initialPage: Int
    let wallpaper: WallpaperConfig
    /// B2 窄版：流式响应期间 skip updatePages。用户几乎不会在 AI 吐字时切对话 / 切楼层 /
    /// 放贴纸，窗口安全。isStreaming 变化本身 @Observable，边界时刻（开始前 / 结束后）
    /// SwiftUI 天然触发 updateUIViewController，外部 parent 那次会照刷。
    /// Plan: docs/plan-paging-isStreaming-skip.md
    let isStreaming: Bool
    /// 侧栏拖动/打开期间跳过 updatePages：拖动的每一帧都重算 ContentView body，
    /// 若每帧都给 4 个 HC 换 rootView = 每帧 diff 整棵聊天树——聊天一长左滑就卡的主凶。
    /// 侧栏关回 progress=0 时恢复刷新（同 isStreaming skip 的先例模式）。
    var pauseUpdates: Bool = false

    // 订阅 scope 从 ContentView 收敛到 Representable 层
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    /// 把 3 个 Manager 转注给 page。app 启动后这 3 个一般都 non-nil（App 注入保证），
    /// 用 if-let 防御性 unwrap，nil 时 page 不带这 3 个 env（ChatInputBar 不会 render，
    /// 但不 crash）。
    @ViewBuilder
    private func injectChatManagers<V: View>(_ page: V) -> some View {
        if let prov = providerManager, let prof = profileManager, let pres = presetManager {
            page
                .environment(prov)
                .environment(prof)
                .environment(pres)
        } else {
            page
        }
    }

    func makeUIViewController(context: Context) -> PagingViewController {
        let vc = PagingViewController(
            pages: [
                AnyView(injectChatManagers(chatPage)),
                AnyView(injectChatManagers(dashPage)),
                AnyView(injectChatManagers(writingPage))
            ],
            initialPage: initialPage
        )
        vc.onPageChanged = { newPage in
            // 同步回写 binding（此闭包由 UIScrollViewDelegate 在 SwiftUI update 周期**之外**
            // 调用，直接改 @Binding 安全）。旧版 DispatchQueue.main.async 留了一帧窗口：
            // VC 已翻到新页（programmaticCurrentPage=1）但 binding 还是 0，其间任意
            // updateUIViewController 会命中 `programmaticCurrentPage != currentPage` →
            // scrollToPage(0) 把用户拽回聊天页（右滑页点一下就跳回的残留 edge case）。
            currentPage = newPage
        }
        vc.setScrollEnabled(!disableScroll)
        vc.setShieldHiddenByCaller(disableScroll)   // sticker 编辑时让 home indicator 给 toolbar
        vc.loadViewIfNeeded()   // 确保 viewDidLoad 在 applyWallpaper 之前跑完，防止 viewDidLoad 里的 backgroundColor = .clear 覆盖主题色
        vc.applyWallpaper(wallpaper)
        return vc
    }

    func updateUIViewController(_ vc: PagingViewController, context: Context) {
        // B2 窄版 skip：流式响应期间不刷 3 个 HC rootView 避免 CardFlowView 整棵每 token
        // 重 diff。isStreaming false 时照旧 updatePages（= 原行为）。B2a 宽 signature 被
        // 证伪（贴纸 stale / 切对话 stale / 切楼层 race）后的保守版。
        if !isStreaming && !pauseUpdates {
            vc.updatePages([
                AnyView(injectChatManagers(chatPage)),
                AnyView(injectChatManagers(dashPage)),
                AnyView(injectChatManagers(writingPage))
            ])
        } else {
            #if DEBUG
            print(String(format: "[PERF] updatePages skip (streaming) t=%.3f", CFAbsoluteTimeGetCurrent()))
            #endif
        }
        vc.setScrollEnabled(!disableScroll)
        vc.setShieldHiddenByCaller(disableScroll)
        vc.applyWallpaper(wallpaper)
        if vc.programmaticCurrentPage != currentPage {
            vc.scrollToPage(currentPage, animated: true)
        }
    }
}
