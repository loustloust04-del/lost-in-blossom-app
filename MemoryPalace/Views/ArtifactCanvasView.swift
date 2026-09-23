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
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
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

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }

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
            webView.loadHTMLString(htmlContent, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String? = nil
        let onLoaded: (() -> Void)?
        init(onLoaded: (() -> Void)?) { self.onLoaded = onLoaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoaded?() }
    }
}

// MARK: - Artifact Card (inline in bubble)

struct ArtifactCardView: View {
    let artifact: ArtifactContent
    let onOpen: () -> Void
    @State private var previewLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            // 活预览：真的在跑，只是不能碰（09-23 画布升级：主人做的小游戏要一眼看见长什么样）
            ZStack {
                ArtifactCanvasView(htmlContent: artifact.renderedHTML, interactive: false) {
                    withAnimation(.easeOut(duration: 0.25)) { previewLoaded = true }
                }
                .opacity(previewLoaded ? 1 : 0)
                if !previewLoaded {
                    ProgressView().tint(Theme.textMuted)
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
                    Image(systemName: artifact.isInteractive ? "gamecontroller" : artifact.type.icon)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.branchIndicator)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(artifact.isInteractive ? "点开玩 · 全屏" : "点开看 · 全屏")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
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

struct ArtifactCanvasSheet: View {
    let artifact: ArtifactContent
    @Environment(\.dismiss) private var dismiss
    @State private var reloadTick = 0
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: artifact.isInteractive ? "gamecontroller" : artifact.type.icon)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                    Text(artifact.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                // 重开一局（小游戏最常按的）
                Button { reloadTick += 1; loaded = false } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Menu {
                    Button { UIPasteboard.general.string = artifact.code } label: { Label("复制源码", systemImage: "doc.on.doc") }
                    ShareLink(item: artifact.code, subject: Text(artifact.title)) { Label("分享源码", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.2)

            ZStack {
                ArtifactCanvasView(htmlContent: artifact.renderedHTML) { loaded = true }
                    .id(reloadTick)
                if !loaded { ProgressView().tint(Theme.textMuted) }
            }
            .ignoresSafeArea(.keyboard)
        }
        .background(Color(UIColor.systemBackground))
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }    // 玩着别锁屏
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
