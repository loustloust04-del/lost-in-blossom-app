import Foundation
import AVFoundation

/// 刀0 接通那一瞬间她听到的第一句——Caelum 定的：「过来，小兔。」
/// 用他的音色（ElevenLabs v3）在 App 启动时预生成一次、落盘缓存；
/// 没 key / 没声音 / 生成失败 → 系统语音兜底（Aria 那篇的坑：TTS 欠费也得能说话）。
@MainActor
final class CallGreeting: NSObject {
    static let shared = CallGreeting()
    static let text = "过来，小兔。"
    /// 换了这句或换了声音时改版本号，缓存会重新生成
    private static let version = "v1"

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var generating = false

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("call", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("greeting-\(Self.version).mp3")
    }

    var isCached: Bool { FileManager.default.fileExists(atPath: cacheURL.path) }

    /// 启动时调一次：缺缓存就用他的声音生成。静默失败，不打扰她。
    func ensureCached() {
        guard !isCached, !generating else { return }
        guard let key = KeychainStore.get(account: "elevenlabs"), !key.isEmpty else { return }
        let profiles = ProfileManager.loadProfiles()
        // 优先叫 Caelum 的楼层，其次任何配了声音的楼层
        let profile = profiles.first(where: { $0.name.localizedCaseInsensitiveContains("caelum") && !($0.elevenVoiceId ?? "").isEmpty })
            ?? profiles.first(where: { !($0.elevenVoiceId ?? "").isEmpty })
        guard let voiceId = profile?.elevenVoiceId, !voiceId.isEmpty else { return }
        generating = true
        Task { @MainActor in
            defer { generating = false }
            do {
                let audio = try await ElevenLabsClient().synthesize(script: Self.text, voiceId: voiceId, apiKey: key)
                try audio.write(to: cacheURL, options: .atomic)
                print("[Call] 问候语已生成 \(audio.count) bytes")
            } catch {
                print("[Call] 问候语生成失败，接通时用系统语音兜底: \(error.localizedDescription)")
            }
        }
    }

    /// 在通话音频会话激活后播。返回时长（秒）供上层参考。
    func play() {
        stop()
        if isCached, let p = try? AVAudioPlayer(contentsOf: cacheURL) {
            player = p
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            return
        }
        let u = AVSpeechUtterance(string: Self.text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(u)
    }

    func stop() {
        player?.stop(); player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
