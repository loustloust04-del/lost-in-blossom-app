import SwiftUI

/// 逐词淡入的流式尾巴（09-23，对照粟粟 B6' 刀 1「逐词淡入」——她靠 fork 渲染器的 animatedByWord，
/// 我们在纯 Text 尾巴上做同款体感）：
/// 每来一批新字，把它记成一个「片段」，新片段从透明淡到不透明；老片段不动。用 Text 拼接（`+`）
/// 保证整段还是一个 Text，换行不断——所以不能给单个片段挂 .opacity，改用 AttributedString 的前景色
/// 透明度渐变：新片段 alpha 从 0 → 1，由一个 0.18s 的定时更新驱动。
/// 只在流式期间存在；定稿后整条换回 Markdown（CardFlowView 流式分支），不影响历史消息。
struct FadeInStreamingText: View {
    let text: String
    let font: Font
    let color: Color
    let lineSpacing: CGFloat

    private struct Piece { let range: Range<Int>; let bornAt: CFTimeInterval }
    @State private var pieces: [Piece] = []
    @State private var known: String = ""
    @State private var now: CFTimeInterval = CACurrentMediaTime()
    private let fadeSeconds: Double = 0.28
    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(attributed)
            .font(font)
            .lineSpacing(lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { absorb(text) }
            .onChange(of: text) { _, t in absorb(t) }
            .onReceive(ticker) { _ in
                // 还有在淡的片段才刷；全亮了就不动
                if pieces.contains(where: { now - $0.bornAt < fadeSeconds }) { now = CACurrentMediaTime() }
            }
    }

    private func absorb(_ t: String) {
        // 正常流式只在尾部追加；内容被重写（比如换段清洗）就整段重来、不淡
        if t.hasPrefix(known), t.count > known.count {
            pieces.append(Piece(range: known.count..<t.count, bornAt: CACurrentMediaTime()))
            if pieces.count > 200 { pieces.removeFirst(pieces.count - 200) }
        } else if t != known {
            pieces = [Piece(range: 0..<t.count, bornAt: 0)]
        }
        known = t
        now = CACurrentMediaTime()
    }

    private var attributed: AttributedString {
        var a = AttributedString(known)
        a.foregroundColor = color
        let chars = Array(known)
        for p in pieces where p.range.upperBound <= chars.count {
            let age = now - p.bornAt
            guard age < fadeSeconds else { continue }
            let alpha = max(0, min(1, age / fadeSeconds))
            // 片段边界从字符偏移换成 AttributedString 索引
            let lo = a.index(a.startIndex, offsetByCharacters: p.range.lowerBound)
            let hi = a.index(a.startIndex, offsetByCharacters: p.range.upperBound)
            a[lo..<hi].foregroundColor = color.opacity(alpha)
        }
        return a
    }
}
