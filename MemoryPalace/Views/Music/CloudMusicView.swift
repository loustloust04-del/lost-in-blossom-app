import SwiftUI
import SwiftData

/// 云端曲库：我的歌单 + 搜索。点一首就播（直链现取，有时效）。
struct CloudMusicView: View {
    let profileId: String
    @Environment(\.modelContext) private var context
    @State private var player = MusicPlayer.shared

    @State private var status: MusicLibraryClient.Status?
    @State private var playlists: [MusicLibraryClient.Playlist] = []
    @State private var openedList: MusicLibraryClient.Playlist?
    @State private var listSongs: [MusicLibraryClient.RemoteSong] = []
    @State private var searchText = ""
    @State private var searchResults: [MusicLibraryClient.RemoteSong] = []
    @State private var loading = false
    @State private var loadingSongId: String?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .task {
            status = await MusicLibraryClient.status()
            playlists = await MusicLibraryClient.playlists()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.textMuted)
            TextField("搜歌名、歌手", text: $searchText)
                .font(.system(size: Theme.F.body))
                .submitLabel(.search)
                .onSubmit { runSearch() }
            if !searchText.isEmpty {
                Button { searchText = ""; searchResults = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textMuted)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.mainBg))
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().tint(ConsoleView.greenDeep).frame(maxHeight: .infinity)
        } else if !searchResults.isEmpty {
            songList(searchResults, title: "搜索结果")
        } else if let l = openedList {
            VStack(spacing: 0) {
                HStack {
                    Button { openedList = nil; listSongs = [] } label: {
                        Label(l.name, systemImage: "chevron.left")
                            .font(.system(size: Theme.F.caption))
                    }
                    .foregroundColor(ConsoleView.greenDeep)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
                songList(listSongs, title: nil)
            }
        } else {
            playlistGrid
        }
    }

    private var playlistGrid: some View {
        List {
            if let s = status, s.loggedIn {
                Section {
                    ForEach(playlists) { p in
                        Button { open(p) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 13))
                                    .foregroundColor(ConsoleView.greenDeep)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.system(size: Theme.F.body)).foregroundColor(Theme.textPrimary)
                                    Text("\(p.count) 首").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.mainBg)
                    }
                } header: {
                    Text("\(s.nickname ?? "我")的歌单")
                }
            } else {
                Text("音源没连上——网关登录态可能过期了，跟 Claude 说一声重新扫码。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func songList(_ songs: [MusicLibraryClient.RemoteSong], title: String?) -> some View {
        List {
            Section {
                ForEach(songs) { s in
                    Button { playRemote(s, in: songs) } label: {
                        HStack(spacing: 10) {
                            if loadingSongId == s.id {
                                ProgressView().scaleEffect(0.6).frame(width: 18)
                            } else {
                                Image(systemName: player.currentSong?.title == s.title
                                      ? (player.isPlaying ? "speaker.wave.2.fill" : "pause.fill") : "music.note")
                                    .font(.system(size: 12))
                                    .foregroundColor(player.currentSong?.title == s.title
                                                     ? ConsoleView.greenDeep : Theme.textMuted)
                                    .frame(width: 18)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.textPrimary).lineLimit(1)
                                Text(s.artist).font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.mainBg)
                    .contextMenu {
                        Button {
                            queueNext(r: s)
                        } label: { Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    }
                }
            } header: { if let t = title { Text(t) } }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 动作

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        Task {
            searchResults = await MusicLibraryClient.search(q)
            loading = false
        }
    }

    private func open(_ p: MusicLibraryClient.Playlist) {
        loading = true
        openedList = p
        Task {
            listSongs = await MusicLibraryClient.songs(inPlaylist: p.id)
            loading = false
        }
    }

    /// 云端歌曲：现取直链和歌词 → 落成本地 Song（带 isRemote）→ 交给播放器
    /// 云端歌「下一首播放」：解析直链→建 Song（边听边存照旧）→插队；没在放歌就直接开播
    private func queueNext(r: MusicLibraryClient.RemoteSong) {
        Task {
            guard let d = await MusicLibraryClient.detail(songId: r.id), let url = d.url else { return }
            let song = Song(profileId: profileId, title: r.title, artist: r.artist, album: r.album,
                            source: url, isRemote: true, durationSec: Double(r.duration), lyrics: d.lyric)
            song.remoteId = r.id
            context.insert(song)
            try? context.save()
            if let remote = URL(string: url) { MusicCache.store(songId: r.id, from: remote) }
            await MainActor.run {
                player.playNext(song)
                HapticService.shared.longPress()
            }
        }
    }

    private func playRemote(_ r: MusicLibraryClient.RemoteSong, in list: [MusicLibraryClient.RemoteSong]) {
        loadingSongId = r.id
        Task {
            defer { loadingSongId = nil }
            guard let d = await MusicLibraryClient.detail(songId: r.id), let url = d.url else { return }
            let song = Song(profileId: profileId, title: r.title, artist: r.artist, album: r.album,
                            source: url, isRemote: true, durationSec: Double(r.duration), lyrics: d.lyric)
            song.remoteId = r.id
            context.insert(song)
            try? context.save()
            // 边听边存，下次就是本地文件
            if let remote = URL(string: url) { MusicCache.store(songId: r.id, from: remote) }
            player.play(song: song, in: [song]) { s in
                MusicCache.localURL(songId: s.remoteId) ?? URL(string: s.source)
            }
        }
    }
}
