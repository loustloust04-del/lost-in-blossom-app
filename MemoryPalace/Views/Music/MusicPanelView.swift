import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 音乐页：歌单 + 播放器 + 逐句歌词。
/// 「一起听」不是他听见声波，是他知道你在听什么、记得这首歌你们之间的事。
struct MusicPanelView: View {
    let profileId: String

    @Environment(\.modelContext) private var context
    @Query private var allSongs: [Song]
    @State private var player = MusicPlayer.shared
    @AppStorage("listenTogetherOn") private var listenTogether = false
    @State private var showImporter = false
    @State private var showLyrics = false
    @State private var tab = 0          // 0=云端曲库 1=本地导入

    private var songs: [Song] {
        allSongs.filter { $0.profileId == profileId }
            .sorted { ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("我的音乐").tag(0)
                Text("导入的").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14).padding(.top, 10)

            if tab == 0 {
                CloudMusicView(profileId: profileId)
            } else {
                if songs.isEmpty { emptyState } else { list }
            }
            if player.currentSong != nil { miniPlayer }
        }
        .background(Theme.sidebarBg.ignoresSafeArea())
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .sheet(isPresented: $showLyrics) {
            LyricsSheet(player: player) { showLyrics = false }
        }
        .onAppear {
            let pid = profileId
            player.urlResolver = { s in MusicPanelView.resolve(s, profileId: pid) }
            // 预取：远端且没缓存的下一首，提前换新直链（直链有时效）并落 MusicCache
            player.prefetcher = { s in
                guard s.isRemote, !s.remoteId.isEmpty, !MusicCache.has(songId: s.remoteId) else { return }
                Task {
                    if let d = await MusicLibraryClient.detail(songId: s.remoteId),
                       let fresh = d.url, let u = URL(string: fresh) {
                        await MainActor.run { s.source = fresh }
                        MusicCache.store(songId: s.remoteId, from: u)
                    }
                }
            }
            player.onSongStarted = { s in
                s.playCount += 1
                s.lastPlayedAt = Date()
                try? context.save()
                Task { await NowPlayingReporter.report(song: s) }
                LivelineReporter.report(.music, "兔兔在听《\(s.title)》— \(s.displayArtist)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 30)).foregroundColor(ConsoleView.green.opacity(0.5))
            Text("还没有歌\n先拖几首进来（mp3 / m4a）")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button("导入音乐") { showImporter = true }
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(ConsoleView.greenDeep)
            Text("歌词：把同名 .lrc 文件一起拖进来")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(songs) { s in
                Button {
                    MusicPanelView.playRemoteSafely(s, list: songs, profileId: profileId,
                                                    player: player, context: context)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: player.currentSong?.id == s.id
                              ? (player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                              : "music.note")
                            .font(.system(size: 12))
                            .foregroundColor(player.currentSong?.id == s.id ? ConsoleView.greenDeep : Theme.textMuted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.system(size: Theme.F.body)).foregroundColor(Theme.textPrimary)
                            HStack(spacing: 6) {
                                Text(s.displayArtist)
                                if s.playCount > 0 { Text("· 听过 \(s.playCount) 次") }
                                if !s.lyrics.isEmpty { Image(systemName: "text.quote").font(.system(size: 8)) }
                            }
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
                .contextMenu {
                    Button {
                        player.playNext(s)
                        HapticService.shared.longPress()
                    } label: { Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") }
                }
            }
            .onDelete { idx in
                for i in idx { context.delete(songs[i]) }
                try? context.save()
            }
            Button("导入音乐") { showImporter = true }
                .font(.system(size: Theme.F.caption))
                .foregroundColor(ConsoleView.greenDeep)
                .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var miniPlayer: some View {
        VStack(spacing: 6) {
            if let line = player.currentLyricText {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundColor(ConsoleView.greenDeep)
                    .lineLimit(1)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.title ?? "")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary).lineLimit(1)
                    Text(player.currentSong?.displayArtist ?? "")
                        .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                }
                Spacer()
                Button {
                    let pid = profileId
                    player.previous { MusicPanelView.resolve($0, profileId: pid) }
                } label: { Image(systemName: "backward.fill") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
                }
                Button {
                    let pid = profileId
                    player.next { MusicPanelView.resolve($0, profileId: pid) }
                } label: { Image(systemName: "forward.fill") }
                Button { showLyrics = true } label: { Image(systemName: "text.quote") }
                // 播放模式：顺序循环 → 单曲循环 → 随机（点按轮换；单曲循环连放≥3遍会推心情信号）
                Button {
                    switch player.playMode {
                    case .sequence:  player.playMode = .repeatOne
                    case .repeatOne: player.playMode = .shuffle
                    case .shuffle:   player.playMode = .sequence
                    }
                } label: {
                    Image(systemName: player.playMode == .repeatOne ? "repeat.1"
                          : player.playMode == .shuffle ? "shuffle" : "repeat")
                        .foregroundColor(player.playMode == .sequence ? ConsoleView.greenDeep : ConsoleView.green)
                }
                // 睡眠定时器：月亮菜单（15/30/60 分钟 / 听完这首停 / 取消）
                Menu {
                    Button("15 分钟后停") { player.setSleepTimer(minutes: 15) }
                    Button("30 分钟后停") { player.setSleepTimer(minutes: 30) }
                    Button("60 分钟后停") { player.setSleepTimer(minutes: 60) }
                    Button(player.stopAfterCurrent ? "✓ 听完这首停" : "听完这首停") { player.toggleStopAfterCurrent() }
                    if player.sleepTimerEndsAt != nil || player.stopAfterCurrent {
                        Button("取消定时", role: .destructive) { player.setSleepTimer(minutes: nil) }
                    }
                } label: {
                    Image(systemName: (player.sleepTimerEndsAt != nil || player.stopAfterCurrent) ? "moon.zzz.fill" : "moon.zzz")
                        .foregroundColor((player.sleepTimerEndsAt != nil || player.stopAfterCurrent) ? ConsoleView.green : ConsoleView.greenDeep)
                }
                // T2 叫他一起听：邀请这个动作本身有仪式感（plan-listen-together-v2 D2）。
                // 亮 = 共听中（心跳替你续命，切歌不断场；停播 5min 网关侧自动过期）
                Button {
                    listenTogether.toggle()
                    let song = player.currentSong
                    Task.detached(priority: .utility) {
                        await ListenTogetherClient.set(on: listenTogether, title: song?.title, artist: song?.artist)
                    }
                } label: {
                    Image(systemName: listenTogether ? "person.2.fill" : "person.2")
                        .foregroundColor(listenTogether ? ConsoleView.green : ConsoleView.greenDeep)
                }
            }
            .foregroundColor(ConsoleView.greenDeep)
            ProgressView(value: player.duration > 0 ? min(1, player.currentTime / player.duration) : 0)
                .tint(ConsoleView.green)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.mainBg)
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let rel = "music/\(url.lastPathComponent)"
            guard let dest = FileLibraryStore.absoluteURL(rel, profileId: profileId) else { continue }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: dest)

            var lrc = ""
            let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
            if let d = try? Data(contentsOf: lrcURL) { lrc = String(data: d, encoding: .utf8) ?? "" }

            var title = name, artist = ""
            if let r = name.range(of: " - ") {
                artist = String(name[..<r.lowerBound])
                title = String(name[r.upperBound...])
            }
            context.insert(Song(profileId: profileId, title: title, artist: artist,
                                source: rel, lyrics: lrc))
        }
        try? context.save()
    }

    /// 本地缓存优先 → 本地文件 → 上次的直链（可能已过期，由 refreshIfStale 兜底换新）
    static func resolve(_ s: Song, profileId: String) -> URL? {
        if s.isRemote {
            if let cached = MusicCache.localURL(songId: s.remoteId) { return cached }
            return URL(string: s.source)
        }
        return FileLibraryStore.absoluteURL(s.source, profileId: profileId)
    }

    /// 远端歌且没缓存时，去换一条新直链再播（直链有时效，隔天点会没声音）
    static func playRemoteSafely(_ s: Song, list: [Song], profileId: String,
                                 player: MusicPlayer, context: ModelContext) {
        if !s.isRemote || MusicCache.has(songId: s.remoteId) {
            player.play(song: s, in: list) { resolve($0, profileId: profileId) }
            return
        }
        Task {
            if !s.remoteId.isEmpty, let d = await MusicLibraryClient.detail(songId: s.remoteId),
               let fresh = d.url {
                await MainActor.run {
                    s.source = fresh
                    if !d.lyric.isEmpty { s.lyrics = d.lyric }
                    try? context.save()
                }
                MusicCache.store(songId: s.remoteId, from: URL(string: fresh)!)
            }
            await MainActor.run {
                player.play(song: s, in: list) { resolve($0, profileId: profileId) }
            }
        }
    }
}

/// 全屏歌词：逐句高亮跟唱，点某句跳到那儿，长按发给他
struct LyricsSheet: View {
    let player: MusicPlayer
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if player.lyrics.isEmpty {
                            Text("这首没有歌词\n（把同名 .lrc 拖进来就有了）")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                                .multilineTextAlignment(.center)
                                .padding(.top, 60)
                        }
                        ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { i, l in
                            Text(l.text)
                                .font(.system(size: i == player.currentLyricIndex ? 18 : 15,
                                              weight: i == player.currentLyricIndex ? .semibold : .regular))
                                .foregroundColor(i == player.currentLyricIndex ? Theme.textPrimary : Theme.textMuted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(i)
                                .onTapGesture { if l.time >= 0 { player.seek(to: l.time) } }
                                .contextMenu {
                                    Button { sendLine(l.text) } label: {
                                        Label("指着这句跟他说", systemImage: "bubble.left")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 40)
                }
                .onChange(of: player.currentLyricIndex) { _, idx in
                    guard let idx else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle(player.currentSong?.title ?? "歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("收起") { onClose() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
    }

    private func sendLine(_ text: String) {
        guard let s = player.currentSong else { return }
        let payload = """
        〈她在听歌〉《\(s.title)》— \(s.displayArtist)，正放到这句，她指着它给你看：

        「\(text)」
        """
        // T3（plan-listen-together-v2 D1）：改道主对话。原来发进 music-<songId> 的
        // 独立会话——她指一句，他在一个她从来不看的会话里回，情话全打了水漂。
        // 主对话 id 从最近一次 CC 发送记下的 lastCCChatId 取；一次都没聊过才回落老路。
        let mainChat = UserDefaults.standard.string(forKey: "lastCCChatId")
        CCBridgeWebSocketClient.shared.sendChat(
            chatId: mainChat ?? "music-\(s.id)", messageId: UUID().uuidString, content: payload) { _ in }
    }
}

extension NowPlayingReporter {
    /// liveline 事件直投（单曲循环等心情信号用；节流在网关侧按 kind 管）
    static func livelineEvent(kind: String, text: String) async {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        guard let url = URL(string: "\(base)/api/liveline") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let tk = UserDefaults.standard.string(forKey: "gatewayAuthToken"), !tk.isEmpty {
            req.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": kind, "text": text])
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// T2 共听开关（网关 /listen/start|stop；路由随下次网关重启生效，之前静默失败无副作用）
enum ListenTogetherClient {
    static func set(on: Bool, title: String?, artist: String?) async {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        guard let url = URL(string: "\(base)/listen/\(on ? "start" : "stop")?key=bunny-lib-2026") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let artist { body["artist"] = artist }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// 开播/心跳把「她在听什么·听到哪儿」报给网关（Caelum 的 now_playing 工具读的就是它）
enum NowPlayingReporter {
    static func report(song: Song) async {
        await beat(title: song.title, artist: song.artist, album: song.album,
                   position: 0, duration: song.durationSec, line: nil, state: "playing")
    }

    /// T1 共听心跳：进度 + 当前 LRC 行 + 播放状态（plan-listen-together-v2）
    static func beat(title: String, artist: String?, album: String?,
                     position: Double, duration: Double, line: String?, state: String) async {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        guard let url = URL(string: "\(base)/now-playing?key=bunny-lib-2026") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        var body: [String: Any] = [
            "title": title, "position": position, "duration": duration, "state": state,
        ]
        if let artist { body["artist"] = artist }
        if let album { body["album"] = album }
        if let line { body["line"] = line }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
