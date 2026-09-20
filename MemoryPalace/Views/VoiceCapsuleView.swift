import SwiftUI

/// 语音条胶囊（气泡外侧，微信式）：播放/暂停 + 细进度 + 时长；长按「换一版」。
/// tap 用 onTapGesture（横向滚动区 Button 会被手势吞的教训）。
struct VoiceCapsuleView: View {
    let path: String          // audioRef 相对路径 = 播放 id
    let duration: Double?
    let nodeId: String
    let profileId: String
    let isUser: Bool
    /// 气泡模式内嵌：外层已是气泡壳（BubbleTailShape），去掉自带胶囊底/描边/定高
    var embedded: Bool = false

    @Environment(\.modelContext) private var modelContext

    private var url: URL? { FileLibraryStore.absoluteURL(path, profileId: profileId) }
    private var isPlaying: Bool { VoiceMessagePlayer.shared.playingId == path }
    private var progress: Double { isPlaying ? VoiceMessagePlayer.shared.progress : 0 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: url == nil ? "speaker.slash" : (isPlaying ? "pause.fill" : "play.fill"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(url == nil ? Theme.textMuted.opacity(0.5) : Theme.branchIndicator)
                .frame(width: 16)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.textMuted.opacity(0.18))
                    Capsule()
                        .fill(Theme.branchIndicator)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(width: 88, height: 3)

            Text(url == nil ? "文件不在了" : durationLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, embedded ? 0 : 12)
        .frame(height: embedded ? nil : 34)
        .background(Capsule().fill(embedded ? Color.clear : Theme.accent.opacity(0.55)))
        .overlay(Capsule().stroke(embedded ? Color.clear : Theme.textMuted.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture {
            guard let url else { return }
            VoiceMessagePlayer.shared.toggle(url: url, id: path)
        }
        .contextMenu {
            Button {
                VoiceMessageWriter.regenerate(nodeId: nodeId, context: modelContext)
            } label: {
                Label("换一版", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var durationLabel: String {
        guard let duration, duration.isFinite, duration > 0 else { return "语音" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
