import UIKit

/// 深翻定速连滚基准（对照粟粟 ChatPerfBench / lody ChatPerformanceProbe 的口径）。
/// 不靠手划：CADisplayLink 以固定速度把聊天列表往「更早」方向滚 duration 秒，
/// 采 main run-loop 帧间隔（fps / p50 / p95 / 掉帧数 / 最长一帧）+ 内存 footprint 前后差，
/// 结果写一条面包屑 📊，并落盘 Documents/perf-bench.json（附全部帧间隔）。
/// 每刀前后各跑一次，好坏用数字说。反转列表：offset 越大越老，所以是正向加。
final class ChatScrollBench: NSObject {
    static let shared = ChatScrollBench()
    static let startNotification = Notification.Name("ChatScrollBench.start")

    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastTs: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var baseline: Double = 0
    private var speed: Double = 3000     // pt/s，≈真人快速 fling 的衰减段；粟粟对齐 lody 用 8000
    private var duration: Double = 20
    private(set) var isRunning = false

    func start(on sv: UIScrollView, speed: Double = 3000, duration: Double = 20) {
        guard !isRunning else { return }
        scrollView = sv
        self.speed = speed
        self.duration = duration
        intervals.removeAll(keepingCapacity: true)
        baseline = Self.footprintMB()
        isRunning = true
        startedAt = 0
        lastTs = 0
        BreadcrumbLog.shared.add("📊", "深翻基准开始：\(Int(speed))pt/s × \(Int(duration))s，内存 \(Int(baseline))MB")
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let sv = scrollView else { stop(reason: "列表没了"); return }
        let now = l.timestamp
        if startedAt == 0 { startedAt = now; lastTs = now; return }
        let dt = now - lastTs
        lastTs = now
        intervals.append(dt)
        let maxY = max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let y = min(maxY, sv.contentOffset.y + CGFloat(speed * dt))
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
        if now - startedAt >= duration { stop(reason: "到时"); return }
        if y >= maxY - 1, sv.contentSize.height > 0 { stop(reason: "到头") }
    }

    private func stop(reason: String) {
        link?.invalidate(); link = nil
        isRunning = false
        guard !intervals.isEmpty else { return }
        let sorted = intervals.sorted()
        let total = intervals.reduce(0, +)
        let fps = Double(intervals.count) / total
        let p50 = sorted[sorted.count / 2] * 1000
        let p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
        let worst = (sorted.last ?? 0) * 1000
        let hitches = intervals.filter { $0 > 1.0 / 60 * 2 }.count   // 超过两帧（60Hz 口径）算一次
        let mem = Self.footprintMB()
        let summary = "深翻 \(Int(total))s@\(Int(speed))pt/s（\(reason)）：均 \(String(format: "%.1f", fps))fps · p50 \(Int(p50))ms · p95 \(Int(p95))ms · 掉帧 \(hitches) 次 · 最长 \(Int(worst))ms · 内存 \(Int(baseline))→\(Int(mem))MB（+\(Int(mem - baseline))）"
        BreadcrumbLog.shared.add("📊", summary)
        // 落盘：帧间隔全量，给以后画图/对比
        let payload: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "speed": speed, "duration": total, "reason": reason,
            "fps": fps, "p50_ms": p50, "p95_ms": p95, "worst_ms": worst, "hitches": hitches,
            "mem_before_mb": baseline, "mem_after_mb": mem,
            "intervals_ms": intervals.map { $0 * 1000 },
        ]
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("perf-bench.json"))
        }
    }

    /// 物理内存 footprint（MB）——TASK_VM_INFO.phys_footprint，和 Xcode 内存表一个口径
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
