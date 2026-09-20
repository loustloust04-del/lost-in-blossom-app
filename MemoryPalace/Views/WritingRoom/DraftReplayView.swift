import SwiftUI
import SwiftData

/// 写作过程回放：拖时间轴看这篇稿子怎么一点点长出来的。
/// 像绘画软件的过程录像——只不过录的是字。
/// 「对比上一帧」开着时，新增绿底、删掉的红底带删除线。
struct DraftReplayView: View {
    let draft: Draft
    var onClose: () -> Void

    @Environment(\.modelContext) private var context

    @State private var snaps: [DraftSnapshot] = []
    @State private var idx: Double = 0
    @State private var showDiff = true
    @State private var playing = false
    @State private var timer: Timer?

    private var current: DraftSnapshot? {
        guard !snaps.isEmpty else { return nil }
        return snaps[min(max(0, Int(idx)), snaps.count - 1)]
    }
    private var previous: DraftSnapshot? {
        let i = min(max(0, Int(idx)), snaps.count - 1)
        return i > 0 ? snaps[i - 1] : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if snaps.isEmpty { emptyState } else { content }
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("写作回放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { stop(); onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $showDiff) { Text("对比") }
                        .toggleStyle(.button)
                        .font(.system(size: Theme.F.caption))
                        .tint(ConsoleView.greenDeep)
                }
            }
        }
        .onAppear { snaps = DraftSnapshotStore.all(draftId: draft.id, context: context)
                    idx = Double(max(0, snaps.count - 1)) }
        .onDisappear { stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30)).foregroundColor(ConsoleView.green.opacity(0.5))
            Text("还没有录到过程\n写一会儿就有了（每 5 秒记一帧）")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            textPane
            growthCurve
            timeline
            transport
        }
    }

    // MARK: - 正文（带差异高亮）

    private var textPane: some View {
        ScrollView {
            Group {
                if showDiff, let prev = previous, let cur = current {
                    let segs = DraftSnapshotStore.diff(from: prev.text, to: cur.text)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(segs) { seg in
                            Text(seg.text)
                                .font(.system(size: 15, design: .serif))
                                .lineSpacing(5)
                                .strikethrough(seg.kind == .removed, color: Color.red.opacity(0.55))
                                .foregroundColor(seg.kind == .removed ? Theme.textMuted : Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 1)
                                .background(bg(seg.kind))
                        }
                    }
                } else {
                    Text(current?.text ?? "")
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(5)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.mainBg)
    }

    private func bg(_ kind: DraftSnapshotStore.DiffSegment.Kind) -> Color {
        switch kind {
        case .added:   return ConsoleView.green.opacity(0.16)
        case .removed: return Color.red.opacity(0.08)
        case .same:    return .clear
        }
    }

    // MARK: - 生长曲线（字数随时间）

    private var growthCurve: some View {
        GeometryReader { geo in
            let maxC = max(1, snaps.map(\.charCount).max() ?? 1)
            let step = snaps.count > 1 ? geo.size.width / CGFloat(snaps.count - 1) : geo.size.width
            ZStack(alignment: .topLeading) {
                Path { p in
                    for (i, s) in snaps.enumerated() {
                        let x = CGFloat(i) * step
                        let y = geo.size.height * (1 - CGFloat(s.charCount) / CGFloat(maxC))
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }
                .stroke(ConsoleView.green.opacity(0.55), lineWidth: 1.5)
                // 当前位置游标
                Rectangle()
                    .fill(ConsoleView.greenDeep.opacity(0.5))
                    .frame(width: 1)
                    .offset(x: CGFloat(Int(idx)) * step)
            }
        }
        .frame(height: 42)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: - 时间轴

    private var timeline: some View {
        VStack(spacing: 4) {
            Slider(value: $idx, in: 0...Double(max(0, snaps.count - 1)), step: 1)
                .tint(ConsoleView.greenDeep)
                .onChange(of: idx) { _, _ in if playing { stop() } }
            HStack {
                Text(current.map { Self.stamp.string(from: $0.takenAt) } ?? "")
                Spacer()
                if let c = current {
                    Text("\(c.charCount) 字")
                    if c.delta != 0 {
                        Text(c.delta > 0 ? "+\(c.delta)" : "\(c.delta)")
                            .foregroundColor(c.delta > 0 ? ConsoleView.greenDeep : .red.opacity(0.7))
                    }
                }
                Spacer()
                Text("\(Int(idx) + 1)/\(snaps.count)")
            }
            .font(.system(size: Theme.F.caption).monospacedDigit())
            .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 播放控制

    private var transport: some View {
        HStack(spacing: 22) {
            Button { idx = 0 } label: { Image(systemName: "backward.end.fill") }
            Button { playing ? stop() : play() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20))
            }
            Button { idx = Double(snaps.count - 1) } label: { Image(systemName: "forward.end.fill") }
        }
        .foregroundColor(ConsoleView.greenDeep)
        .padding(.vertical, 12)
    }

    private func play() {
        guard snaps.count > 1 else { return }
        if Int(idx) >= snaps.count - 1 { idx = 0 }
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { _ in
            Task { @MainActor in
                guard idx < Double(snaps.count - 1) else { stop(); return }
                idx += 1
            }
        }
    }

    private func stop() {
        playing = false
        timer?.invalidate(); timer = nil
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
}
