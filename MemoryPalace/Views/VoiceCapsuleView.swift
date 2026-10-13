import SwiftUI
import SwiftData

/// 语音条胶囊（气泡外侧，微信式）：播放/暂停 + 细进度 + 时长；长按「转文字 / 收起文字」，助手语音还可「换一版」。
/// tap 用 onTapGesture（横向滚动区 Button 会被手势吞的教训）。
struct VoiceCapsuleView: View {
    let path: String          // audioRef 相对路径 = 播放 id
    let duration: Double?
    let nodeId: String
    let profileId: String
    let isUser: Bool
    /// 气泡模式内嵌：外层已是气泡壳（BubbleTailShape），去掉自带胶囊底/描边/定高
    var embedded: Bool = false

    var sourceScript: String? = nil

    @State private var showTranscript = false
    @State private var transcript: String?
    @State private var transcriptionError: String?
    @State private var isTranscribing = false
    @State private var transcriptionTask: Task<Void, Never>?

    @Environment(\.modelContext) private var modelContext

    private var url: URL? { FileLibraryStore.absoluteURL(path, profileId: profileId) }
    private var isPlaying: Bool { VoiceMessagePlayer.shared.playingId == path }
    private var progress: Double { isPlaying ? VoiceMessagePlayer.shared.progress : 0 }

    /// 市面通用做法（09-25 兔兔：「照着已经成为习惯的方案」）：宽度随时长长（3s→短，60s→接近气泡上限）；
    /// 播放键 + 一排静态波形条 + 时长；播放时波形按进度着色。她的用她气泡的颜色，他的用助手气泡色。
    private var barWidth: CGFloat {
        let secs = max(1, min(60, duration ?? 3))
        return 60 + CGFloat(secs) / 60 * 150            // 60…210pt
    }
    private var bars: [CGFloat] {
        // 用路径当种子生成一排固定的伪波形：同一条每次长得一样
        var x = UInt64(truncatingIfNeeded: path.hashValue) &+ 0x9E3779B97F4A7C15
        return (0..<Int(barWidth / 5)).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return 4 + CGFloat(x % 100) / 100 * 12       // 4…16pt
        }
    }
    private var tint: Color { isUser ? Theme.branchIndicator : Theme.textPrimary.opacity(0.75) }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            capsule
            if showTranscript { transcriptBody }
        }
        // 展开文字不参与气泡入场动画，避免反转列表中新文字层继承旋转动画。
        .transaction { $0.animation = nil }
        .onDisappear {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            isTranscribing = false
        }
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            Image(systemName: url == nil ? "speaker.slash" : (isPlaying ? "pause.fill" : "play.fill"))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(url == nil ? Theme.textMuted.opacity(0.5) : tint)
                .frame(width: 18)

            // 波形：进度扫过的那部分实色，其余淡
            HStack(alignment: .center, spacing: 2) {
                let arr = bars
                ForEach(Array(arr.enumerated()), id: \.offset) { i, h in
                    Capsule()
                        .fill(Double(i) / Double(max(1, arr.count)) < progress ? tint : tint.opacity(0.32))
                        .frame(width: 3, height: h)
                }
            }
            .frame(width: barWidth, height: 18)

            Text(url == nil ? "文件不在了" : durationLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(isUser ? Theme.textPrimary.opacity(0.7) : Theme.textMuted)
        }
        .padding(.horizontal, embedded ? 0 : 14)
        .padding(.vertical, embedded ? 0 : 9)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(embedded ? Color.clear : (isUser ? Theme.userBubble : Theme.assistantBubble))
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            guard let url else { return }
            VoiceMessagePlayer.shared.toggle(url: url, id: path)
        }
        .contextMenu {
            Button {
                if showTranscript { showTranscript = false }
                else { revealTranscript() }
            } label: {
                Label(showTranscript ? "收起文字" : "转文字", systemImage: "text.bubble")
            }
            .disabled(isTranscribing)
            if !isUser {
                Button {
                    VoiceMessageWriter.regenerate(nodeId: nodeId, context: modelContext)
                } label: {
                    Label("换一版", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    @ViewBuilder private var transcriptBody: some View {
        if isTranscribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在转文字…").font(.caption)
            }
            .foregroundColor(Theme.textMuted)
        } else if let transcript, !transcript.isEmpty {
            Text(transcript)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary.opacity(0.8))
                .multilineTextAlignment(isUser ? .trailing : .leading)
                .frame(maxWidth: 260, alignment: isUser ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu {
                    Button { UIPasteboard.general.string = transcript } label: {
                        Label("复制文字", systemImage: "doc.on.doc")
                    }
                    Button { showTranscript = false } label: {
                        Label("收起文字", systemImage: "chevron.up")
                    }
                }
        } else if let transcriptionError {
            Button { revealTranscript() } label: {
                Text(transcriptionError + " · 点此重试")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(isUser ? .trailing : .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func revealTranscript() {
        showTranscript = true
        transcriptionError = nil
        guard transcript == nil, !isTranscribing else { return }
        if !isUser {
            let text = VoiceTranscriber.spokenText(sourceScript ?? "")
            if text.isEmpty { transcriptionError = "这条语音没有保存原文" }
            else { transcript = text }
            return
        }
        if let cached = VoiceTranscriber.cached(profileId: profileId, path: path) {
            transcript = cached
            return
        }
        guard let url else { transcriptionError = "语音文件不在了"; return }
        isTranscribing = true
        transcriptionTask = Task { @MainActor in
            defer { isTranscribing = false; transcriptionTask = nil }
            do {
                let text = try await VoiceTranscriber.transcribe(url: url)
                try Task.checkCancellation()
                VoiceTranscriber.cache(text, profileId: profileId, path: path)
                transcript = text
                // 用户旧 script 可能来自本机识别；仅在 Gemini 成功后替换匹配的语音段。
                let id = nodeId
                if let node = try modelContext.fetch(FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.id == id })).first {
                    node.setSegments((node.segments ?? []).map { segment in
                        if case .audioRef(let n, let m, let p, let d, _) = segment, p == path {
                            return .audioRef(name: n, mime: m, path: p, duration: d, script: text)
                        }
                        return segment
                    })
                    try modelContext.save()
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { transcriptionError = error.localizedDescription }
            }
        }
    }

    private var durationLabel: String {
        guard let duration, duration.isFinite, duration > 0 else { return "语音" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
