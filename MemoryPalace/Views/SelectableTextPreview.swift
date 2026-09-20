import SwiftUI
import UIKit

/// 长按浮层里的「可选中复制」预览（B round 11）。
/// 兔兔 09-15：浮层里的气泡副本长按选不了字。MarkdownUI 的 Markdown 视图不支持 textSelection（库的已知
/// 限制），粟粟那边能选是因为她的渲染器是自己 fork 的。这里换个思路：浮层预览用 UITextView——UIKit 原生
/// 选字、拖手柄、复制一条龙，而且浮层挂在 window 层不在翻转列表里，没有「只翻一次」的雷。
/// 富文本用 AttributedString(markdown:) 全模式画（粗/斜/删除线/行内代码/列表/标题），中文斜体 UIKit 会合成。
struct SelectableTextPreview: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: UIColor

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = [.link]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = Self.render(text, size: fontSize, color: textColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 320
        let h = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: w, height: h)
    }

    static func render(_ raw: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        // {color:x}…{/color} / ||…|| 先剥成纯文字（预览只为选字复制，样式够用就行）
        var s = raw.replacingOccurrences(of: #"\{color:[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "{/color}", with: "")
            .replacingOccurrences(of: "||", with: "")
        if s.isEmpty { s = raw }
        let base: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color]
        guard var a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: s, attributes: base)
        }
        // 段落间留一行（.full 模式段落之间没有换行）
        let ns = NSMutableAttributedString(a)
        ns.addAttributes(base, range: NSRange(location: 0, length: ns.length))
        // 把 inline intent 翻成字体特征（粗/斜/等宽/删除线）
        a = AttributedString(ns)
        let out = NSMutableAttributedString(a)
        for run in a.runs {
            let r = NSRange(run.range, in: a)
            if let intent = run.inlinePresentationIntent {
                var desc = UIFont.systemFont(ofSize: size).fontDescriptor
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty, let d = desc.withSymbolicTraits(traits) { desc = d }
                if intent.contains(.code) { desc = UIFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular).fontDescriptor }
                out.addAttribute(.font, value: UIFont(descriptor: desc, size: size), range: r)
                if intent.contains(.strikethrough) { out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
                if intent.contains(.emphasized), UIFont(descriptor: desc, size: size).fontDescriptor.symbolicTraits.contains(.traitItalic) == false {
                    out.addAttribute(.obliqueness, value: 0.2, range: r)   // 中文没有斜体面，合成一下
                }
            }
            if let pi = run.presentationIntent {
                // 段落 / 标题 / 列表：段尾补换行，标题加粗放大
                var isHeader = false; var level = 0
                for c in pi.components { if case .header(let l) = c.kind { isHeader = true; level = l } }
                if isHeader {
                    let hs = size * (level == 1 ? 1.5 : level == 2 ? 1.3 : 1.15)
                    out.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: hs), range: r)
                }
            }
        }
        // 块与块之间补一个换行（.full 模式把段落 intent 交给渲染器，NSAttributedString 里不自带换行）
        let result = NSMutableAttributedString()
        var lastBlock: Int? = nil
        for run in a.runs {
            let blockId = run.presentationIntent?.components.first?.identity
            if let lb = lastBlock, blockId != lb { result.append(NSAttributedString(string: "\n\n", attributes: base)) }
            lastBlock = blockId
            result.append(out.attributedSubstring(from: NSRange(run.range, in: a)))
        }
        return result.length > 0 ? result : NSAttributedString(string: s, attributes: base)
    }
}
