import SwiftUI

/// 语音条「正在成型」态：与 VoiceCapsuleView 同形同尺寸的胶囊，只是内脏在动。
/// 设计意图：占位不是另一个东西，是同一枚胶囊的前一刻——外壳/高度/圆角/描边全部照抄，
/// 播放键位置换成未闭合圆环（旋转=尚未成形），进度条位置换成三点依次呼吸，时长位置写「生成中」。
/// 尊重「减弱动态效果」：开启后静止显示，不闪不跳。
struct VoicePendingCapsuleView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Int = 0

    private let timer = Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .trim(from: 0, to: 0.68)
                .stroke(Theme.branchIndicator.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(phase) * 120))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: phase)
                .frame(width: 16)

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.branchIndicator.opacity(dotOpacity(i)))
                        .frame(width: 4.5, height: 4.5)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: phase)
                }
            }
            .frame(width: 88, alignment: .leading)

            Text("生成中")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Theme.accent.opacity(0.38)))
        .overlay(Capsule().stroke(Theme.textMuted.opacity(0.12), lineWidth: 0.5))
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("语音条生成中")
    }

    private func dotOpacity(_ i: Int) -> Double {
        if reduceMotion { return 0.45 }
        return i == phase ? 0.85 : 0.28
    }
}
