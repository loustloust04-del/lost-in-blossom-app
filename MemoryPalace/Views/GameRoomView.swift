import SwiftUI
import WebKit

/// 游戏室（09-28）：Fable 搭房子，Caelum 装修——每个游戏都是他写的单文件 HTML，
/// 通过 window.room 这根管子和她对局。服务端在 gateway/src/gameroom.ts。
enum GameRoomAPI {
    static var base: String { UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com" }
    static var token: String { UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? "" }

    static func request(_ path: String, method: String = "GET", body: Any? = nil) async -> Any? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

struct GameRoomView: View {
    @Environment(\.dismiss) private var dismiss
    struct GameMeta: Identifiable, Hashable { let id: String; let title: String; let description: String }
    @State private var games: [GameMeta] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().tint(Theme.textMuted)
                } else if games.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "dice").font(.system(size: 34)).foregroundColor(Theme.textMuted.opacity(0.4))
                        Text("游戏室还空着").font(.system(size: 14)).foregroundColor(Theme.textMuted)
                        Text("这是他的屋子，让他来装修").font(.system(size: 12)).foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                } else {
                    List(games) { g in
                        NavigationLink(value: g) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(g.title).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textPrimary)
                                if !g.description.isEmpty {
                                    Text(g.description).font(.system(size: 12)).foregroundColor(Theme.textMuted).lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.mainBg)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.mainBg.ignoresSafeArea())
            .navigationTitle("游戏室")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: GameMeta.self) { g in GamePlayerView(gameId: g.id, title: g.title) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundColor(Theme.textMuted) }
                }
            }
            .refreshable { await load() }
        }
        .task { await load() }
    }

    private func load() async {
        let j = await GameRoomAPI.request("/api/gameroom/games") as? [String: Any]
        let arr = (j?["games"] as? [[String: Any]]) ?? []
        games = arr.compactMap { d in
            guard let id = d["id"] as? String, let t = d["title"] as? String else { return nil }
            return GameMeta(id: id, title: t, description: d["description"] as? String ?? "")
        }
        loading = false
    }
}

/// 一个游戏的对局页：加载他写的 HTML，注入 window.room，轮询对局变化
struct GamePlayerView: View {
    let gameId: String
    let title: String
    @State private var html: String? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let html {
                GameWebView(gameId: gameId, html: html)
            } else if failed {
                Text("加载不到这个游戏").font(.system(size: 13)).foregroundColor(Theme.textMuted)
            } else {
                ProgressView().tint(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.mainBg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let j = await GameRoomAPI.request("/api/gameroom/games/\(gameId)") as? [String: Any]
            if let h = j?["html"] as? String { html = h } else { failed = true }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// window.room 管子：
///   room.me                    "bunny"
///   room.ready(cb)             管子通了回调 cb(match|null)——最近一局（可能已结束）
///   room.start(state, turn, text) → Promise<match>   开新局
///   room.move({move, state, turn, text, status}) → Promise<match>   她落子（turn 交给 "caelum" 就会叫他）
///   room.onUpdate(cb)          对局变了（他落子了）就回调 cb(match)
struct GameWebView: UIViewRepresentable {
    let gameId: String
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator(gameId: gameId) }

    func makeUIView(context: Context) -> WKWebView {
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "room")
        ucc.addUserScript(WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = ucc
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        context.coordinator.webView = wv
        wv.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.stop() }

    static let bridgeJS = """
    (function(){
      let seq = 0; const pend = {}; const upd = []; let readyCb = null, readyVal = undefined, isReady = false;
      function call(cmd, args){ return new Promise(res => { const id = ++seq; pend[id] = res;
        window.webkit.messageHandlers.room.postMessage({cmd, args, id}); }); }
      window.__roomResolve = (id, v) => { const r = pend[id]; delete pend[id]; if (r) r(v); };
      window.__roomUpdate = (m) => { upd.forEach(f => { try { f(m) } catch(e){} }); };
      window.__roomReady = (m) => { isReady = true; readyVal = m; if (readyCb) readyCb(m); };
      window.room = {
        me: 'bunny',
        ready(cb){ readyCb = cb; if (isReady) cb(readyVal); },
        start(state, turn, text){ return call('start', {state, turn, text}); },
        move(o){ return call('move', o || {}); },
        onUpdate(cb){ upd.push(cb); },
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let gameId: String
        weak var webView: WKWebView?
        var matchId: String? = nil
        var lastUpdated: String = ""
        var timer: Timer? = nil

        init(gameId: String) { self.gameId = gameId; super.init(); Task { await boot() } }

        func stop() { timer?.invalidate(); timer = nil }

        @MainActor private func js(_ fn: String, _ args: [Any]) {
            let parts = args.map { a -> String in
                if let d = try? JSONSerialization.data(withJSONObject: a, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) { return s }
                return "null"
            }
            webView?.evaluateJavaScript("\(fn)(\(parts.joined(separator: ",")))")
        }

        private func boot() async {
            // 页面加载需要一点时间；最近一局交给 ready
            try? await Task.sleep(nanoseconds: 400_000_000)
            let j = await GameRoomAPI.request("/api/gameroom/matches?gameId=\(gameId)") as? [String: Any]
            let latest = (j?["matches"] as? [[String: Any]])?.first
            matchId = latest?["id"] as? String
            lastUpdated = latest?["updatedAt"] as? String ?? ""
            await MainActor.run {
                js("window.__roomReady", [latest ?? NSNull()])
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { await self?.poll() } }
            }
        }

        private func poll() async {
            guard let id = matchId else { return }
            guard let m = await GameRoomAPI.request("/api/gameroom/matches/\(id)") as? [String: Any] else { return }
            let u = m["updatedAt"] as? String ?? ""
            if u != lastUpdated {
                lastUpdated = u
                await MainActor.run { js("window.__roomUpdate", [m]) }
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String, let id = body["id"] as? Int else { return }
            let args = body["args"] as? [String: Any] ?? [:]
            Task {
                var result: Any? = nil
                if cmd == "start" {
                    var b: [String: Any] = ["gameId": gameId, "state": args["state"] ?? [:], "turn": args["turn"] as? String ?? "bunny"]
                    if let t = args["text"] as? String { b["text"] = t }
                    result = await GameRoomAPI.request("/api/gameroom/matches", method: "POST", body: b)
                    if let m = result as? [String: Any] { matchId = m["id"] as? String; lastUpdated = m["updatedAt"] as? String ?? "" }
                } else if cmd == "move", let mid = matchId {
                    result = await GameRoomAPI.request("/api/gameroom/matches/\(mid)/move", method: "POST", body: args)
                    if let m = result as? [String: Any] { lastUpdated = m["updatedAt"] as? String ?? "" }
                }
                await MainActor.run { js("window.__roomResolve", [id, result ?? NSNull()]) }
            }
        }
    }
}
