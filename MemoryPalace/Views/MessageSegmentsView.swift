import SwiftUI
import MarkdownUI

// MARK: - Rich Text 预处理（彩色文字 + spoiler 黑块）

/// `.text` 段在走 Markdown 渲染前的切片结果。
/// - markdown: 普通 Markdown 文本，走原有 MarkdownUI 路径
/// - colored: `{color:xxx}...{/color}` 彩色文字
/// - spoiler: `||...||` 点击展开的黑块
enum RichSegment {
    case markdown(String)
    case colored(String, Color)
    case spoiler(String)
}

/// 扫描文本，识别 {color:xxx}...{/color} 和 ||...|| 自定义语法，切成片段数组。
/// 没有命中任何语法时返回单个 .markdown(text)，让上层走原有渲染路径（零成本）。
func parseRichSegments(_ text: String) -> [RichSegment] {
    var segments: [RichSegment] = []
    var remaining = text[text.startIndex...]

    while !remaining.isEmpty {
        // 找最近的自定义标记
        let colorStart = remaining.range(of: "{color:")
        let spoilerStart = remaining.range(of: "||")

        // 取最先出现的那个
        let firstColor = colorStart?.lowerBound
        let firstSpoiler = spoilerStart?.lowerBound

        // 都没有 → 剩余全部是 markdown
        if firstColor == nil && firstSpoiler == nil {
            let s = String(remaining)
            if !s.isEmpty { segments.append(.markdown(s)) }
            break
        }

        // 判断谁先出现
        let colorFirst = firstColor != nil && (firstSpoiler == nil || firstColor! < firstSpoiler!)

        if colorFirst, let cStart = firstColor {
            // ── 处理 {color:xxx}...{/color} ──
            // 标记前的普通文本
            if cStart > remaining.startIndex {
                let plain = String(remaining[remaining.startIndex..<cStart])
                if !plain.isEmpty { segments.append(.markdown(plain)) }
            }

            // 找 } 关闭标签获取颜色名
            let afterColorColon = remaining[cStart...].dropFirst("{color:".count)
            if let closeBrace = afterColorColon.range(of: "}") {
                let colorName = String(afterColorColon[afterColorColon.startIndex..<closeBrace.lowerBound])
                let contentStart = closeBrace.upperBound

                // 找 {/color}
                if let endTag = remaining[contentStart...].range(of: "{/color}") {
                    let content = String(remaining[contentStart..<endTag.lowerBound])
                    segments.append(.colored(content, colorFromName(colorName)))
                    remaining = remaining[endTag.upperBound...]
                    continue
                }
            }
            // 格式不完整 → 当普通文本，跳过 {color: 继续
            let skip = String(remaining[remaining.startIndex...cStart])
            segments.append(.markdown(skip))
            remaining = remaining[remaining.index(after: cStart)...]

        } else if let sStart = firstSpoiler {
            // ── 处理 ||...|| ──
            // 标记前的普通文本
            if sStart > remaining.startIndex {
                let plain = String(remaining[remaining.startIndex..<sStart])
                if !plain.isEmpty { segments.append(.markdown(plain)) }
            }

            let contentStart = remaining.index(sStart, offsetBy: 2)
            if contentStart < remaining.endIndex,
               let endMarker = remaining[contentStart...].range(of: "||") {
                let content = String(remaining[contentStart..<endMarker.lowerBound])
                if !content.isEmpty {
                    segments.append(.spoiler(content))
                    remaining = remaining[endMarker.upperBound...]
                    continue
                }
            }
            // 格式不完整 → 当普通文本
            let skip = String(remaining[remaining.startIndex..<remaining.index(sStart, offsetBy: min(2, remaining.distance(from: sStart, to: remaining.endIndex)))])
            segments.append(.markdown(skip))
            remaining = remaining[remaining.index(sStart, offsetBy: min(2, remaining.distance(from: sStart, to: remaining.endIndex)))...]
        }
    }

    return segments.isEmpty ? [.markdown(text)] : segments
}

func colorFromName(_ name: String) -> Color {
    switch name.lowercased() {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "purple": return .purple
    case "pink": return .pink
    case "yellow": return .yellow
    case "cyan": return .cyan
    case "white": return .white
    case "gray", "grey": return .gray
    default: return Theme.textPrimary
    }
}

/// 按顺序渲染 Claude v2 导入的 [MessageSegment]。
/// - 每段独立折叠（思考 = DisclosureGroup；工具 = 可展开卡片）
/// - toolUse 后紧跟的同 id toolResult 会合并成一张卡片
/// - 样式沿用现有 Theme 调色盘（mainBg + textMuted），不引新色
struct MessageSegmentsView: View {
    let segments: [MessageSegment]
    let selectedFont: String
    let fontScale: Double
    let lineSpacingScale: Double
    let paragraphSpacingScale: Double
    let regexScripts: [RegexScript]
    /// user 气泡字体 / 对齐跟 assistant 不一样；text 段按此切换渲染。
    var isUser: Bool = false
    /// 粟粟接口对齐（气泡整套搬运）：气泡模式传入，用她的调用点签名。
    /// simplifyMarkdown=true 时 text 段渲染前过 BubbleMarkdownSimplifier（抹平文档感）。
    var profileId: String = ""
    var simplifyMarkdown: Bool = false
    var nodeId: String? = nil
    var onQuoteText: ((String) -> Void)? = nil

    /// 外观 - 消息显示 - 「显示安全提示卡」开关。粟粟觉得 flag 卡丑可关掉。
    @AppStorage("showFlagBlocks") private var showFlagBlocks: Bool = true

    /// 合并后的渲染条目
    fileprivate enum Item {
        case text(String)
        case thinking(String)
        case toolPair(name: String, inputJSON: String, resultText: String?, isError: Bool, integration: String?)
        case orphanToolResult(text: String, isError: Bool, integration: String?)
        case flag(kind: String, helplineLine: String?, helplineUrl: String?)
        case attachment(name: String, type: String?, content: String?)
        case file(name: String)
    }

    private var items: [Item] {
        var result: [Item] = []
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            switch seg {
            case .text(let s):
                // 占位行由胶囊代言，正文里摘掉（否则文字与胶囊同时出现）
                result.append(.text(VoiceMessageWriter.strippedForDisplay(s)))
                i += 1
            case .thinking(let text, _):
                result.append(.thinking(text))
                i += 1
            case .toolUse(let id, let name, let inputJSON, let integration, _):
                // Peek next: 若紧邻的是匹配 id 的 toolResult → 配对
                if i + 1 < segments.count,
                   case let .toolResult(toolUseId, text, isError, resultIntegration) = segments[i + 1],
                   toolUseId == id {
                    result.append(.toolPair(
                        name: name,
                        inputJSON: inputJSON,
                        resultText: text,
                        isError: isError,
                        integration: integration ?? resultIntegration
                    ))
                    i += 2
                } else {
                    // 没有配对的 result（罕见；防御）
                    result.append(.toolPair(
                        name: name,
                        inputJSON: inputJSON,
                        resultText: nil,
                        isError: false,
                        integration: integration
                    ))
                    i += 1
                }
            case .toolResult(_, let text, let isError, let integration):
                // 没有配对的 toolUse 的孤儿 result（防御）
                result.append(.orphanToolResult(text: text, isError: isError, integration: integration))
                i += 1
            case .flag(let kind, let hName, let hPhone, let hUrl):
                var parts: [String] = []
                if let hName, !hName.isEmpty { parts.append(hName) }
                if let hPhone, !hPhone.isEmpty { parts.append(hPhone) }
                result.append(.flag(
                    kind: kind,
                    helplineLine: parts.isEmpty ? nil : parts.joined(separator: " · "),
                    helplineUrl: hUrl
                ))
                i += 1
            case .attachment(let name, let type, let extracted):
                result.append(.attachment(name: name, type: type, content: extracted))
                i += 1
            case .file(let name, _):
                result.append(.file(name: name))
                i += 1
            case .image, .fileData:
                // 图片/文件字节段：气泡模式在 BubbleAttachmentStrip 渲染，文章模式段内跳过
                i += 1
            case .audioRef:
                // 语音条不进 segments 渲染——VoiceCapsuleView 在气泡层单独画胶囊
                i += 1
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let resolved = items
            ForEach(resolved.indices, id: \.self) { idx in
                itemView(resolved[idx])
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: Item) -> some View {
        switch item {
        case .text(let s):
            let applied = regexScripts.isEmpty
                ? s
                : RegexEngine.apply(scripts: regexScripts, text: s, messagePlacement: 2, isMarkdown: true)
            if !applied.isEmpty {
                if isUser {
                    let richSegs = parseRichSegments(applied)
                    if richSegs.count == 1, case .markdown = richSegs[0] {
                        // 纯文本，保留用户气泡字体路径
                        Text(applied)
                            .font(FontManager.font(size: 13.5))
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(4 * (fontScale > 0 ? fontScale : 1.0) * lineSpacingScale)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // 含富文本标记，逐段渲染
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(richSegs.enumerated()), id: \.offset) { _, seg in
                                richSegmentView(seg)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    let richSegments = parseRichSegments(applied)
                    if richSegments.count == 1, case .markdown = richSegments[0] {
                        // 纯 Markdown，走原有渲染路径（零成本）；抹平文档感（assistant 分支）
                        Markdown(BubbleMarkdownSimplifier.simplify(applied))
                            .markdownTheme(.memoryPalace(
                                fontName: selectedFont,
                                scale: fontScale > 0 ? fontScale : 1.0,
                                lineSpacingScale: lineSpacingScale,
                                paragraphSpacingScale: paragraphSpacingScale
                            ))
                            .textSelection(.enabled)
                    } else {
                        // 混合内容，逐段渲染
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(richSegments.enumerated()), id: \.offset) { _, seg in
                                richSegmentView(seg)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .thinking(let s):
            ThinkingBlockView(text: s)
        case .toolPair(let name, let inputJSON, let resultText, let isError, let integration):
            // 搜索/读网页走专用卡片（Claude App 风格：查询词 + 来源列表），
            // 其他工具维持通用 🔧 卡
            if name == WebSearchToolService.toolName {
                SearchActivityCardView(inputJSON: inputJSON, resultText: resultText, isError: isError)
            } else if name == BrowseURLTool.toolName {
                BrowseActivityCardView(inputJSON: inputJSON, resultText: resultText, isError: isError)
            } else {
                ToolCallCardView(
                    name: name,
                    inputJSON: inputJSON,
                    resultText: resultText,
                    isError: isError,
                    integration: integration
                )
            }
        case .orphanToolResult(let text, let isError, let integration):
            ToolCallCardView(
                name: isError ? "tool 结果（失败）" : "tool 结果",
                inputJSON: "",
                resultText: text,
                isError: isError,
                integration: integration
            )
        case .flag(let kind, let helplineLine, let helplineUrl):
            if showFlagBlocks {
                FlagCardView(kind: kind, helplineLine: helplineLine, helplineUrl: helplineUrl)
            }
        case .attachment(let name, let type, let content):
            AttachmentCardView(name: name, type: type, extractedContent: content)
        case .file(let name):
            HStack(spacing: 6) {
                Text("🖼")
                    .font(.system(size: 11))
                Text(name.isEmpty ? "(图片)" : name)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    /// 混合 rich text 模式下的单段渲染分发。
    @ViewBuilder
    private func richSegmentView(_ seg: RichSegment) -> some View {
        let scale = fontScale > 0 ? fontScale : 1.0
        switch seg {
        case .markdown(let md):
            Markdown(isUser ? md : BubbleMarkdownSimplifier.simplify(md))
                .markdownTheme(.memoryPalace(
                    fontName: selectedFont,
                    scale: scale,
                    lineSpacingScale: lineSpacingScale,
                    paragraphSpacingScale: paragraphSpacingScale
                ))
                .textSelection(.enabled)
        case .colored(let text, let color):
            Text(text)
                .foregroundColor(color)
                .font(.system(size: 13.5 * scale))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .spoiler(let text):
            SpoilerView(text: text)
                .font(.system(size: 13.5 * scale))
        }
    }
}

// MARK: - Spoiler 黑块

/// `||...||` 隐藏文字：默认黑块遮罩，点击展开。
struct SpoilerView: View {
    let text: String
    @State private var revealed = false

    var body: some View {
        Text(text)
            .foregroundColor(revealed ? Theme.textPrimary : .clear)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(revealed ? Theme.mainBg.opacity(0.3) : Theme.textPrimary)
            )
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { revealed.toggle() } }
    }
}

// MARK: - Thinking Block

/// 原本用 `DisclosureGroup("思考")` —— macOS 下嵌在 LazyVStack + 自定义 bubble
/// background 里有时吃点击（实测粟粟反馈"思考都点不开"）。改成和 ToolCallCard
/// 一致的 Button + @State 结构，命中区域扩到整行，保证可点。
private struct ThinkingBlockView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("思考")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(Theme.textMuted.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Tool Call Card

private struct ToolCallCardView: View {
    let name: String
    let inputJSON: String
    let resultText: String?
    let isError: Bool
    let integration: String?

    @State private var isExpanded = false
    @State private var resultExpanded = false
    private let resultTruncate = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("🔧").font(.system(size: 11))
                    Text(name.isEmpty ? "(未命名 tool)" : name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    if let integration, !integration.isEmpty {
                        Text("· \(integration)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                    if isError {
                        Text("· 失败")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if !inputJSON.isEmpty && inputJSON != "{}" {
                    Text(inputJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let r = resultText, !r.isEmpty {
                    if !inputJSON.isEmpty && inputJSON != "{}" {
                        Divider().padding(.vertical, 2)
                    }
                    let shown = resultExpanded ? r : String(r.prefix(resultTruncate))
                    Text(shown)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if r.count > resultTruncate {
                        Button(resultExpanded ? "收起结果" : "展开全部（共 \(r.count) 字）") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                resultExpanded.toggle()
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.5))
        )
    }
}

// MARK: - Search Activity Card（search_web 专用）

/// 联网搜索过程卡：折叠态显示查询词 + 状态（搜索中 / N 个来源 / 失败），
/// 展开显示来源列表（标题 + 域名，点击外开）。参照 Claude 官方 App 的搜索 UI，
/// 样式沿用 ToolCallCardView 的卡片语言。resultText == nil 表示工具执行中
/// （Provider 工具轮开始时实时推送的 pending 态）。
private struct SearchActivityCardView: View {
    let inputJSON: String
    let resultText: String?
    let isError: Bool

    @State private var expanded = false

    private struct SourceItem: Identifiable {
        let id: Int
        let title: String
        let urlStr: String
        var url: URL? { URL(string: urlStr) }
        var domain: String {
            let host = URL(string: urlStr)?.host ?? urlStr
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    private var query: String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any]
        return (obj?["query"] as? String) ?? ""
    }

    private var errorMessage: String? {
        guard let r = resultText else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(r.utf8))) as? [String: Any] else {
            return isError ? r : nil
        }
        return obj["error"] as? String
    }

    private var sources: [SourceItem] {
        guard let r = resultText,
              let obj = (try? JSONSerialization.jsonObject(with: Data(r.utf8))) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        return items.enumerated().map { (i, item) in
            SourceItem(
                id: (item["index"] as? Int) ?? (i + 1),
                title: (item["title"] as? String) ?? "",
                urlStr: (item["url"] as? String) ?? ""
            )
        }
    }

    private var isPending: Bool { resultText == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.branchIndicator)
                    Text(query.isEmpty ? "联网搜索" : query)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if isPending {
                        ProgressView().controlSize(.mini)
                        Text("搜索中")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    } else if errorMessage != nil {
                        Text("失败")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.8))
                    } else {
                        Text("\(sources.count) 个来源")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                    if !isPending {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPending)

            if expanded {
                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .textSelection(.enabled)
                        .padding(.leading, 4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sources) { s in
                            sourceRow(s)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.5))
        )
    }

    @ViewBuilder
    private func sourceRow(_ s: SourceItem) -> some View {
        if let url = s.url {
            Link(destination: url) {
                sourceLabel(s)
            }
        } else {
            sourceLabel(s)
        }
    }

    private func sourceLabel(_ s: SourceItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(s.id).")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textMuted.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title.isEmpty ? s.urlStr : s.title)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(s.domain)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Browse Activity Card（browse_url 专用）

/// 读网页过程卡：折叠态显示页面标题（或域名）+ 状态（阅读中 / 已读 N 字 / 失败），
/// 展开显示 URL（可点）+ 摘要。resultText 格式是 BrowseURLTool 的
/// YAML-ish header + Markdown 正文。
private struct BrowseActivityCardView: View {
    let inputJSON: String
    let resultText: String?
    let isError: Bool

    @State private var expanded = false

    private var urlStr: String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any]
        return (obj?["url"] as? String) ?? ""
    }

    private var domain: String {
        let host = URL(string: urlStr)?.host ?? urlStr
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var errorMessage: String? {
        guard let r = resultText else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(r.utf8))) as? [String: Any] else { return nil }
        return obj["error"] as? String
    }

    /// 解析 BrowseURLTool 输出的 YAML-ish header（--- 包围的 key: value 行）
    private var parsed: (title: String, length: Int?, excerpt: String, body: String) {
        guard let r = resultText, r.hasPrefix("---\n") else {
            return ("", nil, "", resultText ?? "")
        }
        let afterFirst = String(r.dropFirst(4))
        guard let endRange = afterFirst.range(of: "\n---\n") else {
            return ("", nil, "", r)
        }
        let header = String(afterFirst[afterFirst.startIndex..<endRange.lowerBound])
        let body = String(afterFirst[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var title = "", excerpt = ""
        var length: Int? = nil
        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "title" { title = value }
            else if key == "length" { length = Int(value) }
            else if key == "excerpt" { excerpt = value }
        }
        return (title, length, excerpt, body)
    }

    private var isPending: Bool { resultText == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.branchIndicator)
                    Text(headlineText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if isPending {
                        ProgressView().controlSize(.mini)
                        Text("阅读中")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    } else if errorMessage != nil {
                        Text("失败")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.8))
                    } else if let len = parsed.length {
                        Text("已读 \(len) 字")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                    if !isPending {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPending)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let url = URL(string: urlStr) {
                        Link(urlStr, destination: url)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.branchIndicator)
                            .lineLimit(1)
                    }
                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                            .textSelection(.enabled)
                    } else {
                        let preview = parsed.excerpt.isEmpty
                            ? String(parsed.body.prefix(300))
                            : parsed.excerpt
                        if !preview.isEmpty {
                            Text(preview)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textMuted)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.5))
        )
    }

    private var headlineText: String {
        if isPending || parsed.title.isEmpty {
            return domain.isEmpty ? "读取网页" : domain
        }
        return parsed.title
    }
}

// MARK: - Flag Card

private struct FlagCardView: View {
    let kind: String
    let helplineLine: String?
    let helplineUrl: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("⚠️").font(.system(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("flag: \(kind)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                if let line = helplineLine {
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted.opacity(0.8))
                        .textSelection(.enabled)
                }
                if let url = helplineUrl, let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.textMuted.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Attachment Card

struct AttachmentCardView: View {
    let name: String
    let type: String?
    let extractedContent: String?

    @State private var isExpanded = false
    private let previewTruncate = 2000

    private var hasContent: Bool {
        (extractedContent?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if hasContent {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("📎").font(.system(size: 11))
                    Text(name.isEmpty ? "(附件)" : name)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                    if let t = type, !t.isEmpty {
                        Text("· \(t)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                    Spacer()
                    if hasContent {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)

            if isExpanded, let ex = extractedContent, !ex.isEmpty {
                let shown = ex.count > previewTruncate ? String(ex.prefix(previewTruncate)) + "\n...（已截断）" : ex
                Text(shown)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.5))
        )
    }
}
