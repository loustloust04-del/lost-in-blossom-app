import Foundation

/// txt 章节正文 → 阅读器可渲染的 HTML 字符串。
///
/// 设计：
/// - 段落按空行切，每段一个 `<p>`
/// - 章节标题作 `<h2>`
/// - 内联 CSS 用 MP 主题色（暖奶白 #FFFBF6 + 浅灰薄荷 #E7EEEC），暗色模式自动
/// - 不引外网资源（无 web font / 无 CDN），严格 file:// 安全
/// - 用 `prefers-color-scheme` 跟随系统暗色
///
/// JS 桥（生成的 HTML 自带一段 inline script）：
/// - 滚动节流（200ms）→ `bookReader.postMessage({type:"scroll", ratio: 0-1})`
/// - selectionchange → `bookReader.postMessage({type:"select", text, start, end})`
/// - `ready` 事件首次加载完通知 Swift
enum ChapterHTMLRenderer {

    /// 字体大小档位（pt），对应阅读器设置面板的滑块刻度
    enum FontSize: Int, CaseIterable, Codable {
        case xs = 14
        case sm = 16
        case md = 18   // 默认
        case lg = 20
        case xl = 22
        case xxl = 24

        var label: String {
            switch self {
            case .xs: return "极小"; case .sm: return "小"; case .md: return "中"
            case .lg: return "大"; case .xl: return "大"; case .xxl: return "极大"
            }
        }
    }

    struct Style {
        var fontSize: FontSize = .md
        var lineHeight: Double = 1.8        // 中文阅读舒适区
        var paragraphSpacing: Double = 0.6  // em
    }

    /// 一段需要在原文上着色的标注。M3 用：高亮 / AI 划线。
    /// 用章节内字符 offset 锚定（跟 selection 报上来的 start/end 同口径——纯文本字符序）。
    struct Annotation {
        enum Kind { case highlight, aiUnderline, note }
        /// CR-1 双色：笔迹主人（Note.role 映射）。
        enum Author { case user, ai }
        let id: String
        let kind: Kind
        let start: Int   // 章节内纯文本 offset
        let end: Int
        var author: Author = .user
        /// 选段原文快照（失锚检测用；空 = 跳过校验）。
        var anchorText: String = ""
    }

    /// 渲染一章。
    /// - parameter title: 章节标题（h2 显示）
    /// - parameter text: 章节正文纯文本
    /// - parameter style: 排版风格
    /// - parameter chapterNo: 当前章号（透传给 JS bridge）
    /// - parameter totalChapters: 总章数
    /// - parameter annotations: 该章节已有的高亮/AI 划线/笔记锚点（M3）
    static func render(
        title: String,
        text: String,
        style: Style = Style(),
        chapterNo: Int,
        totalChapters: Int,
        annotations: [Annotation] = [],
        vocabWords: [String] = []
    ) -> String {
        let paragraphs = splitParagraphs(text)

        // 算每段在「全章纯文本流」里的起止 offset——必须跟 JS selection 报上来的 offset 同口径。
        // JS 那边用 `range.setEnd(article)` 取 toString().length，等价于 article.textContent
        // 字符序——会把 h2 的标题也算进去。所以这里也要把 title 的长度算进 base。
        // 注意：JS 端 article.textContent 是 "<h2>title</h2><p>...</p>..." 拼起来去标签后的串，
        // 没有标签间的空白。我们这边各段直接 join 不带分隔，base offset 就是 title.count + 前面段总长。
        let titleLen = title.count
        var paragraphRanges: [(start: Int, end: Int)] = []
        var cursor = titleLen
        for p in paragraphs {
            let len = p.count
            paragraphRanges.append((cursor, cursor + len))
            cursor += len
        }

        let bodyHTML = paragraphs.enumerated().map { (idx, p) -> String in
            let (pStart, pEnd) = paragraphRanges[idx]
            let inner = applyAnnotationsToParagraph(
                text: p,
                paragraphStart: pStart,
                paragraphEnd: pEnd,
                annotations: annotations
            )
            return "<p data-pi=\"\(idx)\" data-ps=\"\(pStart)\">\(inner)</p>"
        }.joined(separator: "\n")

        let css = stylesheet(style: style)
        let js = bridgeScript(chapterNo: chapterNo, totalChapters: totalChapters, vocabWords: vocabWords)

        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <article id="chapter">
        <h2>\(escape(title))</h2>
        \(bodyHTML)
        </article>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    // MARK: - 段落标注切片（CR-1 charMap 双层，tasogare 平移）

    /// 逐字符两层状态合成（旧实现"后写盖前写"处理不了重叠，CR-1 重写）：
    /// - 底色层：highlight/note 的 user/ai/both（重叠段 = both 双色渐变）
    /// - 虚线层：aiUnderline（aiBubble 锚），独立于底色可叠加，data-id 保点击链路
    /// 连续同值字符合并成一个 span。
    static func applyAnnotationsToParagraph(
        text: String,
        paragraphStart: Int,
        paragraphEnd: Int,
        annotations: [Annotation]
    ) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }

        enum Bg { case none, user, ai, both }
        var bg = [Bg](repeating: .none, count: chars.count)
        var ul = [String?](repeating: nil, count: chars.count)
        // R4：每字符所属的 note id 集合（含底色与虚线层）——点击弹就地小窗用，
        // 重叠段带多 id，小窗列全命中的批注
        var ids = [Set<String>](repeating: [], count: chars.count)
        var touched = false

        for a in annotations {
            let s = max(0, max(a.start, paragraphStart) - paragraphStart)
            let e = min(chars.count, min(a.end, paragraphEnd) - paragraphStart)
            guard s < e else { continue }
            touched = true
            switch a.kind {
            case .aiUnderline:
                for i in s..<e {
                    ul[i] = a.id   // 虚线重叠：后者盖前者（保持旧语义）
                    ids[i].insert(a.id)
                }
            case .highlight, .note:
                for i in s..<e {
                    ids[i].insert(a.id)
                    switch (bg[i], a.author) {
                    case (.none, .user): bg[i] = .user
                    case (.none, .ai):   bg[i] = .ai
                    case (.user, .ai), (.ai, .user): bg[i] = .both
                    default: break   // both 不再变；同色重叠不变
                    }
                }
            }
        }
        if !touched { return escape(text) }

        var out = ""
        var i = 0
        while i < chars.count {
            let b = bg[i]
            let u = ul[i]
            let idSet = ids[i]
            var j = i + 1
            while j < chars.count && bg[j] == b && ul[j] == u && ids[j] == idSet { j += 1 }
            let inner = escape(String(chars[i..<j]))

            var classes: [String] = []
            switch b {
            case .none: break
            case .user: classes.append("hl")
            case .ai:   classes.append("hl-ai")
            case .both: classes.append("hl-both")
            }
            if u != nil { classes.append("ai-ul") }

            if classes.isEmpty {
                out += inner
            } else {
                let idsAttr = idSet.isEmpty ? "" : " data-ids=\"\(escape(idSet.sorted().joined(separator: ",")))\""
                out += "<span class=\"\(classes.joined(separator: " "))\"\(idsAttr)>\(inner)</span>"
            }
            i = j
        }
        return out
    }

    // MARK: - 失锚检测（CR-1）

    /// 章内文本流切片（title+段落 join 口径，与 annotation offset 同域）。
    /// 高亮融合时重建合并区间的 anchorText 用。越界返回 nil。
    static func flowSlice(title: String, text: String, start: Int, end: Int) -> String? {
        let flow = title + splitParagraphs(text).joined()
        let chars = Array(flow)
        guard start >= 0, end <= chars.count, start < end else { return nil }
        return String(chars[start..<end])
    }

    /// 整章比对：annotation 的 offset 切片 vs anchorText 快照。
    /// **宽容模式**：去空白归一化后比对（跨段换行/段内折叠差异免疫，只有真实文字变化才判失锚）；
    /// anchorText 空跳过。失锚不影响渲染（照常上色），只供抽屉标「原文已变」——零视觉回归。
    static func brokenAnchorIds(title: String, text: String, annotations: [Annotation]) -> Set<String> {
        let flow = title + splitParagraphs(text).joined()
        let chars = Array(flow)
        var broken: Set<String> = []
        for a in annotations where !a.anchorText.isEmpty {
            guard a.start >= 0, a.end <= chars.count, a.start < a.end else {
                broken.insert(a.id)
                continue
            }
            let slice = String(chars[a.start..<a.end])
            if normalizeAnchor(slice) != normalizeAnchor(a.anchorText) {
                broken.insert(a.id)
            }
        }
        return broken
    }

    private static func normalizeAnchor(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    // MARK: - 段落切分

    /// txt 段落识别：
    /// 1. 标准排版（段间空行）→ 按 `\n\n` 切，段内单 `\n` 折叠成空格
    /// 2. 紧凑排版（每段一行，没空行）→ fallback 按单 `\n` 切
    ///
    /// 触发紧凑分支的条件：`\n\n` 切出 ≤ 1 段，但章里有多个 `\n` 行。
    /// 网文抓取的 txt 常见"每段一行"格式，老逻辑会把整章压成一坨——这条 fallback 是修这个。
    static func splitParagraphs(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                              .replacingOccurrences(of: "\r", with: "\n")

        // trim 必须含换行：奇数连 \n（如 \n\n\n）切完剩单个 \n 粘在段首，
        // 标准路径会把它折成前导空格（5fdfda1d 回归，testSplitParagraphsByBlankLine 抓的）
        let byDouble = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if byDouble.count <= 1 {
            let bySingle = normalized.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if bySingle.count > byDouble.count {
                return bySingle
            }
        }

        // 标准路径：段内单 \n 折叠成空格（避免硬换行打散）
        return byDouble.map { $0.replacingOccurrences(of: "\n", with: " ") }
    }

    // MARK: - HTML 转义

    /// 防 XSS：用户书内容里可能有 `<` `>` `&` `"` `'`
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 样式

    /// 内联 CSS。MP 主题色：暖奶白 #FFFBF6 + 浅灰薄荷 #E7EEEC + 薄荷强调 #8EBD9F。
    /// 暗色模式：跟随系统 `prefers-color-scheme`。
    private static func stylesheet(style: Style) -> String {
        """
        :root {
          --bg: #FFFBF6;
          --bg-card: #FAF6F0;
          --text: #2C2A28;
          --text-muted: #8A8682;
          --accent: #E7EEEC;
          --mint: #8EBD9F;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1E1D1B;
            --bg-card: #25241F;
            --text: #E8E5DF;
            --text-muted: #9A958E;
            --accent: #2F3B36;
            --mint: #6FA383;
          }
        }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--bg);
          color: var(--text);
          -webkit-text-size-adjust: 100%;
          -webkit-font-smoothing: antialiased;
          font-family: -apple-system, "PingFang SC", "Hiragino Sans GB",
                       "Microsoft YaHei", "Songti SC", "STSong", serif;
        }
        article#chapter {
          /* iOS Notch / 圆角 / home indicator 全避开；左右至少 20px */
          padding-top: max(24px, env(safe-area-inset-top));
          padding-right: max(20px, env(safe-area-inset-right));
          padding-bottom: max(80px, env(safe-area-inset-bottom));
          padding-left: max(20px, env(safe-area-inset-left));
          max-width: 720px;
          margin: 0 auto;
          box-sizing: border-box;
          font-size: \(style.fontSize.rawValue)px;
          line-height: \(style.lineHeight);
        }
        h2 {
          font-size: 1.4em;
          margin: 0 0 1.5em;
          padding-bottom: 0.5em;
          border-bottom: 1px solid var(--accent);
          color: var(--mint);
          font-weight: 600;
        }
        p {
          margin: 0 0 \(style.paragraphSpacing)em;
          text-indent: 2em;
          text-align: justify;
        }
        /* M3 会用到的高亮/AI 划线 */
        .hl {
          background: rgba(142, 189, 159, 0.25);
          border-radius: 2px;
          padding: 0 2px;
        }
        /* CR-1 双色：AI 笔迹玫瑰 #C98A8A；both = 上下两支笔（上薄荷下玫瑰） */
        .hl-ai {
          background: rgba(201, 138, 138, 0.28);
          border-radius: 2px;
          padding: 0 2px;
        }
        .hl-both {
          background: linear-gradient(to bottom,
            rgba(142, 189, 159, 0.30) 0%, rgba(142, 189, 159, 0.30) 50%,
            rgba(201, 138, 138, 0.32) 50%, rgba(201, 138, 138, 0.32) 100%);
          border-radius: 2px;
          padding: 0 2px;
        }
        .ai-ul {
          border-bottom: 1px dashed var(--mint);
          padding-bottom: 1px;
        }
        /* CR-3：已收生词——点状下划线（与 AI 虚线区分），点击弹词卡 */
        .vocab-ul {
          border-bottom: 1.5px dotted rgba(142, 142, 142, 0.65);
          padding-bottom: 1px;
        }
        ::selection {
          background: rgba(142, 189, 159, 0.4);
        }
        """
    }

    // MARK: - JS Bridge

    private static func bridgeScript(chapterNo: Int, totalChapters: Int, vocabWords: [String] = []) -> String {
        // 词表 JSON 化进脚本（收词后 rerender 走既有管线，与 annotations 同生命周期）
        let vocabJSON = (try? String(data: JSONEncoder().encode(vocabWords), encoding: .utf8)) ?? "[]"
        return """
        (function(){
          const post = (msg) => {
            try { window.webkit.messageHandlers.bookReader.postMessage(msg); } catch(_) {}
          };

          // CR-3：已收生词 → 文本节点内 whole-word 包 .vocab-ul（JS 后处理不动
          // textContent 字符序，selection/annotation offset 口径不受影响；学 tasogare
          // 但补词边界：ASCII 词用 \\b，含 CJK 的词组直接精确串匹配）
          const MP_VOCAB = \(vocabJSON);
          const escRe = (s) => s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
          function mpApplyVocab() {
            if (!MP_VOCAB.length) return;
            const pats = MP_VOCAB.map(w => {
              const e = escRe(w);
              return /^[\\x00-\\x7F]+$/.test(w) ? '\\\\b' + e + '\\\\b' : e;
            });
            const re = new RegExp('(' + pats.join('|') + ')', 'gi');
            const article = document.getElementById('chapter');
            if (!article) return;
            const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
              acceptNode: (n) => n.parentElement && n.parentElement.closest('.vocab-ul')
                ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
            });
            const targets = [];
            let node;
            while ((node = walker.nextNode())) {
              if (re.test(node.nodeValue)) targets.push(node);
              re.lastIndex = 0;
            }
            for (const t of targets) {
              const frag = document.createDocumentFragment();
              let last = 0;
              const s = t.nodeValue;
              s.replace(re, (m, _g, off) => {
                frag.appendChild(document.createTextNode(s.slice(last, off)));
                const span = document.createElement('span');
                span.className = 'vocab-ul';
                span.setAttribute('data-word', m.toLowerCase());
                span.textContent = m;
                frag.appendChild(span);
                last = off + m.length;
                return m;
              });
              frag.appendChild(document.createTextNode(s.slice(last)));
              t.parentNode.replaceChild(frag, t);
            }
          }

          // 点击生词 → 词卡
          document.addEventListener('click', (e) => {
            const v = e.target.closest('.vocab-ul');
            if (!v) return;
            const w = v.getAttribute('data-word');
            if (!w) return;
            post({type: 'vocabTap', word: w, chapter: \(chapterNo)});
          }, {passive: true});

          // ready
          window.addEventListener('load', () => {
            mpApplyVocab();
            post({type: 'ready', chapter: \(chapterNo), total: \(totalChapters)});
          });

          // scroll 节流（rAF + 200ms 节流）
          let scrollTicking = false;
          let lastScrollTs = 0;
          window.addEventListener('scroll', () => {
            const now = Date.now();
            if (scrollTicking || now - lastScrollTs < 200) return;
            scrollTicking = true;
            requestAnimationFrame(() => {
              const docH = document.documentElement.scrollHeight - window.innerHeight;
              const ratio = docH > 0 ? Math.min(1, Math.max(0, window.scrollY / docH)) : 0;
              post({type: 'scroll', ratio: ratio, chapter: \(chapterNo)});
              lastScrollTs = Date.now();
              scrollTicking = false;
            });
          }, {passive: true});

          // R4：点任何批注划线（高亮/AI色/双色/虚线）→ 就地小窗（Swift 弹 NoteQuickLook）。
          // 生词虚线（.vocab-ul）另有 handler 且在文本节点更内层，closest 先命中它——保持优先。
          document.addEventListener('click', (e) => {
            if (e.target.closest('.vocab-ul')) return;
            const span = e.target.closest('[data-ids]');
            if (!span) return;
            const ids = (span.getAttribute('data-ids') || '').split(',').filter(Boolean);
            if (!ids.length) return;
            post({type: 'noteTap', noteIds: ids, chapter: \(chapterNo)});
          }, {passive: true});

          // 选段（mouseup/touchend 后取 selection）
          const reportSelection = () => {
            const sel = window.getSelection();
            if (!sel || sel.isCollapsed || !sel.toString().trim()) return;
            const text = sel.toString();
            // 计算 selection 在 article 内的字符 offset（rough，章节内）
            const range = sel.getRangeAt(0);
            const article = document.getElementById('chapter');
            if (!article) return;
            const pre = document.createRange();
            pre.selectNodeContents(article);
            pre.setEnd(range.startContainer, range.startOffset);
            const start = pre.toString().length;
            const end = start + text.length;
            post({type: 'select', text: text, start: start, end: end, chapter: \(chapterNo)});
          };
          document.addEventListener('mouseup', () => setTimeout(reportSelection, 10));
          document.addEventListener('touchend', () => setTimeout(reportSelection, 10));
        })();
        """
    }

    // MARK: - 恢复滚动位置（Swift → JS）

    /// 生成一段 JS 让 webView 滚到指定 ratio（0-1），Swift 端 evaluateJavaScript 调用。
    static func scrollToRatioScript(_ ratio: Double) -> String {
        let r = max(0, min(1, ratio))
        return """
        (function(){
          const docH = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo({top: docH * \(r), behavior: 'instant'});
        })();
        """
    }
}
