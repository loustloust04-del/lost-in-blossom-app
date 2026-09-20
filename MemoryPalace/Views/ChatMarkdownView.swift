import SwiftUI
import MarkdownUI

// 搬运垫片（2026-08-30，气泡模式整套搬运）。
//
// 粟粟那边的 ChatMarkdownView 是她「流式重写」线的渲染器，底下是她 Mac 本机的
// SwiftStreamingMarkdown local fork（project.yml 里 path: /Users/susu/...，不在仓库里），
// 上面又挂了划词收生词 / 高亮 / 话题草稿一整套（VocabCardStore、ChatHighlightStore…）。
// 这些我们没有也不该有。这里保留她的调用签名，内部走我们现成的 MarkdownUI，
// 让她的 ChatBubbleStyle / ThinkingSheet 原文不改就能编译。
//
// 签名对齐她的 Views/ChatMarkdownView.swift:33-43（多余参数照收不用）。
struct ChatMarkdownView: View {
    let text: String
    var fontName: String = ""
    var scale: CGFloat = 1.2
    var animated: Bool = false
    var nodeId: String? = nil
    var profileId: String = ""
    var onQuote: ((String) -> Void)? = nil
    var flashQuote: String? = nil

    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65

    var body: some View {
        Markdown(text)
            .markdownTheme(.memoryPalace(
                fontName: fontName,
                scale: scale > 0 ? scale : 1.0,
                lineSpacingScale: CGFloat(lineSpacingScale),
                paragraphSpacingScale: CGFloat(paragraphSpacingScale)
            ))
            .textSelection(.enabled)
    }
}

// 她的 fork 里 BlockView 有个 html artifact hook，通过这个 environment 注入渲染器。
// 我们的 MarkdownUI 没有这个钩子，键保留只为让 `.environment(\.htmlBlockRenderer)` 调用点编译。
struct HTMLBlockRendererKey: EnvironmentKey {
    static let defaultValue: ((String) -> AnyView)? = nil
}

extension EnvironmentValues {
    var htmlBlockRenderer: ((String) -> AnyView)? {
        get { self[HTMLBlockRendererKey.self] }
        set { self[HTMLBlockRendererKey.self] = newValue }
    }
}

/// 她的 HTMLArtifactCardView 在 Views/Web/ 下绑 WKWebView 预览；这里最小占位——
/// 折叠成一条「HTML 片段」提示，不渲染。等我们的 artifact 线接上再换。
struct HTMLArtifactCardView: View {
    let content: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11))
            Text("HTML 片段（\(content.count) 字）")
                .font(.system(size: 12))
        }
        .foregroundColor(Theme.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.textMuted.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 粟粟召回卡（RecallCardView 绑她的记忆召回系统）——垫片：我们暂无对应功能，空渲染。
/// 她的 BubbleModeRow 在 assistant 列里无条件挂它，签名保持一致让原文编译。
struct RecallCardView: View {
    let node: MessageNode
    var body: some View { EmptyView() }
}

// 平台图片别名 + Image 初始化桥（粟粟 MessageSegmentsView 同款；她的 AvatarImageCache 用）
#if os(macOS)
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}
#endif
