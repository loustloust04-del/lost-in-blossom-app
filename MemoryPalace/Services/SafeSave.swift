import Foundation
import SwiftData

/// 存盘失败不再无声无息。
///
/// 审查报告 2026-08-12 的头号发现：`try? context.save()` 遍布 8 个文件 15+ 处，
/// 写失败时**完全没人知道** —— 药物同步产生重复、聊天数据可能丢、记忆存不进去，
/// 用户侧一点提示都没有。这也是我们今天被咬三次的同一个模式
/// （门铃看着在工作其实一条没发、歌隔天点就哑、健康数据超期被删）。
///
/// 用法：`context.saveOrReport("吃药打卡")`
/// - 成功：什么都不发生（和 try? 一样安静）
/// - 失败：控制台留下带上下文的错误 + 给用户一个 toast，不再静默
extension ModelContext {

    /// 存盘，失败时报告而不是吞掉。
    /// - Parameters:
    ///   - what: 这次存的是什么（出错时给用户看，比如「吃药打卡」「刻痕」）
    ///   - notifyUser: 是否弹 toast。后台同步类的传 false，只记日志。
    @discardableResult
    func saveOrReport(_ what: String, notifyUser: Bool = true) -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            let detail = (error as NSError).localizedDescription
            print("⚠️ [SafeSave] \(what) 存盘失败：\(detail)")
            // 保险：同时上报服务器。兔兔曾被这个 bug 吞掉过两个聊天窗口，
            // 当时没有任何痕迹可查——现在就算她没注意到 toast，事后也能翻到。
            SaveFailureReporter.report(what: what, detail: detail)
            if notifyUser {
                Task { @MainActor in
                    ToastCenter.shared.show("\(what)没存上，再试一次？")
                }
            }
            return false
        }
    }
}


/// 存盘失败的黑匣子：本地留一份 + 上报服务器。
enum SaveFailureReporter {
    private static let logKey = "safeSave.failures"

    static func report(what: String, detail: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(what): \(detail)"

        // 本地环形日志（留最近 50 条，App 内可查）
        var log = UserDefaults.standard.stringArray(forKey: logKey) ?? []
        log.append(line)
        if log.count > 50 { log = Array(log.suffix(50)) }
        UserDefaults.standard.set(log, forKey: logKey)

        // 上报服务器（失败就算了，本地那份还在）
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        guard let url = URL(string: "\(base)/api/save-failure?key=bunny-lib-2026") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["what": what, "detail": detail])
        URLSession.shared.dataTask(with: req).resume()
    }

    /// App 内查最近的失败记录
    static func recentFailures() -> [String] {
        UserDefaults.standard.stringArray(forKey: logKey) ?? []
    }
}
