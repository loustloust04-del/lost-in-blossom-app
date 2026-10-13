import SwiftUI
import SwiftData

/// 音乐卡（10-05，收粟粟的菜：她 09-26 的 MusicCardView——黑胶 + 波形进度；我们这版接网易云和一起听）。
/// 他在回复里写 ```card-music {"song_id":"…","title":"…","artist":"…","cover":"…","note":"…"}
/// 或只写 {"query":"晴天 周杰伦"}（点播放时去网易云搜第一首）。
/// 点播放 = 走和他「放歌给你」(music_play) 同一条路：取直链 → 建 Song → MusicPlayer 开播，
/// 所以 now_playing / 一起听那边他也能看到唱到哪句。
struct MusicCard {
    let songId: String?
    let query: String?
    let title: String
    let artist: String
    let cover: String?
    let note: String?

    init?(_ o: [String: Any]) {
        let sid = (o["song_id"] ?? o["id"]).map { "\($0)" }
        let q = o["query"] as? String
        guard sid != nil || q != nil else { return nil }
        songId = sid
        query = q
        title = o["title"] as? String ?? (q ?? "一首歌")
        artist = o["artist"] as? String ?? ""
        cover = o["cover"] as? String
        note = o["note"] as? String
    }
}

@MainActor
enum MusicCardPlayback {
    /// 和 onMusicCommand 同一条路
    static func play(songId: String, title: String, artist: String, profileId: String, context: ModelContext) async -> Bool {
        guard let d = await MusicLibraryClient.detail(songId: songId), let url = d.url else { return false }
        let song = Song(profileId: profileId, title: title, artist: artist, album: "",
                        source: url, isRemote: true, durationSec: 0, lyrics: d.lyric)
        song.remoteId = songId
        context.insert(song)
        try? context.save()
        if let remote = URL(string: url) { MusicCache.store(songId: songId, from: remote) }
        MusicPlayer.shared.play(song: song, in: [song]) { s in
            MusicCache.localURL(songId: s.remoteId) ?? URL(string: s.source)
        }
        return true
    }
}

struct MusicCardView: View {
    let card: MusicCard
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var resolvedId: String? = nil
    @State private var resolvedTitle: String? = nil
    @State private var resolvedArtist: String? = nil
    @State private var resolvedCover: String? = nil
    @State private var loading = false
    @State private var failed = false
    @State private var spin: Double = 0
    @State private var dragProgress: Double? = nil

    private var player: MusicPlayer { MusicPlayer.shared }
    private var sid: String? { resolvedId ?? card.songId }
    private var isMine: Bool { sid != nil && player.currentSong?.remoteId == sid }
    private var playing: Bool { isMine && player.isPlaying }
    private var progress: Double {
        if let d = dragProgress { return d }
        guard isMine, player.duration > 0 else { return 0 }
        return min(1, player.currentTime / player.duration)
    }
    private var title: String { resolvedTitle ?? card.title }
    private var artist: String { resolvedArtist ?? card.artist }
    private var coverURL: URL? { (resolvedCover ?? card.cover).flatMap(URL.init(string:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                vinyl
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    if !artist.isEmpty {
                        Text(artist).font(.system(size: 12)).foregroundColor(Theme.textMuted).lineLimit(1)
                    }
                    if let n = card.note, !n.isEmpty {
                        Text(n).font(.system(size: 12).italic()).foregroundColor(Theme.textMuted).lineLimit(2).padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
                Button(action: tap) {
                    ZStack {
                        Circle().fill(Theme.branchIndicator).frame(width: 40, height: 40)
                        if loading { ProgressView().tint(.white) }
                        else {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                                .contentTransition(.symbolEffect(.replace))
                                .offset(x: playing ? 0 : 1.5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
            waveform
            if failed {
                Text("这首放不了（可能没版权或网易云没登录）").font(.system(size: 11)).foregroundColor(Theme.danger)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg.opacity(0.75))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)))
        .onAppear { if playing { startSpin() } }
        .onChange(of: playing) { _, p in if p { startSpin() } }
    }

    // 黑胶：唱片纹 + 中间封面，放着的时候慢慢转
    private var vinyl: some View {
        ZStack {
            Circle().fill(Color(red: 0.08, green: 0.08, blue: 0.09))
            ForEach(0..<5) { i in
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.6).padding(CGFloat(4 + i * 3))
            }
            Group {
                if let u = coverURL {
                    AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color(red: 0.55, green: 0.74, blue: 0.62) }
                } else {
                    Color(red: 0.55, green: 0.74, blue: 0.62)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            Circle().fill(Color(red: 0.08, green: 0.08, blue: 0.09)).frame(width: 5, height: 5)
        }
        .frame(width: 58, height: 58)
        .rotationEffect(.degrees(spin))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    // 波形当进度条：已放的部分亮；手指拖动可快进倒退（只在正在放这首时）
    private var waveform: some View {
        let bars: [CGFloat] = {
            var x = UInt64(truncatingIfNeeded: (sid ?? card.title).hashValue) &+ 0x9E3779B97F4A7C15
            return (0..<44).map { _ in x ^= x << 13; x ^= x >> 7; x ^= x << 17; return 0.25 + CGFloat(x % 100) / 140 }
        }()
        return GeometryReader { g in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, h in
                    let lit = Double(i) / Double(bars.count) < progress
                    Capsule()
                        .fill(lit ? Theme.branchIndicator : Theme.textMuted.opacity(0.25))
                        .frame(height: 20 * h * (playing && lit ? 1.0 : 0.85))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in guard isMine else { return }; dragProgress = max(0, min(1, v.location.x / g.size.width)) }
                .onEnded { _ in
                    if let p = dragProgress, isMine, player.duration > 0 { player.seek(to: p * player.duration) }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragProgress = nil }
                })
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.2), value: progress)
    }

    private func startSpin() {
        spin = spin.truncatingRemainder(dividingBy: 360)
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { spin += 360 }
    }

    private func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if isMine { player.toggle(); if !player.isPlaying { spin = spin.truncatingRemainder(dividingBy: 360) }; return }
        loading = true
        failed = false
        Task {
            var id = card.songId
            if id == nil, let q = card.query, let first = await MusicLibraryClient.search(q).first {
                id = first.id
                resolvedId = first.id; resolvedTitle = first.title; resolvedArtist = first.artist; resolvedCover = first.cover
            }
            guard let songId = id else { loading = false; failed = true; return }
            let ok = await MusicCardPlayback.play(songId: songId, title: title, artist: artist,
                                                  profileId: profileManager?.currentProfile.id ?? "", context: modelContext)
            loading = false
            failed = !ok
        }
    }
}

/// 正在放歌时，聊天页顶栏下面一颗小玻璃胶囊（粟粟 09-27 同款）：转着的小黑胶 + 歌名 + 暂停/继续。
/// 切到别的对话也在，歌不停。
struct NowPlayingCapsule: View {
    private var player: MusicPlayer { MusicPlayer.shared }
    @State private var spin: Double = 0

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    Circle().fill(Color(red: 0.55, green: 0.74, blue: 0.62)).frame(width: 9, height: 9)
                }
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(spin))
                Text(song.artist.isEmpty ? song.title : "\(song.title) · \(song.artist)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 24, height: 24)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 5)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Theme.textMuted.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .onAppear { if player.isPlaying { startSpin() } }
            .onChange(of: player.isPlaying) { _, p in if p { startSpin() } else { spin = spin.truncatingRemainder(dividingBy: 360) } }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func startSpin() {
        withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin += 360 }
    }
}
