import Foundation

// MARK: - Context Summary Model

struct ContextSummary: Codable {
    let summary: String
    let coveredCount: Int      // 摘要覆盖的旧消息条数
    let updatedAt: Date
}

// MARK: - Context Summarizer

struct ContextSummarizer {

    // MARK: - 存取

    private static func storageKey(_ conversationId: String) -> String {
        "ctxSummary_\(conversationId)"
    }

    static func load(conversationId: String) -> ContextSummary? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(conversationId)) else { return nil }
        return try? JSONDecoder().decode(ContextSummary.self, from: data)
    }

    static func save(_ summary: ContextSummary, conversationId: String) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(conversationId))
    }

    static func clear(conversationId: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(conversationId))
    }

    // MARK: - 压缩游标（prompt caching 窗口锚点）

    // MARK: - 滞回裁剪（Hysteresis）
    //
    // 水位制：窗口放任生长，涨到 highWater 触发，一刀裁回 lowWater，
    // 然后再放任生长。lowWater 到 highWater 之间什么都不做。
    // 这个"什么都不做"让窗口边界在两次裁剪之间（约 lowWater/2 轮）纹丝不动，
    // 缓存断点挂在历史末尾，每轮只把上一轮对话焊进缓存，历史部分白吃。
    //
    // 旧方案（compressionChunk=20 的分块游标）每 20 条推进一次，推进时缓存全毁。
    // 滞回方案让裁剪间隔拉到 30 条（约 15 轮），中间缓存全命中。
    
    static let highWater = 60   // 涨到这个数触发裁剪
    static let lowWater  = 30   // 裁回这个数

    /// 窗口锚点 = 已折叠进摘要的旧消息条数。buildAPIMessages 从这里开始取窗口，
    /// 只在压缩游标推进时跳变（每 chunk 轮一次），其余时间历史前缀纹丝不动。
    static func windowStart(conversationId: String) -> Int {
        load(conversationId: conversationId)?.coveredCount ?? 0
    }

    /// 滞回游标：消息数涨到 highWater 才裁剪，裁回 lowWater。
    /// 中间不动 → 缓存前缀稳定 → 白吃缓存。
    static func desiredCursor(totalCount: Int, contextDepth: Int) -> Int {
        // 读已有摘要的游标作为当前水位
        // 注意：这个函数是纯算，不读存储；调用方传 existingCursor 进来
        let overflow = totalCount - contextDepth
        guard overflow > 0 else { return 0 }
        // 向下取整到 lowWater 的倍数（兼容旧逻辑）
        return (overflow / lowWater) * lowWater
    }
    
    /// 滞回判断：当前消息数是否触发裁剪？
    static func shouldTrigger(totalCount: Int, existingCoveredCount: Int) -> Bool {
        let windowSize = totalCount - existingCoveredCount
        return windowSize >= highWater
    }
    
    /// 裁剪目标：保留 lowWater 条在窗口里，其余全部折叠进摘要
    static func trimTarget(totalCount: Int) -> Int {
        return max(0, totalCount - lowWater)
    }

    // MARK: - 判断是否需要总结

    /// 滞回裁剪：窗口涨到 highWater 才触发，一刀裁回 lowWater。
    /// 中间什么都不做 → 窗口边界稳定 → 缓存白吃。
    static func messagesToSummarize(
        allMessages: [(role: String, content: String)],
        contextDepth: Int,
        conversationId: String
    ) -> (oldMessages: [(role: String, content: String)], existingSummary: ContextSummary?)? {
        let totalCount = allMessages.count
        let existing = load(conversationId: conversationId)
        let currentCovered = existing?.coveredCount ?? 0
        let windowSize = totalCount - currentCovered
        
        // 滞回核心：窗口没涨到 highWater → 什么都不做
        guard windowSize >= highWater else { return nil }
        
        // 触发裁剪：保留 lowWater 条，其余全部折叠
        let trimTo = totalCount - lowWater
        guard trimTo > currentCovered else { return nil }
        
        let oldMessages = Array(allMessages.prefix(trimTo))
        return (oldMessages: oldMessages, existingSummary: existing)
    }

    // MARK: - 构建总结请求

    /// 默认对话压缩 prompt。设置页可载入编辑；UserDefaults contextSummaryPrompt 为空时运行时用它。
    /// 滞回摘要 prompt — 覆盖式、第一人称回忆体、近清远糊
    /// 教训：① DeepSeek 会编故事，必须用 Sonnet ② prompt 要三明治（头尾各给一次指令）
    /// ③ 喂人格让书记员知道什么重要 ④ 禁止"今天/昨天"，全落绝对日期
    static let defaultSummaryPrompt = """
        你是这段对话的书记员。把被裁掉的旧对话和已有摘要合并成一份新的前情提要。
        这份前情提要会被注入到后续对话的 system prompt 中，是AI唯一能看到的关于过去的记忆。
        
        写法：
        - 覆盖式：旧摘要和新对话原文一起重写成一份完整的新摘要，不是追加
        - 近清远糊：最近发生的事情写得清晰具体，更早的事情压缩模糊——像人类记忆一样
        - 第一人称回忆体：用"我们聊了……""她说……""我回答了……"，不用"用户与助手进行了交流"
        - 保留的优先级：情绪转折 > 关键决策 > 具体事实 > 闲聊内容
        - 保留原话：如果某句话很重要（承诺、暗号、让对方感动的话），保留原文加引号
        - 绝对日期：禁止写"今天""昨天""刚才"（写下的"今天"在未来被读到就是假记忆），全部用绝对日期
        - 不记录系统故障、重试、报错等技术噪音
        - 控制在 2000 字以内。直接输出，不加标题、不加代码块
        - 人称：对话中的 user 称「用户」或其名字，assistant 称「AI」或其角色名
        """

    static func buildSummaryRequest(
        oldMessages: [(role: String, content: String)],
        existingSummary: ContextSummary?
    ) -> (systemPrompt: String, messages: [(role: String, content: String)]) {
        // 设置页可覆盖压缩 prompt（contextSummaryPrompt 非空时优先用）
        let customSummaryPrompt: String? = {
            let v = UserDefaults.standard.string(forKey: "contextSummaryPrompt")
            return (v?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? v : nil
        }()

        // 累计记忆式压缩（2026-06-11 参考粟粟的酒馆 memory_rule 升级：覆盖式更新 + 字段结构 + 以"能续写"为目标）
        let systemPrompt = Self.defaultSummaryPrompt


        if let existing = existingSummary {
            // 增量更新：旧摘要 + 新增消息
            let newStartIndex = existing.coveredCount
            let newMessages = newStartIndex < oldMessages.count
                ? Array(oldMessages.suffix(from: newStartIndex))
                : oldMessages

            let systemPrompt = customSummaryPrompt ?? Self.defaultSummaryPrompt

            let userContent = """
            【已有摘要】
            \(existing.summary)

            【被裁掉的新对话原文】
            \(formatMessages(newMessages))

            三明治提醒（重要！）：现在请把上面的已有摘要和新对话合并成一份新的前情提要。近的事清晰，远的事模糊。覆盖式重写，不是追加。控制在 2000 字以内。
            """

            return (systemPrompt: customSummaryPrompt ?? systemPrompt, messages: [(role: "user", content: userContent)])
        } else {
            // 首次总结
            let systemPrompt = customSummaryPrompt ?? Self.defaultSummaryPrompt

            let userContent = formatMessages(oldMessages)
            return (systemPrompt: customSummaryPrompt ?? systemPrompt, messages: [(role: "user", content: userContent)])
        }
    }

    // MARK: - 执行总结

    /// fire-and-forget：判断 → 构建请求 → 调 API → 存结果
    static func summarize(
        allMessages: [(role: String, content: String)],
        contextDepth: Int,
        conversationId: String,
        model: ProviderModel,
        providerManager: ProviderManager
    ) async throws {
        guard let needed = messagesToSummarize(
            allMessages: allMessages,
            contextDepth: contextDepth,
            conversationId: conversationId
        ) else {
            #if DEBUG
            print("📝 上下文总结: 不需要（消息数未超 contextDepth 或摘要已是最新）")
            #endif
            return
        }

        #if DEBUG
        print("📝 上下文总结: 触发（旧消息 \(needed.oldMessages.count) 条，已有摘要覆盖 \(needed.existingSummary?.coveredCount ?? 0) 条）")
        #endif

        let request = buildSummaryRequest(
            oldMessages: needed.oldMessages,
            existingSummary: needed.existingSummary
        )

        // 预算保险闸：backend agent 过 gate，避免总结烧 key
        if let provider = providerManager.provider(for: model) {
            var accumulated = request.systemPrompt
            for m in request.messages { accumulated += "\n" + m.content }
            let inputTok = HeuristicEstimator().estimate(accumulated)
            let estimated = BudgetCalculator.actualCost(
                provider: provider,
                modelId: model.modelId,
                usage: TokenUsage(inputTokens: inputTok, outputTokens: 1024)
            )
            let gate = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated)
            if case .blocked = gate {
                #if DEBUG
                print("📝 上下文总结: 跳过（预算已用完 / 未拨款）")
                #endif
                return
            }
        }

        let router = ProviderRouter()
        let (response, usage) = try await router.sendNonStreaming(
            model: model,
            messages: request.messages,
            systemPrompt: request.systemPrompt,
            providerManager: providerManager
        )

        // Post-commit 扣费
        if let usage, let provider = providerManager.provider(for: model) {
            let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
            await MainActor.run {
                providerManager.commitSpend(providerId: provider.id, amount: cost)
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            #if DEBUG
            print("📝 上下文总结: ⚠️ 模型返回空内容")
            #endif
            return
        }

        let summary = ContextSummary(
            summary: trimmed,
            coveredCount: needed.oldMessages.count,
            updatedAt: Date()
        )
        save(summary, conversationId: conversationId)

        #if DEBUG
        print("📝 上下文总结: ✅ 已保存（覆盖 \(summary.coveredCount) 条，摘要 \(trimmed.count) 字）")
        #endif
    }

    // MARK: - Private

    private static func formatMessages(_ messages: [(role: String, content: String)]) -> String {
        messages.map { msg in
            let label = msg.role == "user" ? "用户" : "AI"
            return "\(label): \(msg.content)"
        }.joined(separator: "\n\n")
    }
}
