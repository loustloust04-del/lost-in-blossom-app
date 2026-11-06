import Foundation

/// [B 2026-11-07] 网关口令统一从设置读（UserDefaults「gatewayAuthToken」，即设置页填的那个），
/// 不再写死在代码里——旧口令已随公开仓库泄露，网关改为「读数据只认新口令」。
enum GatewayKey {
    static var current: String { UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? "" }
    static var query: String { current.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }
}
