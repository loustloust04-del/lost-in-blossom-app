import Foundation

/// WKWebView 默认 UA 缺 `Version/N.N` 字段——部分反爬站据此判定"非真浏览器"拒服务（白屏）。
/// 用真 Safari UA 字串伪装，关键字段 `Version/18.0`。
enum WebUserAgent {
    /// iPhone Safari 18 移动端 UA
    static let iOSMobile =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 平台默认 UA（iOS only）
    static var platformDefault: String { iOSMobile }
}
