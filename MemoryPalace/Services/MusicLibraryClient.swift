import Foundation

/// 网易云音源客户端。App 里零网易代码——只认自家网关，cookie 在服务器不下发。
enum MusicLibraryClient {
    struct RemoteSong: Codable, Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Int
        var cover: String? = nil
    }
    struct Playlist: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
        var cover: String? = nil
    }
    struct SongDetail: Codable {
        let url: String?
        let lyric: String
        var translated: String? = nil
        var level: String? = nil
    }
    struct Status: Codable {
        let loggedIn: Bool
        var nickname: String? = nil
        var vip: Int? = nil
    }

    private static var base: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private static var key: String { "bunny-lib-2026" }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async -> T? {
        var comps = URLComponents(string: base + path)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "key", value: key))
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private struct SongsWrap: Codable { let songs: [RemoteSong] }
    private struct ListsWrap: Codable { let playlists: [Playlist] }

    static func status() async -> Status? { await get("/api/music/status") }

    static func search(_ q: String) async -> [RemoteSong] {
        let w: SongsWrap? = await get("/api/music/search", ["q": q])
        return w?.songs ?? []
    }

    static func playlists() async -> [Playlist] {
        let w: ListsWrap? = await get("/api/music/playlists")
        return w?.playlists ?? []
    }

    static func songs(inPlaylist id: String) async -> [RemoteSong] {
        let w: SongsWrap? = await get("/api/music/playlist/\(id)")
        return w?.songs ?? []
    }

    /// 播放前取直链和歌词（直链有时效，每次播放前现取）
    static func detail(songId: String) async -> SongDetail? {
        await get("/api/music/song/\(songId)")
    }
}
