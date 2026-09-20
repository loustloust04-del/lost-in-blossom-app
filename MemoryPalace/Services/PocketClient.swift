import Foundation
import WebKit

/// Pocket Browser 客户端 —— 让 Caelum 借这台手机里的 WKWebView 浏览网页。
/// 连 wss {gateway}/pocket/ws?token=，收网关下发的命令（ping/goto/js/html/screenshot），
/// 在离屏 WKWebView（共享默认 cookie/登录态）上执行，回结果。断线指数退避重连。
/// 默认关闭（UserDefaults "pocketBrowserEnabled"）——只有兔兔主动开启才让 Caelum 能驱动。
@MainActor
final class PocketClient: NSObject {
    static let shared = PocketClient()

    private var webView: WKWebView?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var running = false
    private var reconnectDelay: TimeInterval = 2

    private(set) var isConnected = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "pocketBrowserEnabled") }

    private var wsURL: URL? {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        let ws = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let token = UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
        guard !token.isEmpty else { return nil }
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return URL(string: "\(ws)/pocket/ws?token=\(encoded)")
    }

    // MARK: - 生命周期

    /// 开关打开且已配置 token 时才连。App 启动 / 控制台出现时调用。
    func startIfEnabled() {
        guard Self.isEnabled else { return }
        start()
    }

    func start() {
        guard !running else { return }
        running = true
        ensureWebView()
        connect()
    }

    func stop() {
        running = false
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func ensureWebView() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 共享 cookie / 登录态
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
    }

    private func connect() {
        guard running, let url = wsURL else { running = false; return }
        let s = URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        isConnected = true
        reconnectDelay = 2
        send(json: ["type": "hello", "client": "ios"])
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    self.isConnected = false
                    self.scheduleReconnect()
                case .success(let message):
                    await self.handle(message)
                    self.receiveLoop()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard running else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
    }

    // MARK: - 命令执行

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        guard case let .string(text) = message,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let action = obj["action"] as? String else { return }
        do {
            let result = try await execute(action: action, payload: obj)
            reply(id: id, ok: true, result: result)
        } catch {
            reply(id: id, ok: false, error: error.localizedDescription)
        }
    }

    private func execute(action: String, payload: [String: Any]) async throws -> Any {
        ensureWebView()
        guard let wv = webView else { throw PocketError.noWebView }
        switch action {
        case "ping":
            return "pong"
        case "goto":
            guard let urlStr = payload["url"] as? String, let url = URL(string: urlStr) else { throw PocketError.badInput }
            wv.load(URLRequest(url: url))
            return "loading \(urlStr)"
        case "js", "code":
            let code = (payload["code"] as? String) ?? (payload["js"] as? String) ?? ""
            return try await evalJS(wv, code)
        case "html":
            return try await evalJS(wv, "document.documentElement.outerHTML")
        case "screenshot":
            return try await snapshot(wv)
        default:
            throw PocketError.unknownAction
        }
    }

    /// 用 completion 版本（async 版遇 undefined 结果会崩），nil 结果安全归一为空串。
    private func evalJS(_ wv: WKWebView, _ code: String) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            wv.evaluateJavaScript(code) { result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: PocketClient.stringify(result))
                }
            }
        }
    }

    private func snapshot(_ wv: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            let cfg = WKSnapshotConfiguration()
            wv.takeSnapshot(with: cfg) { image, error in
                if let error { cont.resume(throwing: error); return }
                guard let png = image?.pngData() else { cont.resume(throwing: PocketError.snapshot); return }
                cont.resume(returning: "data:image/png;base64," + png.base64EncodedString())
            }
        }
    }

    private static func stringify(_ r: Any?) -> Any {
        guard let r, !(r is NSNull) else { return "" }
        if let s = r as? String { return s }
        if let n = r as? NSNumber { return n.stringValue }
        if JSONSerialization.isValidJSONObject(r),
           let d = try? JSONSerialization.data(withJSONObject: r),
           let s = String(data: d, encoding: .utf8) { return s }
        return String(describing: r)
    }

    private func reply(id: String, ok: Bool, result: Any? = nil, error: String? = nil) {
        var obj: [String: Any] = ["id": id, "ok": ok]
        if let result { obj["result"] = result }
        if let error { obj["error"] = error }
        send(json: obj)
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    enum PocketError: LocalizedError {
        case noWebView, badInput, unknownAction, snapshot
        var errorDescription: String? {
            switch self {
            case .noWebView:      return "webview not ready"
            case .badInput:       return "bad input"
            case .unknownAction:  return "unknown action"
            case .snapshot:       return "snapshot failed"
            }
        }
    }
}
