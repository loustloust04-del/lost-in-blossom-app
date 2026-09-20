import Foundation

// MARK: - Regex Script (酒馆正则脚本)

struct RegexScript: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var scriptName: String = ""
    var findRegex: String = ""           // 正则表达式（含 flags，如 /pattern/s）
    var replaceString: String = ""       // 替换模板（$1 $2 捕获组, {{match}} = $0）
    var placement: [Int] = [2]           // 1=用户消息, 2=AI消息, 3=命令, 5=世界书, 6=推理
    var disabled: Bool = false
    var markdownOnly: Bool = true        // true=只在渲染时替换
    var promptOnly: Bool = false         // true=只在发送 API 时替换
    var runOnEdit: Bool = true
    var trimStrings: [String] = []       // 从结果中移除的字符串
    var substituteRegex: Int = 0         // 0=不替换, 1=替换宏（原样）, 2=替换宏（转义）
    var minDepth: Int? = nil             // promptOnly: 最小消息深度（0=最新）
    var maxDepth: Int? = nil             // promptOnly: 最大消息深度

    /// 从 TavernCard extensions.regex_scripts[] 的 JSON 字典解析
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.scriptName = dict["scriptName"] as? String ?? ""
        self.findRegex = dict["findRegex"] as? String ?? ""
        self.replaceString = dict["replaceString"] as? String ?? ""
        self.placement = dict["placement"] as? [Int] ?? [2]
        self.disabled = dict["disabled"] as? Bool ?? false
        self.markdownOnly = dict["markdownOnly"] as? Bool ?? true
        self.promptOnly = dict["promptOnly"] as? Bool ?? false
        self.runOnEdit = dict["runOnEdit"] as? Bool ?? true
        self.trimStrings = dict["trimStrings"] as? [String] ?? []
        self.substituteRegex = dict["substituteRegex"] as? Int ?? 0
        self.minDepth = dict["minDepth"] as? Int
        self.maxDepth = dict["maxDepth"] as? Int
    }

    init() {}
}

// MARK: - Regex Engine (兼容酒馆)

struct RegexEngine {

    /// 酒馆 placement 常量
    static let placementUserInput = 1
    static let placementAIOutput = 2

    /// 对文本应用正则脚本
    ///
    /// - messagePlacement: 1=用户消息, 2=AI消息
    /// - isMarkdown: true=渲染显示模式
    /// - isPrompt: true=API发送模式
    /// - depth: 消息深度（0=最新消息，仅 promptOnly 用）
    /// - userName/charName: 宏替换用
    static func apply(
        scripts: [RegexScript],
        text: String,
        messagePlacement: Int,
        isMarkdown: Bool = false,
        isPrompt: Bool = false,
        depth: Int? = nil,
        userName: String = "",
        charName: String = ""
    ) -> String {
        var result = text

        for script in scripts {
            guard !script.disabled else { continue }

            // 上下文过滤（对齐酒馆逻辑）
            let shouldRun: Bool
            if script.markdownOnly && script.promptOnly {
                shouldRun = isMarkdown || isPrompt
            } else if script.markdownOnly {
                shouldRun = isMarkdown
            } else if script.promptOnly {
                shouldRun = isPrompt
            } else {
                shouldRun = !isMarkdown && !isPrompt
            }
            guard shouldRun else { continue }

            // 检查 placement
            guard script.placement.contains(messagePlacement) else { continue }

            // 深度过滤（仅 promptOnly 模式）
            if isPrompt, let depth = depth {
                if let min = script.minDepth, min >= 0, depth < min { continue }
                if let max = script.maxDepth, max >= 0, depth > max { continue }
            }

            // 构造 findRegex（substituteRegex 宏替换）
            var findPattern = script.findRegex
            if script.substituteRegex > 0 && (!userName.isEmpty || !charName.isEmpty) {
                findPattern = MacroExpander.expandForRegex(
                    findPattern,
                    userName: userName,
                    charName: charName,
                    escape: script.substituteRegex == 2
                )
            }

            // 解析正则
            guard let (pattern, options) = parseRegex(findPattern) else { continue }

            do {
                let regex = try NSRegularExpression(pattern: pattern, options: options)
                let range = NSRange(result.startIndex..<result.endIndex, in: result)

                // 替换模板：{{match}} → $0
                let rawTemplate = script.replaceString
                    .replacingOccurrences(of: "{{match}}", with: "$0", options: .caseInsensitive)

                // 清理模板里指向不存在捕获组的反向引用（如 $1 但正则无捕获组）。
                // 否则 stringByReplacingMatches 会抛出无法被 do-catch 捕获的
                // NSInvalidArgumentException（ObjC 异常），直接崩掉整个 App。
                let template = sanitizeTemplate(rawTemplate, groupCount: regex.numberOfCaptureGroups)

                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            } catch {
                continue
            }

            // trimStrings
            for trim in script.trimStrings where !trim.isEmpty {
                result = result.replacingOccurrences(of: trim, with: "")
            }
        }

        // 最后对结果做宏替换
        if !userName.isEmpty || !charName.isEmpty {
            result = MacroExpander.expand(result, userName: userName, charName: charName)
        }

        return result
    }

    /// 解析酒馆格式正则：`/pattern/flags` → (pattern, NSRegularExpression.Options)
    private static func parseRegex(_ raw: String) -> (String, NSRegularExpression.Options)? {
        var input = raw.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return nil }

        guard input.hasPrefix("/") else {
            return (input, [])
        }

        input = String(input.dropFirst())

        guard let lastSlash = input.lastIndex(of: "/") else {
            return (input, [])
        }

        let pattern = String(input[input.startIndex..<lastSlash])
        let flags = String(input[input.index(after: lastSlash)...])

        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        // g = global，NSRegularExpression 默认全局替换

        return (pattern, options)
    }

    /// 清理替换模板中的反向引用：把指向不存在捕获组的 `$N` 以及裸 `$` 转义为字面量。
    ///
    /// `NSRegularExpression.stringByReplacingMatches(withTemplate:)` 在模板引用了
    /// 不存在的捕获组时（例如正则没有分组却写了 `$1`），会抛出
    /// `NSInvalidArgumentException`。这是 ObjC 异常，Swift 的 `do-catch` 抓不到，
    /// 会导致 App 崩溃。用户可自行编辑酒馆正则脚本，所以必须在这里做兜底清理。
    ///
    /// - Parameters:
    ///   - template: 已做过 `{{match}} → $0` 展开的替换模板
    ///   - groupCount: `regex.numberOfCaptureGroups`（不含表示整体匹配的 `$0`）
    /// - Returns: 只保留有效反向引用（`$0` 到 `$groupCount`）的安全模板
    static func sanitizeTemplate(_ template: String, groupCount: Int) -> String {
        var output = ""
        output.reserveCapacity(template.count)
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            // 已有的转义序列（\$ / \\ / \N 等）原样保留
            if c == "\\" {
                output.append(c)
                if i + 1 < chars.count {
                    output.append(chars[i + 1])
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            if c == "$" {
                // 贪婪读取紧随其后的数字串
                var j = i + 1
                while j < chars.count, chars[j].isNumber {
                    j += 1
                }

                if j == i + 1 {
                    // 裸 `$`（后面没有数字）→ 转义成字面量
                    output.append("\\$")
                    i += 1
                    continue
                }

                let digits = String(chars[(i + 1)..<j])
                if let n = Int(digits), n <= groupCount {
                    // 有效反向引用：$0 = 整体匹配，$1...$groupCount = 捕获组
                    output.append("$")
                    output.append(contentsOf: digits)
                } else {
                    // 指向不存在的捕获组（或数字过大溢出）→ 整段转义为字面量
                    output.append("\\$")
                    output.append(contentsOf: digits)
                }
                i = j
                continue
            }

            output.append(c)
            i += 1
        }
        return output
    }
}
