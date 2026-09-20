import SwiftUI
import WebKit

struct MessageContentWebView: UIViewRepresentable {
    let content: String
    let themeColors: [String: String]  // CSS 变量名 → 颜色值
    @Binding var dynamicHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = config.userContentController
        userContent.add(context.coordinator, name: "heightChanged")
        userContent.add(context.coordinator, name: "linkClicked")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // 加载本地 HTML 模板
        if let htmlURL = Bundle.main.url(forResource: "message-renderer", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingContent = content
        context.coordinator.pendingTheme = themeColors
        // 如果页面已加载完成，立即渲染；否则等 didFinish 后渲染
        if context.coordinator.pageLoaded {
            context.coordinator.renderContent(in: webView)
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MessageContentWebView
        var pageLoaded = false
        var pendingContent: String = ""
        var pendingTheme: [String: String] = [:]
        // 去重：避免 dynamicHeight 变化触发 updateUIView → 重新渲染 → 代码块折叠状态被重置
        private var lastRenderedContent: String = ""
        private var lastRenderedTheme: [String: String] = [:]
        weak var webView: WKWebView?

        init(_ parent: MessageContentWebView) { self.parent = parent }

        // JavaScript → Swift 消息处理
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "heightChanged":
                // JS number 桥接成 NSNumber；CGFloat 不能直接 as? 转，先取 doubleValue。
                if let number = message.body as? NSNumber {
                    let height = CGFloat(number.doubleValue)
                    if height > 0 {
                        let maxH = UIScreen.main.bounds.height * 1.5
                        let needsScroll = height > maxH
                        let clamped = needsScroll ? maxH : height
                        DispatchQueue.main.async {
                            self.parent.dynamicHeight = clamped
                            self.webView?.scrollView.isScrollEnabled = needsScroll
                        }
                    }
                }
            case "linkClicked":
                if let urlStr = message.body as? String, let url = URL(string: urlStr) {
                    UIApplication.shared.open(url)
                }
            default: break
            }
        }

        // 页面加载完成后渲染内容
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            renderContent(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                if self.parent.dynamicHeight < 44 { self.parent.dynamicHeight = 44 }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                if self.parent.dynamicHeight < 44 { self.parent.dynamicHeight = 44 }
            }
        }

        func renderContent(in webView: WKWebView) {
            let contentChanged = pendingContent != lastRenderedContent
            let themeChanged = pendingTheme != lastRenderedTheme

            // 内容和主题都没变 → 跳过渲染，保持 WebView 内部状态（代码块折叠等）
            guard contentChanged || themeChanged else { return }

            // 更新主题（只在变化时）
            if themeChanged {
                lastRenderedTheme = pendingTheme
                let themeJSON = (try? JSONSerialization.data(withJSONObject: pendingTheme))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                webView.evaluateJavaScript("updateTheme(\(themeJSON))")
            }

            // 渲染内容（只在变化时）
            if contentChanged {
                lastRenderedContent = pendingContent
                let escaped = pendingContent
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "$", with: "\\$")
                webView.evaluateJavaScript("render(`\(escaped)`)")
            }
        }
    }
}
