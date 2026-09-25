import SwiftUI
import WebKit

// MARK: - Artifact Types

enum ArtifactType {
    case html
    case svg
    case mermaid

    var label: String {
        switch self {
        case .html: return "HTML"
        case .svg: return "SVG"
        case .mermaid: return "Mermaid"
        }
    }

    var icon: String {
        switch self {
        case .html: return "globe"
        case .svg: return "scribble.variable"
        case .mermaid: return "arrow.triangle.branch"
        }
    }
}

struct ArtifactContent {
    let code: String
    let type: ArtifactType

    /// 卡片标题：<title> → 第一个 <h1> → 类型名（09-23 画布升级：主人做的小游戏要有名字）
    var title: String {
        for pattern in [#"<title[^>]*>(.*?)</title>"#, #"<h1[^>]*>(.*?)</h1>"#] {
            if let r = code.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let inner = String(code[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
        }
        switch type {
        case .html: return "小页面"
        case .svg: return "SVG 图"
        case .mermaid: return "流程图"
        }
    }

    /// 是不是「能玩」的：有脚本或有可点的东西，卡片文案就写「点开玩」
    var isInteractive: Bool {
        type == .html && (code.range(of: "<script", options: .caseInsensitive) != nil
                          || code.range(of: "<button|onclick=|<input|<canvas", options: [.regularExpression, .caseInsensitive]) != nil)
    }

    /// 引了外网资源（脚本/样式/图/字体）——国内加载慢甚至不通，是「画布加载不出来」的头号原因（兔兔 09-23）
    var usesRemoteResources: Bool {
        code.range(of: #"(src|href)\s*=\s*["']https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            || code.range(of: #"@import\s+url\(|url\(\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 完整可加载的 HTML（卡片预览与全屏共用）
    var renderedHTML: String {
        switch type {
        case .html:
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<html") { return code }
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:16px;font-family:-apple-system,sans-serif;font-size:14px;line-height:1.5;}</style>
            </head>
            <body>
            \(code)
            </body>
            </html>
            """
        case .svg:
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:0;display:flex;justify-content:center;align-items:flex-start;padding:16px;box-sizing:border-box;} svg{max-width:100%;height:auto;}</style>
            </head>
            <body>
            \(code)
            </body>
            </html>
            """
        case .mermaid:
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:16px;font-family:-apple-system,sans-serif;}</style>
            <script src="mermaid.min.js"></script>
            </head>
            <body>
            <div class="mermaid">
            \(code)
            </div>
            <script>mermaid.initialize({startOnLoad:true,theme:'default'});</script>
            </body>
            </html>
            """
        }
    }
}

// MARK: - Artifact Detector

enum ArtifactDetector {

    /// Scans markdown content for the first renderable code block.
    static func find(in content: String) -> ArtifactContent? {
        let lines = content.components(separatedBy: "\n")
        var inBlock = false
        var blockLang = ""
        var blockLines: [String] = []

        for line in lines {
            if !inBlock {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                guard stripped.hasPrefix("```") else { continue }
                let lang = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                inBlock = true
                blockLang = lang
                blockLines = []
            } else {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    let code = blockLines.joined(separator: "\n")
                    if let artifact = classify(code: code, lang: blockLang) {
                        return artifact
                    }
                    inBlock = false
                    blockLang = ""
                    blockLines = []
                } else {
                    blockLines.append(line)
                }
            }
        }
        return nil
    }


    /// 从内容中移除第一个可渲染代码块，返回剩余内容。
    static func stripFirst(in content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var inBlock = false
        var blockLang = ""
        var blockStartIdx = 0
        var blockLines: [String] = []
        var removed = false

        for (i, line) in lines.enumerated() {
            if removed {
                result.append(line)
                continue
            }
            if !inBlock {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.hasPrefix("```") {
                    let lang = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    inBlock = true
                    blockLang = lang
                    blockStartIdx = i
                    blockLines = []
                } else {
                    result.append(line)
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    let code = blockLines.joined(separator: "\n")
                    if classify(code: code, lang: blockLang) != nil {
                        removed = true
                    } else {
                        result.append(lines[blockStartIdx])
                        result.append(contentsOf: blockLines)
                        result.append(line)
                    }
                    inBlock = false
                    blockLang = ""
                    blockLines = []
                } else {
                    blockLines.append(line)
                }
            }
        }

        if inBlock {
            result.append(lines[blockStartIdx])
            result.append(contentsOf: blockLines)
        }

        return result.joined(separator: "\n")
    }

    static func classify(code: String, lang: String) -> ArtifactContent? {
        switch lang {
        case "html": return ArtifactContent(code: code, type: .html)
        case "svg": return ArtifactContent(code: code, type: .svg)
        case "mermaid": return ArtifactContent(code: code, type: .mermaid)
        default:
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<html") {
                return ArtifactContent(code: code, type: .html)
            }
            if trimmed.hasPrefix("<svg") {
                return ArtifactContent(code: code, type: .svg)
            }
            return nil
        }
    }
}

// MARK: - WKWebView Wrapper

struct ArtifactCanvasView: UIViewRepresentable {
    let htmlContent: String
    var interactive: Bool = true
    var onLoaded: (() -> Void)? = nil
    var onProgress: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded, onProgress: onProgress) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = interactive
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        // 加载进度（兔兔 09-25：「白屏加载不出来，想要个进度条」）——estimatedProgress 是 KVO 的
        context.coordinator.progressObs = webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in
            let p = wv.estimatedProgress
            DispatchQueue.main.async { context.coordinator.onProgress?(p) }
        }
        if !interactive {
            // 卡片里的活预览：只看不碰，点击穿透给卡片去开全屏
            webView.isUserInteractionEnabled = false
            webView.scrollView.isScrollEnabled = false
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != htmlContent {
            context.coordinator.loadedHTML = htmlContent
            context.coordinator.revealed = false
            // baseURL 指向 bundle 资源目录：<script src="mermaid.min.js"> 这类本地资源才找得到
            webView.loadHTMLString(htmlContent, baseURL: Bundle.main.resourceURL)
            // 兜底：页面引了外网资源卡在加载时，1.5s 后照样露出——WebView 是渐进渲染的，
            // 主体早画好了，别让一个加载不到的字体把整页拖成转圈（兔兔 09-23「画布加载不出来」）
            let c = context.coordinator
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak c] in c?.reveal() }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String? = nil
        var revealed = false
        var progressObs: NSKeyValueObservation?
        let onLoaded: (() -> Void)?
        let onProgress: ((Double) -> Void)?
        init(onLoaded: (() -> Void)?, onProgress: ((Double) -> Void)?) { self.onLoaded = onLoaded; self.onProgress = onProgress }
        func reveal() { guard !revealed else { return }; revealed = true; onLoaded?() }
        // didCommit = 首批内容已到，就露出；不等所有外链资源 didFinish
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { reveal() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { reveal() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { reveal() }
    }
}

// MARK: - Artifact Card (inline in bubble)

struct ArtifactCardView: View {
    let artifact: ArtifactContent
    let onOpen: () -> Void
    @State private var previewLoaded = false
    @State private var previewProgress: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // 活预览：真的在跑，只是不能碰（09-23 画布升级：主人做的小游戏要一眼看见长什么样）
            ZStack(alignment: .top) {
                ArtifactCanvasView(htmlContent: artifact.renderedHTML, interactive: false, onLoaded: {
                    withAnimation(.easeOut(duration: 0.25)) { previewLoaded = true }
                }, onProgress: { previewProgress = $0 })
                .opacity(previewLoaded ? 1 : 0)
                if !previewLoaded {
                    CanvasLoadingBar(progress: previewProgress, hint: nil)
                        .padding(.top, 8)
                }
                // 底部渐隐，暗示「还有」
                LinearGradient(colors: [.clear, Theme.mainBg.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .frame(height: 180)
            .clipped()

            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.branchIndicator.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: artifact.isInteractive ? "wand.and.stars" : artifact.type.icon)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.branchIndicator)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(artifact.usesRemoteResources
                         ? "引了外网资源，可能加载慢"
                         : (artifact.isInteractive ? "点开玩 · 全屏" : "点开看 · 全屏"))
                        .font(.system(size: 11))
                        .foregroundColor(artifact.usesRemoteResources ? Color.orange.opacity(0.8) : Theme.textMuted)
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.mainBg.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - Artifact Canvas Sheet

/// 画布加载条：进度 + 卡住时的提示（09-25 兔兔：「还是会白屏加载不出来，希望有个进度条」）
struct CanvasLoadingBar: View {
    let progress: Double
    let hint: String?
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textMuted.opacity(0.18))
                    Capsule().fill(Theme.branchIndicator)
                        .frame(width: max(6, g.size.width * CGFloat(min(1, max(0.04, progress)))))
                        .animation(.easeOut(duration: 0.25), value: progress)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 24)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

struct ArtifactCanvasSheet: View {
    let artifact: ArtifactContent
    @Environment(\.dismiss) private var dismiss
    @State private var reloadTick = 0
    @State private var loaded = false
    @State private var progress: Double = 0
    @State private var slow = false          // 6s 还没完 → 提示外网资源

    /// 分页容器里 fullScreenCover 的安全区不可靠（顶栏被灵动岛盖住＝兔兔「没有退出键」）：
    /// 自己从 window 读，整页 ignoresSafeArea 后手动让出
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 59
    }
    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 34
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(UIColor.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: topInset + 44)   // 顶栏占位（顶栏本体在 overlay，永远在最上层）
                ZStack(alignment: .top) {
                    ArtifactCanvasView(htmlContent: artifact.renderedHTML, onLoaded: { loaded = true }, onProgress: { progress = $0 })
                        .id(reloadTick)
                    if !loaded {
                        CanvasLoadingBar(progress: progress,
                                         hint: slow ? (artifact.usesRemoteResources ? "还在等外网资源…可能加载不到" : "还在加载…") : nil)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, bottomInset)
            }
            .ignoresSafeArea()

            // 顶栏：自己让出状态栏，关闭键做成实心圆——在任何页面上都看得见
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: artifact.isInteractive ? "wand.and.stars" : artifact.type.icon)
                        .font(.system(size: 12))
                    Text(artifact.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(UIColor.systemBackground).opacity(0.85)))

                Spacer()

                Button { reloadTick += 1; loaded = false; progress = 0; slow = false } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)

                Menu {
                    Button { UIPasteboard.general.string = artifact.code } label: { Label("复制源码", systemImage: "doc.on.doc") }
                    ShareLink(item: artifact.code, subject: Text(artifact.title)) { Label("分享源码", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, topInset + 5)
        }
        .ignoresSafeArea()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true    // 玩着别锁屏
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if !loaded { slow = true } }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
