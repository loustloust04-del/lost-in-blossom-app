import Foundation
import AVFoundation

/// 只在用户点「转文字」时调用，与 hub 听语音使用同一 Gemini 配置。
/// 助手语音直接读 audioRef.script，不重新识别、不改 TTS 脚本。
enum VoiceTranscriber {
    enum Failure: LocalizedError {
        case configuration, missingAudio, tooLarge, unavailable, empty, server(String)
        var errorDescription: String? {
            switch self {
            case .configuration: return "先在控制台连接网关"
            case .missingAudio: return "语音文件无法读取"
            case .tooLarge: return "这条语音太长了"
            case .unavailable: return "转文字服务暂时不可用"
            case .empty: return "没有识别到文字"
            case .server(let message): return message
            }
        }
    }

    static func spokenText(_ script: String) -> String {
        // ElevenLabs 方括号是表演指令，转文字只显示实际台词；原脚本仍原样保存。
        script.replacingOccurrences(of: #"\[[^\]\r\n]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cacheKey(profileId: String, path: String) -> String {
        "voice.geminiTranscript.v1.\(profileId).\(path)"
    }
    static func cached(profileId: String, path: String) -> String? {
        UserDefaults.standard.string(forKey: cacheKey(profileId: profileId, path: path))
    }
    static func cache(_ text: String, profileId: String, path: String) {
        UserDefaults.standard.set(text, forKey: cacheKey(profileId: profileId, path: path))
    }

    static func transcribe(url: URL) async throws -> String {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        let token = UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
        guard !token.isEmpty, let endpoint = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/voice/transcribe") else {
            throw Failure.configuration
        }
        // 解码录音移到后台，WAV 是现有 Gemini 音频链路的输入格式。
        let audio = try await Task.detached(priority: .userInitiated) {
            try wavData(from: url)
        }.value
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 95
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["audio": audio.base64EncodedString()])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unavailable }
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            // 未启用接口 / 登录错误不把服务器原始页面或凭证展示给用户。
            if http.statusCode == 401 || http.statusCode == 403 { throw Failure.configuration }
            if let message = result?["error"] as? String { throw Failure.server(message) }
            throw Failure.unavailable
        }
        guard let text = result?["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wavData(from url: URL) throws -> Data {
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0 else { throw Failure.missingAudio }
        let format = input.processingFormat
        // 录音最长五分钟，且限解码大小，避免一条历史音频吃满手机内存。
        guard input.length <= AVAudioFramePosition(format.sampleRate * 300),
              input.length * AVAudioFramePosition(format.channelCount) * 2 < 12 * 1024 * 1024 else { throw Failure.tooLarge }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("voice-text-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw Failure.missingAudio }
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
        let data = try Data(contentsOf: temporary)
        guard data.count < 12 * 1024 * 1024 else { throw Failure.tooLarge }
        return data
    }
}
