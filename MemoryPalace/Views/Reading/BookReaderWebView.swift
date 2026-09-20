import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 书阅读器 WebView——动态加载 ChapterHTMLRenderer 渲染好的章节 HTML 字符串。
/// 跟 WebViewHost 不同点：
/// - WebViewHost 加载 bundled HTML 文件（静态 artifact）
/// - 本组件加载内存 HTML 字符串（章节内容动态）
///
/// JS bridge handler name = `bookReader`。约定消息：
/// - `{type: "ready", chapter, total}`：首次加载完成
/// - `{type: "scroll", ratio, chapter}`：滚动节流后回报
/// - `{type: "select", text, start, end, chapter}`：用户选段（macOS 用，触发自定义菜单）
/// - `{type: "action", name, text, start, end, chapter}`：iOS 原生 edit menu 触发动作
///
/// Swift 推回：
/// - `BookReaderCommand.scrollToRatio(_:)` → 恢复阅读位置
struct BookReaderWebView: View {
    /// 当前要显示的章节 HTML（变化时整页 reload）
    let html: String
    /// 当前章节号——切章时改变，触发新 HTML reload
    let chapterNo: Int
    /// 加载完成后要滚到的进度（nil=保持顶部）
    var initialScrollRatio: Double? = nil
    /// iOS 原生 edit menu 第 4 个条目用的称呼（默认"助手"），跟 @AppStorage("assistantName") 走
    var assistantName: String = "助手"
    var onMessage: (BookReaderMessage) -> Void = { _ in }

    var body: some View {
        PlatformBookReaderWebView(
            html: html,
            chapterNo: chapterNo,
            initialScrollRatio: initialScrollRatio,
            assistantName: assistantName,
            onMessage: onMessage
        )
    }
}

enum BookReaderMessage {
    case ready(chapter: Int, total: Int)
    case scroll(ratio: Double, chapter: Int)
    case select(text: String, start: Int, end: Int, chapter: Int)
    case noteTap(noteIds: [String], chapter: Int)   // R4：点任何批注划线 → 就地小窗（重叠段多 id）
    case vocabTap(word: String, chapter: Int)    // CR-3：点击已收生词 → 词卡
    /// iOS 原生选段浮条触发的动作（替换 confirmationDialog 卡片）。
    /// name: "copy" | "highlight" | "addNote" | "askAI" | "addVocab"
    case action(name: String, text: String, start: Int, end: Int, chapter: Int)
    case error(String)

    init?(body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        switch type {
        case "ready":
            self = .ready(
                chapter: dict["chapter"] as? Int ?? 0,
                total: dict["total"] as? Int ?? 0
            )
        case "scroll":
            self = .scroll(
                ratio: dict["ratio"] as? Double ?? 0,
                chapter: dict["chapter"] as? Int ?? 0
            )
        case "select":
            self = .select(
                text: dict["text"] as? String ?? "",
                start: dict["start"] as? Int ?? 0,
                end: dict["end"] as? Int ?? 0,
                chapter: dict["chapter"] as? Int ?? 0
            )
        case "noteTap":
            self = .noteTap(
                noteIds: (dict["noteIds"] as? [String] ?? []).filter { !$0.isEmpty },
                chapter: dict["chapter"] as? Int ?? 0
            )
        case "vocabTap":
            self = .vocabTap(
                word: dict["word"] as? String ?? "",
                chapter: dict["chapter"] as? Int ?? 0
            )
        case "action":
            self = .action(
                name: dict["name"] as? String ?? "",
                text: dict["text"] as? String ?? "",
                start: dict["start"] as? Int ?? 0,
                end: dict["end"] as? Int ?? 0,
                chapter: dict["chapter"] as? Int ?? 0
            )
        default:
            return nil
        }
    }
}

#if os(macOS)
private struct PlatformBookReaderWebView: NSViewRepresentable {
    let html: String
    let chapterNo: Int
    let initialScrollRatio: Double?
    let assistantName: String
    let onMessage: (BookReaderMessage) -> Void

    func makeCoordinator() -> BookReaderCoordinator {
        BookReaderCoordinator(onMessage: onMessage)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator, initialRatio: initialScrollRatio)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.update(webView: webView, html: html, chapterNo: chapterNo, initialRatio: initialScrollRatio)
    }
}
#else
private struct PlatformBookReaderWebView: UIViewRepresentable {
    let html: String
    let chapterNo: Int
    let initialScrollRatio: Double?
    let assistantName: String
    let onMessage: (BookReaderMessage) -> Void

    func makeCoordinator() -> BookReaderCoordinator {
        BookReaderCoordinator(onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = makeWebView(coordinator: context.coordinator, initialRatio: initialScrollRatio)
        if let mp = wv as? MPReaderWebView {
            mp.currentChapter = chapterNo
            mp.assistantName = assistantName
            mp.installCustomMenuItems()
        }
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.update(webView: webView, html: html, chapterNo: chapterNo, initialRatio: initialScrollRatio)
        if let mp = webView as? MPReaderWebView {
            mp.currentChapter = chapterNo
            if mp.assistantName != assistantName {
                mp.assistantName = assistantName
                mp.installCustomMenuItems()
            }
        }
    }
}
#endif

private func makeWebView(coordinator: BookReaderCoordinator, initialRatio: Double?) -> WKWebView {
    let userContent = WKUserContentController()
    userContent.add(coordinator, name: "bookReader")

    let config = WKWebViewConfiguration()
    config.userContentController = userContent
    config.preferences.javaScriptCanOpenWindowsAutomatically = false

    #if os(iOS)
    let webView = MPReaderWebView(frame: .zero, configuration: config)
    #else
    let webView = WKWebView(frame: .zero, configuration: config)
    #endif
    webView.navigationDelegate = coordinator
    coordinator.webView = webView
    coordinator.pendingInitialRatio = initialRatio

    #if os(macOS)
    webView.setValue(false, forKey: "drawsBackground")
    #else
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    #endif
    return webView
}

// MARK: - iOS 自定义 edit menu WKWebView 子类

#if os(iOS)
/// iOS 原生选段浮条菜单——替换系统的 Copy / Look Up / Translate / Share，
/// 改成我们的「复制 / 高亮 / 加笔记 / 问{assistantName}」四个条目。
///
/// 实现路径：UIMenuController.shared.menuItems（iOS 16+ 已被 UIEditMenuInteraction 接管，
/// 但 menuItems 仍是官方支持的注入点，会出现在原生浮条里）+ override canPerformAction 屏蔽默认动作。
///
/// 每个 action 都 evaluateJavaScript 在 WKWebView 内取 selection 文本和章节内字符 offset，
/// 通过 `bookReader` message handler 发回 `{type: "action", name, text, start, end, chapter}`。
final class MPReaderWebView: WKWebView {
    /// 当前章节号——updateUIView 时同步，发 action message 时附带
    var currentChapter: Int = 0
    /// 第 4 条菜单显示用，跟 @AppStorage("assistantName") 走
    var assistantName: String = "助手"

    override var canBecomeFirstResponder: Bool { true }

    /// 只放行我们的 4 个 selector；系统的 copy/lookup/share/translate 一律 false 不显示
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return action == #selector(mp_copy(_:))
            || action == #selector(mp_highlight(_:))
            || action == #selector(mp_addNote(_:))
            || action == #selector(mp_askAI(_:))
            || action == #selector(mp_addVocab(_:))
    }

    /// 注册自定义菜单条目。assistantName 变了要重调。
    /// UIMenuController 是全局单例——本子类生命周期内（reader sheet 打开期间）独占。
    /// sheet 关闭时 didMoveToWindow(window=nil) 会清。
    func installCustomMenuItems() {
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "复制", action: #selector(mp_copy(_:))),
            UIMenuItem(title: "高亮", action: #selector(mp_highlight(_:))),
            UIMenuItem(title: "加笔记", action: #selector(mp_addNote(_:))),
            // [共读暂缓] 问 AI / 收生词条目（真身抽屉与生词本后续单独搬）
            // UIMenuItem(title: "问\(assistantName)", action: #selector(mp_askAI(_:))),
            // UIMenuItem(title: "收生词", action: #selector(mp_addVocab(_:)))
        ]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // 离场 — 清掉避免污染其他 UITextView 选段菜单
            UIMenuController.shared.menuItems = nil
        }
    }

    /// 通用：取 selection + 章节内 offset，发 action message。
    /// JS 端 offset 算法跟 ChapterHTMLRenderer.bridgeScript 的 reportSelection 同口径
    /// （`article.textContent` 字符序）—— ChapterHTMLRenderer.applyAnnotationsToParagraph
    /// 的锚点逻辑也是按这个口径，写入和读取闭合。
    private func postAction(_ name: String) {
        let js = """
        (function(){
          const sel = window.getSelection();
          if (!sel || sel.isCollapsed) return;
          const text = sel.toString();
          if (!text || !text.trim()) return;
          const article = document.getElementById('chapter');
          if (!article) return;
          const range = sel.getRangeAt(0);
          const pre = document.createRange();
          pre.selectNodeContents(article);
          pre.setEnd(range.startContainer, range.startOffset);
          const start = pre.toString().length;
          const end = start + text.length;
          window.webkit.messageHandlers.bookReader.postMessage({
            type: 'action',
            name: '\(name)',
            text: text,
            start: start,
            end: end,
            chapter: \(currentChapter)
          });
        })();
        """
        evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func mp_copy(_ sender: Any?) { postAction("copy") }
    @objc func mp_highlight(_ sender: Any?) { postAction("highlight") }
    @objc func mp_addNote(_ sender: Any?) { postAction("addNote") }
    @objc func mp_askAI(_ sender: Any?) { postAction("askAI") }
    @objc func mp_addVocab(_ sender: Any?) { postAction("addVocab") }
}
#endif

private final class BookReaderCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onMessage: (BookReaderMessage) -> Void
    weak var webView: WKWebView?
    /// 当前已加载的章节号——updateNSView/UIView 时跟传入对比，变了才 reload
    private var loadedChapterNo: Int = -1
    /// 待 ready 后执行的初始滚动 ratio
    var pendingInitialRatio: Double?
    /// 已经渲染过的 HTML 的指纹，避免相同章节频繁 reload
    private var lastLoadedFingerprint: String = ""

    init(onMessage: @escaping (BookReaderMessage) -> Void) {
        self.onMessage = onMessage
    }

    func update(webView: WKWebView, html: String, chapterNo: Int, initialRatio: Double?) {
        let fp = "\(chapterNo)#\(html.count)"
        guard fp != lastLoadedFingerprint else { return }
        lastLoadedFingerprint = fp
        loadedChapterNo = chapterNo
        pendingInitialRatio = initialRatio
        webView.loadHTMLString(html, baseURL: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bookReader",
              let msg = BookReaderMessage(body: message.body) else { return }

        if case .ready = msg, let r = pendingInitialRatio, r > 0 {
            let js = ChapterHTMLRenderer.scrollToRatioScript(r)
            // 延一帧再滚——刚 ready 时 layout 可能还没稳，docH 取不准
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.webView?.evaluateJavaScript(js)
            }
            pendingInitialRatio = nil
        }
        onMessage(msg)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // 文件 / about:blank / data: 允许；外链点击交给系统浏览器
        if url.isFileURL || ["about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow); return
        }
        if navigationAction.navigationType == .linkActivated {
            openExternalWebViewLink(url.absoluteString)
        }
        decisionHandler(.cancel)
    }
}
