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
