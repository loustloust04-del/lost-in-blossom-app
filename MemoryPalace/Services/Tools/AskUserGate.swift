import Foundation

/// 选择卡 API 通路的「闸门」（2026-08-31，Fable）。
///
/// 骨架里的 TODO 设想是「中断本轮、整轮恢复参数打包进 PendingUserQuestion」——
/// 其实不必：ToolCallLoop.execute 本来就是 provider 循环里 await 的 async 函数，
/// 在这里挂起一个 continuation，整个循环上下文（messages/工具轮状态）原地活着，
/// 用户点完选项 resume，工具结果自然回灌。零打包、零重建。
///
/// 规则：
/// · 单卡制——已有卡挂着时再来一张直接回「未能弹出」（模型自纠），不排队
/// · 10 分钟超时 → 全题按跳过回灌，循环永不悬死
/// · resume 恰好一次（continuation 清空即失效）
@MainActor
final class AskUserGate {
    static let shared = AskUserGate()

    /// UI 侧安装（CardFlowView onAppear，与 CC 卡回调同处）：题面到了弹 sheet
    var onQuestions: (([AskUserTool.ParsedQuestion]) -> Void)?

    private var continuation: CheckedContinuation<[String?], Never>?
    private var timeoutTask: Task<Void, Never>?

    /// 工具循环调用：挂起直到用户答完/关卡/超时。
    /// 返回与 questions 下标对齐的最终答案串（nil = 跳过）；onQuestions 没人装时返回 nil。
    func ask(_ questions: [AskUserTool.ParsedQuestion]) async -> [String?]? {
        // 兔兔 0904 三报「API 卡不出」定案（0906）：ToolCallLoop.execute 不是 @MainActor，
        // 从后台线程 await 进来时，若 onQuestions 尚未安装（首轮/重挂窗口）就直接
        // 返回 nil＝「弹不出来」，模型于是嘴上说弹了、卡没出。
        // 修：等一小会儿再判——UI 回调在 CardFlowView.onAppear 装，正常瞬间就绪；
        // 真没装（App 在后台）才回落到「弹不出来」的诚实文案。
        guard continuation == nil else { return nil }
        var gate = onQuestions
        if gate == nil {
            for _ in 0..<20 {                      // 最多等 2s
                try? await Task.sleep(for: .milliseconds(100))
                if let g = onQuestions { gate = g; break }
            }
        }
        guard let onQuestions = gate else { return nil }
        onQuestions(questions)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            self?.resolve(Array(repeating: nil, count: questions.count))
        }
        return await withCheckedContinuation { self.continuation = $0 }
    }

    /// 答案出口（completeActiveAskCard / dismissActiveAskCard / 超时共用；只生效一次）
    func resolve(_ answers: [String?]) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: answers)
    }

    var isPending: Bool { continuation != nil }
}
