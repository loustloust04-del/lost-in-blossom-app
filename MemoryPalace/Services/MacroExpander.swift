import Foundation

/// 酒馆风格宏替换统一入口。
///
/// 支持的宏：`{{user}}` `{{char}}` `{{persona}}` `{{description}}` `{{personality}}` `{{scenario}}`
/// 空值 fallback：`userName` 为空 → `"你"`；`assistantName` 为空 → `"助手"`。
enum MacroExpander {
    /// 通用展开（Profile 版）：用于 prompt 组装、世界书扫描、UI 文案、regex result 端。
    ///
    /// `profile` 为 nil 时仍会把 `{{user}}` / `{{char}}` 替换成 fallback，
    /// 避免把字面量 `{{...}}` 暴露给用户。
    static func expand(_ text: String, profile: Profile?) -> String {
        let result = expand(
            text,
            userName: profile?.userName ?? "",
            charName: profile?.assistantName ?? ""
        )
        return result
            .replacingOccurrences(of: "{{persona}}", with: profile?.userPersona ?? "")
            .replacingOccurrences(of: "{{description}}", with: profile?.characterDescription ?? "")
            .replacingOccurrences(of: "{{personality}}", with: profile?.characterPersonality ?? "")
            .replacingOccurrences(of: "{{scenario}}", with: profile?.scenario ?? "")
    }

    /// 通用展开（字符串版）：只处理 `{{user}}` / `{{char}}`。
    /// 用于没有 Profile 但有原始字符串名字的调用点（如 `RegexScript.apply`）。
    static func expand(_ text: String, userName: String, charName: String) -> String {
        let user = resolvedName(userName, fallback: "你")
        let char = resolvedName(charName, fallback: "助手")
        return text
            .replacingOccurrences(of: "{{user}}", with: user)
            .replacingOccurrences(of: "{{char}}", with: char)
    }

    /// Regex 安全展开：仅用于 `RegexScript.findRegex` 的宏替换。
    /// - Parameter escape: true 时对名字做 `NSRegularExpression.escapedPattern` 转义。
    static func expandForRegex(
        _ pattern: String,
        userName: String,
        charName: String,
        escape: Bool
    ) -> String {
        let user = resolvedName(userName, fallback: "你")
        let char = resolvedName(charName, fallback: "助手")
        let userReplacement = escape ? NSRegularExpression.escapedPattern(for: user) : user
        let charReplacement = escape ? NSRegularExpression.escapedPattern(for: char) : char
        return pattern
            .replacingOccurrences(of: "{{user}}", with: userReplacement)
            .replacingOccurrences(of: "{{char}}", with: charReplacement)
    }

    private static func resolvedName(_ raw: String, fallback: String) -> String {
        raw.isEmpty ? fallback : raw
    }
}

extension String {
    /// UI 文案宏展开：
    /// ```
    /// Text("和{{char}}聊天时会自动记住重要的事".expandingMacros(profile: currentProfile))
    /// ```
    func expandingMacros(profile: Profile?) -> String {
        MacroExpander.expand(self, profile: profile)
    }
}
