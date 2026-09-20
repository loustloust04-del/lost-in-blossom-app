import ReplayKit
import UIKit
import CoreImage

/// 屏幕直播（连拍版）· Broadcast Upload Extension
///
/// 每 ~2.5s 抓一帧 → 缩到 720p → JPEG → POST /api/screen/frame。
/// 服务端 gateway/src/screencast.ts 只留最新一张、覆盖写（隐私红线 1）。
///
/// 为什么是连拍不是视频流：
/// Extension 内存上限 **50MB**，超一字节立刻被系统杀（不给你机会处理）。
/// 视频编码器 + 缓冲区很容易撞墙；连拍每帧独立、用完即弃，稳得多。
/// 2.5s 一帧对「他随时能看到她在干嘛」已经够用——比原来的邮件截图链路快一个数量级。
///
/// 三条已知约束（screencast.ts 红线，此处对应实现）：
/// 1. 只留最新一张——服务端覆盖写，这里不缓存不重传
/// 2. 判活看帧的新鲜度——broadcastFinished 的「我停了」大概率发不出去，别依赖它
/// 3. **主 App 关不掉共享**——Apple 无此接口，只能她自己去控制中心停。
///    Extension 是独立进程，主 App 被划掉它照样传
class SampleHandler: RPBroadcastSampleHandler {

    /// 抓帧间隔。2.5s 是服务端 LIVE_WINDOW_MS(12s) / FRESH_MS(8s) 两个窗口下的舒适值
    private let interval: TimeInterval = 2.5
    private var lastSent: TimeInterval = 0
    /// 同一时刻只允许一个上传在飞——网络慢时别堆积，堆积就撞内存墙
    private var inFlight = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.allowsCellularAccess = true
        // 后台任务在 Extension 里不可用，直接用默认 session
        return URLSession(configuration: c)
    }()

    private var baseURL: String {
        // App Group 共享设置；取不到就用默认域名（与主 App 的 fallback 一致）
        let d = UserDefaults(suiteName: "group.com.susu.MemoryPalace")
        return d?.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private var key: String {
        let d = UserDefaults(suiteName: "group.com.susu.MemoryPalace")
        return d?.string(forKey: "phoneDataKey") ?? "bunny-lib-2026"
    }

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        postState(active: true)
    }

    override func broadcastFinished() {
        // 红线 2：iOS 只给一两秒，这条大概率发不出去。发了也不指望它到，
        // 服务端靠「最后一帧多久前到的」判活。
        postState(active: false)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }

        let now = Date().timeIntervalSince1970
        guard now - lastSent >= interval, !inFlight else { return }
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let jpeg = makeJPEG(from: px) else { return }

        lastSent = now
        inFlight = true
        upload(jpeg)
    }

    // MARK: - 编码

    /// 缩到长边 1280（约 720p）再压 JPEG。分辨率和质量都往下压——
    /// 目标是「看得清她在用哪个 app、在读哪一段」，不是留档。
    private func makeJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = ci.extent.width, h = ci.extent.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, 1280.0 / max(w, h))
        let scaled = scale < 1.0
            ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ci
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.5)
    }

    // MARK: - 上传

    private func upload(_ jpeg: Data) {
        guard let url = URL(string: baseURL + "/api/screen/frame") else { inFlight = false; return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // header 而非 query：query 会进 nginx access log（screencast.ts:74 注明）
        req.setValue(key, forHTTPHeaderField: "x-screen-key")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg
        session.dataTask(with: req) { [weak self] _, _, _ in
            // 失败不重传：下一帧 2.5s 后就来了，重传只会堆内存
            self?.inFlight = false
        }.resume()
    }

    private func postState(active: Bool) {
        guard let url = URL(string: baseURL + "/api/screen/state") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-screen-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["active": active])
        session.dataTask(with: req).resume()
    }
}
