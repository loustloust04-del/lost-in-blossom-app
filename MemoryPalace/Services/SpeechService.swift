@preconcurrency import AVFoundation
import Foundation

final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()
    private(set) var activeNodeId: String?

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(nodeId: String, text: String) {
        guard UserDefaults.standard.object(forKey: "ttsEnabled") as? Bool ?? true else { return }
        let cleaned = Self.cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }

        stop()
        activeNodeId = nodeId
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.rate = Float(UserDefaults.standard.double(forKey: "ttsRate").nonZeroOrDefault(0.48))
        if let language = Locale.preferredLanguages.first {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeNodeId = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        activeNodeId = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        activeNodeId = nil
    }

    static func speakableText(from node: MessageNode) -> String {
        if let segments = node.segments, !segments.isEmpty {
            return segments.compactMap { segment in
                if case .text(let text) = segment {
                    return text
                }
                return nil
            }.joined(separator: "\n\n")
        }
        return node.content
    }

    static func cleanForSpeech(_ text: String) -> String {
        let withoutThinking = ContentCleaner.extractThinking(from: text).content
        var result = withoutThinking
        let replacements: [(String, String)] = [
            ("```[\\s\\S]*?```", " "),
            ("`([^`]+)`", "$1"),
            ("!\\[[^\\]]*\\]\\([^\\)]*\\)", " "),
            ("\\[([^\\]]+)\\]\\([^\\)]*\\)", "$1"),
            ("[#>*_~\\-]{1,}", " "),
            ("\\|", " "),
            ("\\n{3,}", "\n\n")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Double {
    func nonZeroOrDefault(_ fallback: Double) -> Double {
        self == 0 ? fallback : self
    }
}
