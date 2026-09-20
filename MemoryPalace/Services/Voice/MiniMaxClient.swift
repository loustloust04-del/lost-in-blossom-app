import Foundation

/// MiniMax（海螺）TTS。国内直连、中文母语级、约 ElevenLabs 1/4 价。
/// 与 ElevenLabs 的两点方言差异，在这里吸收，Writer 与教学都不必改：
/// 1) 表演标签：EL 用方括号逐句导演；MiniMax 用圆括号拟声 + 整句 emotion 档位。
///    → 取脚本首个可映射的 [tag] 当整句 emotion，其余 [tag] 剥掉（避免被念出来）。
/// 2) 音色：MiniMax 是系统音色常量表 + 克隆音色 id，无需拉列表。
struct MiniMaxClient {
    static let endpoint = URL(string: "https://api.minimaxi.com/v1/t2a_v2")!
    static let model = "speech-2.8-hd"

    var session: URLSession = .shared

    /// 系统音色（常用男声优先，够日常朗读用；克隆音色可手填 id）
    static let systemVoices: [ElevenVoice] = [
        .init(voiceId: "male-qn-jingying", name: "精英青年（男）", previewURL: nil),
        .init(voiceId: "male-qn-qingse", name: "青涩青年（男）", previewURL: nil),
        .init(voiceId: "male-qn-badao", name: "霸道少爷（男）", previewURL: nil),
        .init(voiceId: "presenter_male", name: "男主持人", previewURL: nil),
        .init(voiceId: "audiobook_male_1", name: "有声书男声一", previewURL: nil),
        .init(voiceId: "audiobook_male_2", name: "有声书男声二", previewURL: nil),
        .init(voiceId: "female-shaonv", name: "少女（女）", previewURL: nil),
        .init(voiceId: "female-yujie", name: "御姐（女）", previewURL: nil),
        .init(voiceId: "presenter_female", name: "女主持人", previewURL: nil),
    ]

    /// EL 标签 → MiniMax 情绪档位。只映射官方支持的档，其余标签剥掉。
    private static let emotionMap: [String: String] = [
        "whispers": "sad", "softly": "sad", "broken whisper": "sad", "sighs": "sad",
        "crying": "sad", "sobbing": "sad", "low voice": "sad", "quietly": "sad",
        "laughs": "happy", "playful": "happy", "mischievously": "happy", "excited": "happy",
        "curious": "surprised", "angry": "angry", "rushed": "fearful",
    ]

    /// 返回 (清洗后的文本, 整句情绪)。标签剥净以免被念出来。
    static func adapt(script: String) -> (text: String, emotion: String?) {
        var emotion: String?
        let ns = script as NSString
        let re = try! NSRegularExpression(pattern: "\\[([^\\]]{1,40})\\]")
        for m in re.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1)).lowercased().trimmingCharacters(in: .whitespaces)
            if emotion == nil, let e = emotionMap[tag] { emotion = e }
        }
        var text = re.stringByReplacingMatches(
            in: script, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), emotion)
    }

    func synthesize(script: String, voiceId: String, apiKey: String) async throws -> Data {
        let (text, emotion) = Self.adapt(script: script)
        guard !text.isEmpty else { throw ElevenLabsError.network }

        var voiceSetting: [String: Any] = [
            "voice_id": voiceId,
            "speed": VoiceTuning.current().speed,
            "vol": 1,
            "pitch": 0,
        ]
        if let emotion { voiceSetting["emotion"] = emotion }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "text": text,
            "stream": false,
            "voice_setting": voiceSetting,
            "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1],
        ])

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch {
            let ns = error as NSError
            VoiceMessageWriter.dbg("mm-net-\(ns.domain)-\(ns.code)")
            throw ElevenLabsError.network
        }
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 { throw ElevenLabsError.invalidKey }

        // 响应体：{ data: { audio: "<hex>" }, base_resp: { status_code, status_msg } }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElevenLabsError.network
        }
        if let base = obj["base_resp"] as? [String: Any],
           let code = base["status_code"] as? Int, code != 0 {
            let msg = (base["status_msg"] as? String) ?? "\(code)"
            VoiceMessageWriter.dbg("mm-api-\(code)")
            _ = msg
            throw (code == 1004 || code == 1008) ? ElevenLabsError.quotaOrRateLimited
                                                 : ElevenLabsError.server(code)
        }
        guard let d = obj["data"] as? [String: Any],
              let hex = d["audio"] as? String,
              let audio = Data(hexString: hex), !audio.isEmpty else {
            throw ElevenLabsError.network
        }
        return audio
    }

    func fetchVoices(apiKey: String) async throws -> [ElevenVoice] { Self.systemVoices }
}

extension MiniMaxClient: TTSBackend {}

private extension Data {
    /// MiniMax 返回 hex 编码音频
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        func val(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let h = val(chars[i]), let l = val(chars[i+1]) else { return nil }
            bytes.append(h << 4 | l); i += 2
        }
        self.init(bytes)
    }
}
