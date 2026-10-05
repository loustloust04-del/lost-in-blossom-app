import SwiftUI
import Observation

/// 引用回复（10-03，对照粟粟 270caf66 三刀；我们不加数据库字段——引用作为 [引用]…[/引用] 前缀存进正文，
/// 模型看得到；显示时剥掉、在气泡顶上画成引用条）。
@MainActor
@Observable
final class QuoteDraft {
    static let shared = QuoteDraft()
    /// 当前要引用的那一句（输入条上方显示，发送时带走）
    var pending: Quote? = nil

    struct Quote: Equatable {
        let who: String       // 「他」/「你」
        let text: String      // ≤80 字
    }

    func set(from node: MessageNode, assistantName: String) {
        let raw = ContentCleaner.clean(String(node.content.prefix(600)))
        let body = node.role == "assistant" ? ContentCleaner.extractThinking(from: raw).content : raw
        let line = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        pending = Quote(who: node.role == "assistant" ? assistantName : "我",
                        text: line.count > 80 ? String(line.prefix(80)) + "…" : line)
    }

    /// 发送时：取走并清空，返回要前置的标记
    func take() -> String? {
        guard let q = pending else { return nil }
        pending = nil
        return "[引用]\(q.who)：\(q.text)[/引用]"
    }

    /// 气泡要画的引用（先跳过回应捎带段）
    static func quoteOf(_ content: String) -> String? {
        var c = content
        if c.hasPrefix("[回应]"), let r = c.range(of: "[/回应]") {
            c = String(c[r.upperBound...]); if c.hasPrefix("\n") { c.removeFirst() }
        }
        return parse(c).quote
    }

    /// 从正文开头解析引用（显示用）
    static func parse(_ content: String) -> (quote: String?, rest: String) {
        guard content.hasPrefix("[引用]"), let end = content.range(of: "[/引用]") else { return (nil, content) }
        let q = String(content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound])
        var rest = String(content[end.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        return (q, rest)
    }
}

/// 气泡顶上的引用条
struct QuoteStrip: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.branchIndicator.opacity(0.7)).frame(width: 3)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.textMuted.opacity(0.08)))
        .fixedSize(horizontal: false, vertical: true)
    }
}
