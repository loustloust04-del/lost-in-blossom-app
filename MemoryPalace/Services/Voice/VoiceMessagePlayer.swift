import Foundation
import AVFoundation
import Observation

/// 语音条播放器：一次只播一条（播 B 自动停 A），开播暂停听书（单向互斥——语音条短）。
/// id 用 audioRef 的 path（同一文件同一条）。
@MainActor
@Observable
final class VoiceMessagePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceMessagePlayer()

    private(set) var playingId: String? = nil
    private(set) var progress: Double = 0   // 0...1
    private var player: AVAudioPlayer? = nil
    private var timer: Timer? = nil

    func toggle(url: URL, id: String) {
        if playingId == id {
            stop()
            return
        }
        stop()
        // （粟粟侧这里会暂停 AudiobookPlayer——我们没有有声书系统，无互斥对象）
        configureSession()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.delegate = self
        p.play()
        playingId = id
        progress = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingId = nil
        progress = 0
    }

    private func tick() {
        guard let p = player, p.duration > 0 else { return }
        progress = p.currentTime / p.duration
    }

    private func configureSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
