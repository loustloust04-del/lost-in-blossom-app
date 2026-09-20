import UIKit

/// 掉帧探针：CADisplayLink 数每一帧，超过两倍预期帧间隔算一次掉帧（hitch）。
/// 按秒攒，攒到掉帧的那一秒写一条面包屑：掉了几次、最长一帧多少 ms、离上一个动作多久。
/// 兔兔 09-12 定的规矩：「卡」要有数字，不靠感觉——粟粟当年就是靠探针把白屏钉死的。
/// 开销：每帧一个减法；只有掉帧那一秒才落盘。ProMotion 120Hz 时预期 8.3ms，60Hz 时 16.7ms。
///
/// 用法：启动时 `FrameHitchProbe.shared.start()`；关键动作处 `FrameHitchProbe.mark("发送")`。
final class FrameHitchProbe {
    static let shared = FrameHitchProbe()
    private var link: CADisplayLink?
    private var lastTs: CFTimeInterval = 0
    private var bucketStart: CFTimeInterval = 0
    private var hitches = 0
    private var worstMs: Double = 0
    private var lastMark = "启动"
    private var lastMarkAt: CFTimeInterval = 0

    static func mark(_ what: String) {
        shared.lastMark = what
        shared.lastMarkAt = CACurrentMediaTime()
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastMarkAt = CACurrentMediaTime()
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        defer { lastTs = now }
        guard lastTs > 0 else { bucketStart = now; return }
        let dt = now - lastTs
        let expected = l.targetTimestamp - l.timestamp   // 这一帧应有的间隔
        if dt > 2 {
            // 两秒以上不是掉帧，是后台/锁屏/切走了；单独记一条，不算进掉帧
            BreadcrumbLog.shared.add("⏸️", "离开了 \(Int(dt))s（后台/锁屏/切 App）")
            hitches = 0; worstMs = 0; bucketStart = now
            return
        }
        if expected > 0, dt > expected * 2 {
            hitches += 1
            worstMs = max(worstMs, dt * 1000)
        }
        if now - bucketStart >= 1 {
            // 只记值得看的那一秒：≥3 次或最长 ≥ 60ms（09-15 兔兔第一份数据：每秒 1 次 30-50ms 的
            // 小掉帧刷屏，把 📐📎🧭 都挤出面包屑）
            if hitches >= 3 || worstMs >= 60 {
                let since = Int((now - lastMarkAt) * 1000)
                BreadcrumbLog.shared.add("📉", "掉帧 \(hitches) 次，最长 \(Int(worstMs))ms，「\(lastMark)」后 \(since)ms")
            }
            hitches = 0; worstMs = 0; bucketStart = now
        }
    }
}
