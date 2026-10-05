import SwiftUI
import Charts

/// 对话卡片（10-04，收粟粟的菜：她的 ChatCard 体系 9-26 起）。
/// 他在回复里写一段 ```card-<类型> + JSON 的代码块，App 就把它画成原生卡片，不当代码显示。
/// v1：ask（单选/多选/问答）、dice（骰子/抽签）。后面：music（接网易云/一起听）、todo、chart。
enum ChatCardParser {
    enum Segment { case text(String); case card(ChatCard) }

    /// 把正文切成「文字 / 卡片」交替的段；没有卡片返回 nil（调用方照旧整段 Markdown）
    static func split(_ text: String) -> [Segment]? {
        guard text.contains("```") else { return nil }
        let pattern = #"```(card-)?([a-z]+)[ \t]*\n([\s\S]*?)\n```"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        var out: [Segment] = []
        var cursor = 0
        var found = false
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hasPrefix = m.range(at: 1).location != NSNotFound
            let kind = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3))
            // 简写（```ask）只在 JSON 严格解析成卡片时才算——免得普通代码块被吞（粟粟 42ba1cc1 同款）
            guard let card = ChatCard.parse(kind: kind, json: body), hasPrefix || ChatCard.shorthandKinds.contains(kind) else { continue }
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(before)) }
            out.append(.card(card))
            cursor = m.range.location + m.range.length
            found = true
        }
        guard found else { return nil }
        let rest = ns.substring(from: cursor)
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(rest)) }
        return out
    }
}

enum ChatCard {
    case ask(AskCard)
    case dice(DiceCard)
    case music(MusicCard)
    case todo(TodoCard)
    case chart(ChartCard)

    static let shorthandKinds: Set<String> = ["ask", "dice", "music", "todo", "chart"]

    static func parse(kind: String, json: String) -> ChatCard? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch kind {
        case "ask": return AskCard(obj).map { .ask($0) }
        case "dice": return DiceCard(obj).map { .dice($0) }
        case "music": return MusicCard(obj).map { .music($0) }
        case "todo": return TodoCard(obj).map { .todo($0) }
        case "chart": return ChartCard(obj).map { .chart($0) }
        default: return nil
        }
    }
}

/// 卡片作答 → 当作她的一条消息发给他（输入条监听 composerSendNow）
extension Notification.Name {
    static let composerSendNow = Notification.Name("composerSendNow")
}

/// 作答记录（本机）：消息 id + 卡序号 → 答案，答过的卡显示已答态
enum CardAnswerStore {
    private static let key = "chatCardAnswers"
    static func get(_ k: String) -> String? { (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[k] }
    static func set(_ k: String, _ v: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[k] = v
        UserDefaults.standard.set(d, forKey: key)
    }
}

// MARK: - 提问卡

struct AskCard {
    let question: String
    let options: [String]
    let multi: Bool
    let allowText: Bool

    init?(_ o: [String: Any]) {
        guard let q = o["question"] as? String ?? o["q"] as? String else { return nil }
        question = q
        options = (o["options"] as? [Any])?.compactMap { "\($0)" } ?? []
        multi = (o["multi"] as? Bool) ?? false
        allowText = (o["text"] as? Bool) ?? options.isEmpty    // 没有选项 = 问答
    }
}

struct AskCardView: View {
    let card: AskCard
    let answerKey: String
    @State private var picked: Set<String> = []
    @State private var typed = ""
    @State private var answered: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").font(.system(size: 13)).foregroundColor(Theme.branchIndicator)
                Text(card.question).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
            }
            if let a = answered {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.branchIndicator)
                    Text(a).font(.system(size: 13)).foregroundColor(Theme.textMuted)
                }
            } else {
                ForEach(card.options, id: \.self) { opt in
                    let on = picked.contains(opt)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if card.multi { if on { picked.remove(opt) } else { picked.insert(opt) } }
                        else { submit(opt) }
                    } label: {
                        HStack {
                            if card.multi {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundColor(on ? Theme.branchIndicator : Theme.textMuted)
                            }
                            Text(opt).font(.system(size: 14)).foregroundColor(Theme.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.branchIndicator.opacity(0.12) : Theme.textMuted.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
                if card.allowText {
                    HStack {
                        TextField(card.options.isEmpty ? "写下你的回答" : "或者自己写", text: $typed)
                            .font(.system(size: 14))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textMuted.opacity(0.07)))
                        Button("发") { submit(typed) }
                            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.branchIndicator)
                    }
                }
                if card.multi {
                    Button { submit(card.options.filter { picked.contains($0) }.joined(separator: "、")) } label: {
                        Text("选好了").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Capsule().fill(picked.isEmpty ? Theme.textMuted.opacity(0.3) : Theme.branchIndicator))
                    }
                    .buttonStyle(.plain).disabled(picked.isEmpty)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg.opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)))
        .onAppear { answered = CardAnswerStore.get(answerKey) }
    }

    private func submit(_ a: String) {
        let ans = a.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ans.isEmpty else { return }
        answered = ans
        CardAnswerStore.set(answerKey, ans)
        NotificationCenter.default.post(name: .composerSendNow, object: nil,
                                        userInfo: ["text": "（回答「\(card.question)」：\(ans)）"])
    }
}

// MARK: - 骰子卡

struct DiceCard {
    let title: String?
    let count: Int          // 骰子个数
    let sides: Int
    let result: [Int]?      // 他已经掷好的（有就直接演到这个点数）
    let picks: [String]     // 非空 = 抽签：在这些选项里跑马灯

    init?(_ o: [String: Any]) {
        title = o["title"] as? String
        count = max(1, min(6, (o["count"] as? Int) ?? 1))
        sides = max(2, min(100, (o["sides"] as? Int) ?? 6))
        result = (o["result"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") }
        picks = (o["picks"] as? [Any])?.compactMap { "\($0)" } ?? []
    }
}

struct DiceCardView: View {
    let card: DiceCard
    let answerKey: String
    @State private var faces: [Int] = []
    @State private var rolling = false
    @State private var pickIndex: Int? = nil
    @State private var done: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: card.picks.isEmpty ? "dice" : "sparkles").font(.system(size: 13)).foregroundColor(Theme.branchIndicator)
                Text(card.title ?? (card.picks.isEmpty ? "掷骰子" : "抽一个")).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
            }
            if card.picks.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(faces.enumerated()), id: \.offset) { _, f in
                        DieFace(value: f, sides: card.sides)
                            .rotation3DEffect(.degrees(rolling ? 360 : 0), axis: (x: 1, y: 1, z: 0))
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(card.picks.enumerated()), id: \.offset) { i, p in
                        Text(p).font(.system(size: 14))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(pickIndex == i ? Theme.branchIndicator.opacity(0.25) : Theme.textMuted.opacity(0.07)))
                    }
                }
            }
            if let d = done {
                Text(d).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.branchIndicator)
            } else if card.result == nil {
                Button { roll(sendBack: true) } label: {
                    Text(card.picks.isEmpty ? "掷！" : "抽！").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Capsule().fill(rolling ? Theme.textMuted.opacity(0.3) : Theme.branchIndicator))
                }
                .buttonStyle(.plain).disabled(rolling)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg.opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)))
        .onAppear {
            faces = Array(repeating: 1, count: card.count)
            if let saved = CardAnswerStore.get(answerKey) { done = saved; restore(saved) }
            else if card.result != nil { roll(sendBack: false) }      // 他掷好的：演一遍
        }
    }

    private func restore(_ s: String) {
        if !card.picks.isEmpty { pickIndex = card.picks.firstIndex { s.contains($0) } }
        else { let n = s.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init); if n.count >= card.count { faces = Array(n.prefix(card.count)) } }
    }

    private func roll(sendBack: Bool) {
        rolling = true
        var g = SystemRandomNumberGenerator()
        let finalFaces = card.result.map { Array($0.prefix(card.count)) } ?? (0..<card.count).map { _ in Int.random(in: 1...card.sides, using: &g) }
        let finalPick = card.picks.isEmpty ? nil : Int.random(in: 0..<card.picks.count, using: &g)
        // 减速翻滚：间隔越来越长
        let steps = 14
        for i in 0..<steps {
            let delay = 0.04 * Double(i) + 0.006 * Double(i * i)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if card.picks.isEmpty { faces = (0..<card.count).map { _ in Int.random(in: 1...card.sides) } }
                else { pickIndex = ((pickIndex ?? -1) + 1) % card.picks.count }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
            }
        }
        let end = 0.04 * Double(steps) + 0.006 * Double(steps * steps)
        withAnimation(.easeOut(duration: end)) { }
        DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            var text: String
            if let p = finalPick { pickIndex = p; text = "抽到：\(card.picks[p])" }
            else { faces = finalFaces; text = "掷出：" + finalFaces.map(String.init).joined(separator: " + ") + (card.count > 1 ? " = \(finalFaces.reduce(0, +))" : "") }
            rolling = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            done = text
            CardAnswerStore.set(answerKey, text)
            if sendBack {
                NotificationCenter.default.post(name: .composerSendNow, object: nil,
                                                userInfo: ["text": "（\(card.title ?? (card.picks.isEmpty ? "骰子" : "抽签"))\(text)）"])
            }
        }
    }
}

private struct DieFace: View {
    let value: Int
    let sides: Int
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.white)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            if sides == 6 { pips } else {
                Text("\(value)").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(Color(red: 0.25, green: 0.22, blue: 0.2))
            }
        }
        .frame(width: 46, height: 46)
    }
    private var pips: some View {
        let pos: [Int: [(CGFloat, CGFloat)]] = [
            1: [(0.5, 0.5)], 2: [(0.25, 0.25), (0.75, 0.75)], 3: [(0.25, 0.25), (0.5, 0.5), (0.75, 0.75)],
            4: [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)],
            5: [(0.25, 0.25), (0.75, 0.25), (0.5, 0.5), (0.25, 0.75), (0.75, 0.75)],
            6: [(0.25, 0.22), (0.75, 0.22), (0.25, 0.5), (0.75, 0.5), (0.25, 0.78), (0.75, 0.78)],
        ]
        return GeometryReader { g in
            ForEach(Array((pos[value] ?? []).enumerated()), id: \.offset) { _, p in
                Circle().fill(value == 1 ? Color(red: 0.83, green: 0.35, blue: 0.33) : Color(red: 0.25, green: 0.22, blue: 0.2))
                    .frame(width: 8, height: 8)
                    .position(x: g.size.width * p.0, y: g.size.height * p.1)
            }
        }
    }
}

/// 一条回复里「文字 + 卡片」交替渲染
struct ChatCardSegmentsView<TextBody: View>: View {
    let segments: [ChatCardParser.Segment]
    let nodeId: String
    let textBody: (String) -> TextBody

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                switch seg {
                case .text(let t): textBody(t)
                case .card(.ask(let c)): AskCardView(card: c, answerKey: "\(nodeId)#\(i)")
                case .card(.dice(let c)): DiceCardView(card: c, answerKey: "\(nodeId)#\(i)")
                case .card(.music(let c)): MusicCardView(card: c)
                case .card(.todo(let c)): TodoCardView(card: c, answerKey: "\(nodeId)#\(i)")
                case .card(.chart(let c)): ChartCardView(card: c)
                }
            }
        }
    }
}

// MARK: - 待办卡（10-05）：他列的几件事，一点「加入」就进她的待办

struct TodoCard {
    let title: String?
    let items: [String]
    init?(_ o: [String: Any]) {
        title = o["title"] as? String
        let arr = (o["items"] as? [Any])?.compactMap { "\($0)" } ?? ((o["item"] as? String).map { [$0] } ?? [])
        guard !arr.isEmpty else { return nil }
        items = Array(arr.prefix(12))
    }
}

struct TodoCardView: View {
    let card: TodoCard
    let answerKey: String
    @State private var added: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 13)).foregroundColor(Theme.branchIndicator)
                Text(card.title ?? "待办").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Spacer()
                if added.count < card.items.count {
                    Button("全部加入") { card.items.forEach(add) }
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Theme.branchIndicator)
                }
            }
            ForEach(card.items, id: \.self) { it in
                let done = added.contains(it)
                HStack {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(done ? Theme.branchIndicator : Theme.textMuted)
                    Text(it).font(.system(size: 14)).foregroundColor(done ? Theme.textMuted : Theme.textPrimary)
                    Spacer()
                    if !done {
                        Button { add(it) } label: {
                            Text("加入").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.branchIndicator)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().stroke(Theme.branchIndicator.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("已加入").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg.opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)))
        .onAppear {
            if let s = CardAnswerStore.get(answerKey) { added = Set(s.components(separatedBy: "\u{1F}").filter { !$0.isEmpty }) }
        }
    }

    private func add(_ it: String) {
        guard !added.contains(it) else { return }
        TodoManager.shared.add(it)
        added.insert(it)
        CardAnswerStore.set(answerKey, added.joined(separator: "\u{1F}"))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - 图表卡（10-05）：柱状 / 折线 / 环形，点一下看数值


struct ChartCard {
    enum Kind: String { case bar, line, ring }
    struct Point: Identifiable { let id = UUID(); let label: String; let value: Double; let series: String }
    let kind: Kind
    let title: String?
    let unit: String
    let points: [Point]

    init?(_ o: [String: Any]) {
        kind = Kind(rawValue: (o["type"] as? String ?? "bar").lowercased()) ?? .bar
        title = o["title"] as? String
        unit = o["unit"] as? String ?? ""
        let labels = (o["labels"] as? [Any])?.map { "\($0)" } ?? []
        var pts: [Point] = []
        if let series = o["series"] as? [[String: Any]] {
            for s in series {
                let name = s["name"] as? String ?? ""
                let vals = (s["values"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") } ?? []
                for (i, v) in vals.enumerated() where i < labels.count { pts.append(Point(label: labels[i], value: v, series: name)) }
            }
        } else {
            let vals = (o["values"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") } ?? []
            for (i, v) in vals.enumerated() where i < labels.count { pts.append(Point(label: labels[i], value: v, series: "")) }
        }
        guard !pts.isEmpty else { return nil }
        points = Array(pts.prefix(60))
    }
}

struct ChartCardView: View {
    let card: ChartCard
    @State private var picked: String? = nil

    private var multi: Bool { Set(card.points.map(\.series)).count > 1 }
    private var pickedText: String? {
        guard let p = picked else { return nil }
        let rows = card.points.filter { $0.label == p }
        guard !rows.isEmpty else { return nil }
        return p + "：" + rows.map { (multi ? "\($0.series) " : "") + fmt($0.value) + card.unit }.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.kind == .ring ? "chart.pie" : (card.kind == .line ? "chart.xyaxis.line" : "chart.bar"))
                    .font(.system(size: 13)).foregroundColor(Theme.branchIndicator)
                Text(card.title ?? "图表").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Spacer()
                if let t = pickedText {
                    Text(t).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.branchIndicator).lineLimit(1)
                }
            }
            chart.frame(height: card.kind == .ring ? 180 : 170)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg.opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)))
    }

    @ViewBuilder private var chart: some View {
        switch card.kind {
        case .bar:
            Chart(card.points) { p in
                BarMark(x: .value("项", p.label), y: .value("值", p.value))
                    .foregroundStyle(by: .value("组", multi ? p.series : "·"))
                    .opacity(picked == nil || picked == p.label ? 1 : 0.35)
                    .cornerRadius(4)
            }
            .chartLegend(multi ? .visible : .hidden)
            .chartXSelection(value: $picked)
        case .line:
            Chart(card.points) { p in
                LineMark(x: .value("项", p.label), y: .value("值", p.value))
                    .foregroundStyle(by: .value("组", multi ? p.series : "·"))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("项", p.label), y: .value("值", p.value))
                    .foregroundStyle(by: .value("组", multi ? p.series : "·"))
                    .symbolSize(picked == p.label ? 80 : 24)
                if picked == p.label {
                    RuleMark(x: .value("项", p.label)).foregroundStyle(Theme.textMuted.opacity(0.4))
                }
            }
            .chartLegend(multi ? .visible : .hidden)
            .chartXSelection(value: $picked)
        case .ring:
            let total = card.points.reduce(0) { $0 + $1.value }
            Chart(card.points) { p in
                SectorMark(angle: .value("值", p.value), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .foregroundStyle(by: .value("项", p.label))
                    .opacity(picked == nil || picked == p.label ? 1 : 0.4)
                    .cornerRadius(3)
            }
            .chartAngleSelection(value: Binding(get: { nil as Double? }, set: { v in
                guard let v else { picked = nil; return }
                var acc = 0.0
                for p in card.points { acc += p.value; if v <= acc { picked = p.label; break } }
            }))
            .overlay {
                VStack(spacing: 0) {
                    Text(fmt(total) + card.unit).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text("合计").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
