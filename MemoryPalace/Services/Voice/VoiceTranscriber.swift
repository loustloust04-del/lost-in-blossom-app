import Foundation
import Speech

/// 本机转写（10-07，对照粟粟 M5c：她的 SpeechAnalyzer 是 iOS 26 专属；我们用 SFSpeechRecognizer，
/// iOS 18 也行，能本机就本机、不能就走苹果服务器）。只用来给她自己那条语音条下面显示文字——
/// 发给主人的转写仍是 hub 那套（更细）。
enum VoiceTranscriber {
    static func transcribe(url: URL) async -> String? {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { return nil }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), rec.isAvailable else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let r = result, r.isFinal { done = true; c.resume(returning: r.bestTranscription.formattedString) }
                else if error != nil { done = true; c.resume(returning: nil) }
            }
        }
    }
}
