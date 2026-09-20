import Foundation

/// TTS 后端。ElevenLabs 走标签表演体系（贵、需反代）；MiniMax 中文母语级、国内直连、约 1/4 价。
enum TTSProvider: String, CaseIterable, Identifiable, Codable {
    case elevenLabs
    case miniMax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .miniMax: return "MiniMax（海螺）"
        }
    }

    var blurb: String {
        switch self {
        case .elevenLabs: return "方括号标签逐句导演表演，捏声原创。额度贵，走自家反代。"
        case .miniMax: return "中文自然度高、国内直连、便宜。情绪按档位走，圆括号拟声。"
        }
    }

    /// Keychain 账号名（两家 key 分开存，切换不用重填）
    var keychainAccount: String {
        switch self {
        case .elevenLabs: return VoiceTuning.keychainAccount
        case .miniMax: return "minimax.apikey"
        }
    }
}

/// 两家后端的统一接口：Writer 只认这个，换后端不改调用方。
protocol TTSBackend {
    /// 合成一段语音。script 为表演脚本（可能含 [tag]），实现方负责把标签翻成自家方言。
    func synthesize(script: String, voiceId: String, apiKey: String) async throws -> Data
    /// 可选音色列表（MiniMax 为系统音色常量表，不需要网络）
    func fetchVoices(apiKey: String) async throws -> [ElevenVoice]
}

extension ElevenLabsClient: TTSBackend {
    /// 协议要求三参签名；本体的 synthesize 带 settings 默认值，默认参数不满足协议一致性，这里转发。
    func synthesize(script: String, voiceId: String, apiKey: String) async throws -> Data {
        try await synthesize(script: script, voiceId: voiceId, apiKey: apiKey, settings: VoiceTuning.current())
    }
}
