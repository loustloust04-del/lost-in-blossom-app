import SwiftUI

/// 彩色字 / 剧透块的**原生**渲染（B 计划第一块砖：把 WebView 请出气泡）。
///
/// 语法（与 message-renderer.html 的 preprocessRichText 完全对齐）：
///   {color:红名}文字{/color}   颜色名走同一张柔和色表，也接受 #hex / 任意 CSS 名（不认的回落主色）
///   ||遮住的字||               剧透块：同色块盖住，点一下整条气泡的剧透一起显出来
/// 段内 Markdown 走 AttributedString(markdown:) 的 inline 模式（粗/斜/行内代码/链接），
/// 标题、列表本来就被 BubbleMarkdownSimplifier 抹平，不损失。
/// 含 ``` 代码块的消息暂不走这里（inline 模式画不了折叠代码块），由调用方回落 WebView。
///
/// 为什么要拆 WebView：每条彩色消息各背一个 WKWebView 进程 + 一次 HTML 加载 + marked.js 解析，
/// 长对话打开就是这些在主线程排队；气泡高度靠网页回报、靠猜（09-12「幸运气泡特别长」）。
/// 原生 Text 没有这些：高度是布局算出来的，和普通气泡一样一次成型。
struct RichBubbleText: View {
    let text: String
    let baseColor: Color
    let spoilerBg: Color
    let font: Font

    @State private var spoilersRevealed = false

    /// 走原生富文本的触发：{color:} / ||剧透||（成对且不跨行）/ ~~删除线~~（Caelum 09-14 二轮 QA：
    /// 纯 ||…|| 和 ~~…~~ 的消息之前走 MarkdownUI，前者不认、后者不显）。`a || b` 单个 || 不触发。
    static func needsRich(_ s: String) -> Bool {
        if s.contains("{color:") { return true }
        if s.range(of: #"\|\|[^|\n]+\|\|"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"~~[^~\n]+~~"#, options: .regularExpression) != nil { return true }
        return false
    }
    /// 必须走 WebView 的语法（原生画不了 / 画不好）。rich=true 时标题/引用块/代码块也回落（原生 inline
    /// 模式画不了块级）；纯文本消息的标题/引用块/代码块照旧走 MarkdownUI（抹平文档感是有意的）。
    /// 中文斜体：SwiftUI 不合成斜体，只有 WebView 的 CSS 会——含中文的 *…* / ***…*** 一律回落。
    static func needsWebView(_ s: String, rich: Bool) -> Bool {
        if rich && s.contains("```") { return true }
        if rich && s.range(of: #"(?m)^\s{0,3}#{1,6}\s"#, options: .regularExpression) != nil { return true }
        if rich && s.range(of: #"(?m)^\s{0,3}>\s"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?m)^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$"#, options: .regularExpression) != nil { return true }   // 分割线
        if s.range(of: #"\*{3}[^*\n]*[\u4e00-\u9fff][^*\n]*\*{3}"#, options: .regularExpression) != nil { return true }   // 中文粗斜体
        if s.range(of: #"(?<![*\w])\*(?!\*)[^*\n]*[\u4e00-\u9fff][^*\n]*\*(?!\*)"#, options: .regularExpression) != nil { return true }   // 中文斜体
        if s.range(of: #"(?<![_\w])_(?!_)[^_\n]*[\u4e00-\u9fff][^_\n]*_(?![_\w])"#, options: .regularExpression) != nil { return true }
        return false
    }
    var body: some View {
        Text(Self.build(text, base: baseColor, spoilerBg: spoilerBg, revealed: spoilersRevealed))
            .font(font)
            .textSelection(.enabled)
            .contentShape(Rectangle())
            .onTapGesture {
                if text.contains("||") {
                    withAnimation(.easeInOut(duration: 0.25)) { spoilersRevealed.toggle() }
                }
            }
    }

    // ── 解析 ──

    /// 与网页版 richColorMap 同一张表
    static let colorMap: [String: Color] = [
        "red": Color(hexString: "#C25B61"), "blue": Color(hexString: "#5878A4"),
        "purple": Color(hexString: "#907AB3"), "green": Color(hexString: "#5E9474"),
        "orange": Color(hexString: "#C4855A"), "yellow": Color(hexString: "#B89B3E"),
        "pink": Color(hexString: "#C4748E"), "cyan": Color(hexString: "#4E9DA8"),
        "brown": Color(hexString: "#9E7B5D"), "magenta": Color(hexString: "#A86B94"),
        "violet": Color(hexString: "#8B72B0"), "gold": Color(hexString: "#B8963E"),
        "crimson": Color(hexString: "#B44D5A"), "indigo": Color(hexString: "#6B6BAD"),
        "teal": Color(hexString: "#4D9489"),
    ]

    enum Segment {
        case plain(String)
        case colored(String, Color?)
        case spoiler(String)
    }

    /// 顺序切段：{color:x}…{/color} 与 ||…|| 两种标记，其余是 plain。不嵌套（网页版也不嵌套）。
    static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            let c = rest.range(of: "{color:")
            let p = rest.range(of: "||")
            // 取最先出现的标记
            let next: (Range<Substring.Index>, Bool)? = {
                switch (c, p) {
                case (nil, nil): return nil
                case (let c?, nil): return (c, true)
                case (nil, let p?): return (p, false)
                case (let c?, let p?): return c.lowerBound <= p.lowerBound ? (c, true) : (p, false)
                }
            }()
            guard let (start, isColor) = next else { out.append(.plain(String(rest))); break }
            if start.lowerBound > rest.startIndex { out.append(.plain(String(rest[rest.startIndex..<start.lowerBound]))) }
            if isColor {
                // {color:NAME}inner{/color}
                guard let close = rest[start.upperBound...].firstIndex(of: "}"),
                      let end = rest.range(of: "{/color}", range: close..<rest.endIndex)
                else { out.append(.plain(String(rest[start.lowerBound...]))); break }
                let name = rest[start.upperBound..<close].trimmingCharacters(in: .whitespaces).lowercased()
                let inner = String(rest[rest.index(after: close)..<end.lowerBound])
                out.append(.colored(inner, colorMap[name] ?? (name.hasPrefix("#") ? Color(hexString: name) : nil)))
                rest = rest[end.upperBound...]
            } else {
                // ||inner||（不跨行，和网页正则 .+? 一致）
                let after = rest[start.upperBound...]
                guard let end = after.range(of: "||"), !after[after.startIndex..<end.lowerBound].contains("\n"),
                      end.lowerBound > after.startIndex
                else { out.append(.plain(String(rest[start.lowerBound..<start.upperBound]))); rest = rest[start.upperBound...]; continue }
                out.append(.spoiler(String(after[after.startIndex..<end.lowerBound])))
                rest = after[end.upperBound...]
            }
        }
        return out
    }

    static func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func build(_ s: String, base: Color, spoilerBg: Color, revealed: Bool) -> AttributedString {
        var result = AttributedString()
        for seg in segments(s) {
            switch seg {
            case .plain(let t):
                result += inlineMarkdown(t)
            case .colored(let t, let color):
                // 彩色段里可以套剧透：{color:x}…||遮住||…{/color}（Caelum QA：组合渲染）
                for inner in segments(t) {
                    switch inner {
                    case .spoiler(let st):
                        var a = inlineMarkdown(st)
                        a.backgroundColor = revealed ? spoilerBg.opacity(0.18) : spoilerBg
                        a.foregroundColor = revealed ? (color ?? base) : .clear
                        result += a
                    case .plain(let pt), .colored(let pt, _):
                        var a = inlineMarkdown(pt)
                        a.foregroundColor = color ?? base
                        result += a
                    }
                }
            case .spoiler(let t):
                var a = inlineMarkdown(t)
                a.backgroundColor = revealed ? spoilerBg.opacity(0.18) : spoilerBg
                a.foregroundColor = revealed ? base : .clear
                result += a
            }
        }
        return result
    }
}
