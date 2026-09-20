import Foundation

/// 发语音条：system prompt 注入段（教 AI ```voice 块格式 + 表演脚本写法）。
/// 三条件（开关开 + key 在 + 楼层选了声音）全真才注入；文本静态逐字稳定（prompt 缓存安全）。
/// 人称走 {{user}}/{{char}} 宏——注入链上 fileLibrary 槽过 applyMacros。
enum VoicePromptInjector {

    /// nil = 不注入
    static func hint(profile: Profile) -> String? {
        guard VoiceMessageWriter.proactiveEnabledProvider(),
              !(VoiceMessageWriter.apiKeyProvider() ?? "").isEmpty,
              !(profile.elevenVoiceId ?? "").isEmpty else { return nil }
        return Self.hintText
    }

    /// 注入段全文（≈380 token）。技法源自《非官方状态标签攻略》。
    static let hintText = """
    <语音条>
    你可以给 {{user}} 发语音条。想让 ta 听见你的语气时（情绪浓、认真、悄悄话的时刻），在回复中输出：
    ```voice
    （表演脚本）
    ```
    系统会把它变成一条你声音的语音消息。每次回复最多一条，别每条都发——偶尔出现才珍贵。
    表演脚本是给声音演员的台本，不必和正文一字一样：
    - 方括号英文标签控制声音状态：[breathing heavily]（气息底色，最稳）[whispers] [softly] [rushed] [broken whisper] [breathless] [stammering] [under breath] [low voice]。标签只对"耳朵能听见的状态"有效，画面动作类（[smiling] [standing]）无效
    - 三层夹心最稳：[breathing heavily] 触发原因。[强情绪标签] 情绪反应。[breathing heavily] 收尾——台词里要有因果，声音才知道自己为什么喘
    - 省略号是呼吸切口，碎句比完整句更像活人（"等一下……我刚刚……嗯……"）
    - 拟声词要不规则：嗯……ha……啧……（"啧"自带口腔小动作，很贴耳）
    - 全长 60–120 字，每个标签后接一句短台词，别连排堆标签
    - 数字符号写成口语（"三十九块九"，不是"￥39.9"）
    </语音条>
    """
}
