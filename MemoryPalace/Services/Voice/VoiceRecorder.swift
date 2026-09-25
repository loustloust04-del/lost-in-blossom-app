import AVFoundation
import Foundation

/// 她给主人发语音条（09-25）：按住录、松手发。AVAudioRecorder → m4a（AAC 64k 单声道，一分钟约 480KB）。
/// hub 那头 09-16 已经接好：chat 帧带 audio:[{b64, ext}]，hub 用 ffmpeg 转 wav 再让 Gemini 转写，
/// 转写并进正文标「（语音）」；App 本地存原音，自己那条显示成语音条可回放。
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    static let shared = VoiceRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0        // 0…1，给波形/呼吸圈用
    @Published var lastError: String? = nil

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private(set) var currentURL: URL?
    static let maxSeconds: TimeInterval = 60

    /// 申请麦克风权限（首次弹系统框）
    func requestPermission() async -> Bool {
        if #available(iOS 17, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { c in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
        }
    }

    func start() async -> Bool {
        guard !isRecording else { return true }
        guard await requestPermission() else { lastError = "没有麦克风权限"; return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch { lastError = "音频会话打不开"; return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.record() else { lastError = "录音没启动"; return false }
            recorder = r
            currentURL = url
            startedAt = Date()
            elapsed = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return true
        } catch {
            lastError = "录音器打不开：\(error.localizedDescription)"
            return false
        }
    }

    private func tick() {
        guard let r = recorder, let s = startedAt else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)          // -160…0
        level = max(0, min(1, (db + 50) / 50))          // -50dB 以下当静音
        elapsed = Date().timeIntervalSince(s)
        if elapsed >= Self.maxSeconds { _ = stop() }
    }

    /// 停止并返回 (文件, 时长)；太短（<0.6s）返回 nil 并删掉
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let r = recorder, let url = currentURL else { return nil }
        let dur = elapsed
        r.stop()
        timer?.invalidate(); timer = nil
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if dur < 0.6 { try? FileManager.default.removeItem(at: url); return nil }
        return (url, dur)
    }

    func cancel() {
        guard isRecording else { return }
        recorder?.stop()
        timer?.invalidate(); timer = nil
        recorder = nil
        isRecording = false
        level = 0
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.lastError = "录音出错：\(error?.localizedDescription ?? "?")" }
    }
}
