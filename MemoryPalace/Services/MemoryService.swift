import Foundation
import NaturalLanguage
import SwiftData

// MARK: - Memory Store Protocol

protocol MemoryStore {
    // CRUD
    @discardableResult
    func add(content: String, category: String, keywords: [String],
             profileId: String, isUserExplicit: Bool, extractedBy: String,
             sourceConversationId: String?, sourceQuote: String?, sourceNodeId: String?,
             context: ModelContext) throws -> Memory
    func update(id: UUID, content: String, keywords: [String],
                sourceQuote: String?, sourceNodeId: String?, context: ModelContext) throws
    func delete(id: UUID, context: ModelContext) throws
    func supersede(id: UUID, context: ModelContext) throws

    // 查询
    func listHot(profileId: String, context: ModelContext) -> [Memory]
    func listHotAndWarm(profileId: String, context: ModelContext) -> [Memory]
    func listAll(profileId: String, context: ModelContext) -> [Memory]

    // 生命周期
    func recordAccess(ids: [UUID], context: ModelContext) throws
    func applyDecay(profileId: String, context: ModelContext) throws
}

// 旧签名便利重载：手动添加/编辑（MemorySettingsTab 等）不带出处，走 nil
extension MemoryStore {
    @discardableResult
    func add(content: String, category: String, keywords: [String],
             profileId: String, isUserExplicit: Bool, extractedBy: String,
             sourceConversationId: String?, context: ModelContext) throws -> Memory {
        try add(content: content, category: category, keywords: keywords,
                profileId: profileId, isUserExplicit: isUserExplicit, extractedBy: extractedBy,
                sourceConversationId: sourceConversationId, sourceQuote: nil, sourceNodeId: nil,
                context: context)
    }

    func update(id: UUID, content: String, keywords: [String], context: ModelContext) throws {
        try update(id: id, content: content, keywords: keywords,
                   sourceQuote: nil, sourceNodeId: nil, context: context)
    }
}

// MARK: - SwiftData Memory Store

struct SwiftDataMemoryStore: MemoryStore {

    @discardableResult
    func add(content: String, category: String, keywords: [String],
             profileId: String, isUserExplicit: Bool, extractedBy: String,
             sourceConversationId: String?, sourceQuote: String?, sourceNodeId: String?,
             context: ModelContext) throws -> Memory {
        let memory = Memory(
            content: content,
            category: category,
            keywords: keywords,
            profileId: profileId,
            isUserExplicit: isUserExplicit,
            extractedBy: extractedBy,
            sourceConversationId: sourceConversationId
        )
        memory.sourceQuote = sourceQuote
        memory.sourceNodeId = sourceNodeId
        context.insert(memory)
        try context.save()
        return memory
    }

    func update(id: UUID, content: String, keywords: [String],
                sourceQuote: String?, sourceNodeId: String?, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        guard let memory = try context.fetch(descriptor).first else { return }
        memory.content = content
        memory.keywords = keywords
        memory.tokenCount = Memory.estimateTokens(content)
        memory.updatedAt = Date()
        // 出处只在有新校验通过的 quote 时覆盖（nil = 保留原始出处不动）
        if let sourceQuote {
            memory.sourceQuote = sourceQuote
            memory.sourceNodeId = sourceNodeId
        }
        try context.save()
    }

    func supersede(id: UUID, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        guard let memory = try context.fetch(descriptor).first else { return }
        memory.supersededAt = Date()
        memory.updatedAt = Date()
        try context.save()
    }

    func delete(id: UUID, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        if let memory = try context.fetch(descriptor).first {
            context.delete(memory)
            try context.save()
        }
    }

    func listHot(profileId: String, context: ModelContext) -> [Memory] {
        let hotThreshold = 0.3
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in
                m.profileId == profileId && (m.isUserExplicit == true || m.decayWeight >= hotThreshold)
            },
            sortBy: [SortDescriptor(\Memory.decayWeight, order: .reverse)]
        )
        // supersededAt 内存层过滤（不进 predicate——SwiftData optional 谓词静默匹配不到）
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.supersededAt == nil }
    }

    func listHotAndWarm(profileId: String, context: ModelContext) -> [Memory] {
        let warmThreshold = 0.05
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in
                m.profileId == profileId && (m.isUserExplicit == true || m.decayWeight >= warmThreshold)
            },
            sortBy: [SortDescriptor(\Memory.decayWeight, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.supersededAt == nil }
    }

    func listAll(profileId: String, context: ModelContext) -> [Memory] {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.profileId == profileId },
            sortBy: [SortDescriptor(\Memory.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func recordAccess(ids: [UUID], context: ModelContext) throws {
        for id in ids {
            let descriptor = FetchDescriptor<Memory>(
                predicate: #Predicate<Memory> { m in m.id == id }
            )
            if let memory = try context.fetch(descriptor).first {
                DecayEngine.reinforce(memory)
            }
        }
        try context.save()
    }

    func applyDecay(profileId: String, context: ModelContext) throws {
        let all = listAll(profileId: profileId, context: context)
        DecayEngine.applyDecay(memories: all)
        try context.save()
    }
}

// MARK: - Decay Engine

enum MemoryTier: String, Hashable {
    case hot    // 自动注入
    case warm   // 可搜索，不自动注入
    case cold   // 归档
}

struct DecayEngine {
    /// 计算记忆当前有效权重（惰性计算，不写入）
    static func effectiveWeight(_ memory: Memory) -> Double {
        guard !memory.isUserExplicit else { return 1.0 }
        let days = Date().timeIntervalSince(memory.lastAccessedAt) / 86400
        return memory.decayWeight * exp(-0.1 * days)
    }

    /// 访问时强化
    static func reinforce(_ memory: Memory) {
        memory.decayWeight = min(1.0, memory.decayWeight + 0.2)
        memory.lastAccessedAt = Date()
        memory.accessCount += 1
    }

    /// 批量衰减：将 effectiveWeight 写回 decayWeight
    static func applyDecay(memories: [Memory]) {
        for memory in memories {
            guard !memory.isUserExplicit else { continue }
            memory.decayWeight = effectiveWeight(memory)
            memory.lastAccessedAt = Date()
            // 检查 validUntil
            if let until = memory.validUntil, Date() > until {
                memory.decayWeight = min(memory.decayWeight, 0.05)
            }
        }
    }

    /// 温区分类
    static func tier(_ memory: Memory) -> MemoryTier {
        let w = effectiveWeight(memory)
        if memory.isUserExplicit || w >= 0.3 { return .hot }
        if w >= 0.05 { return .warm }
        return .cold
    }
}

// MARK: - Memory Flags

enum MemoryFlags {
    /// 记忆系统总开关（设置-记忆）。关 = 不注入不提取不强化，数据不动。
    static var masterEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_master") as? Bool) ?? true
    }

    /// M8 热度衰减开关。paramecium 实测删了衰减（冷者愈冷）、kiwi 留着——用户自己选。
    static var decayEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_decay_enabled") as? Bool) ?? true
    }

    /// M8 提取人称开关。开 = 第一人称带情感（paramecium 式陪伴感）；默认第三人称客观。
    static var firstPersonExtraction: Bool {
        UserDefaults.standard.bool(forKey: "mem_extract_firstperson")
    }

    /// 上下文总结开关（设置-记忆-内容层）。默认开；受 mem_master 连坐。
    /// 关 = 不自动压缩、不注入、历史窗口不锚定（退滑动窗）；已有摘要文件保留不删。
    /// fs 工具读记忆树（memory/）跟文件库开关走，不归这里管。
    static var contextSummaryEnabled: Bool {
        masterEnabled && ((UserDefaults.standard.object(forKey: "mem_content_summary") as? Bool) ?? true)
    }

    /// SC-B2 软失效开关（已批默认开，暂不进设置页）。开 = AUDN delete 改标记 supersededAt
    /// （出排名不出库，面板可复活）；关 = 物理删除（现状行为）。钉住记忆两种模式都不动。
    static var supersedeSoftEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_supersede_soft") as? Bool) ?? true
    }
}

// MARK: - Retrieval Pipeline（M1：多检索器融合，向量/tag 的地基）

enum MemoryLayer { case stable, volatile }

struct ScoredMemory {
    let memory: Memory
    let score: Double
}

/// 一路检索：从候选记忆里挑 (记忆, 分数)，降序返回。纯函数——不碰预算、不去重，那是组装器的事。
protocol MemoryRetriever {
    var id: String { get }
    /// stable=常驻层（逐轮不变，进缓存前缀）；volatile=每轮可变（cacheFriendly 时下沉）
    var layer: MemoryLayer { get }
    /// volatile 内的优先级组：同 tier 多路时 RRF 融合，tier 间顺序拼接。兜底永远最大。
    var tier: Int { get }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory]
}

/// 常驻人格层。keyword 模式=手动/关系/偏好按 score 排序；纯全量模式=仅手动钉住、保持 fetch 序（现状）
struct PersistentRetriever: MemoryRetriever {
    let explicitOnly: Bool
    var id: String { "persistent" }
    var layer: MemoryLayer { .stable }
    var tier: Int { 0 }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        // 常驻层全员注入，排序只影响行序——必须按创建时间（永恒稳定）。
        // 按权重排的话 reinforce/衰减每轮微调分数，行序随时翻面 → system 前缀变 → 缓存无声全废（实测踩过）
        let base = explicitOnly
            ? memories.filter { $0.isUserExplicit }
            : memories.filter(MemoryInjector.isPersistent)
        return base.sorted { $0.createdAt < $1.createdAt }.map { ScoredMemory(memory: $0, score: 1) }
    }
}

/// 关键词检索层（M2 起 BM25 化，对齐 paramecium 的 jieba BM25）：
/// NLTokenizer 分词建词袋，标准 BM25 打分。命中语义不变（分>0 = 提到才注），排序更聪明（稀有词 > 烂大街词）。
struct KeywordRetriever: MemoryRetriever {
    var id: String { "keyword" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 1 }

    private let k1 = 1.2
    private let b = 0.75

    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let candidates = memories.filter { !MemoryInjector.isPersistent($0) }
        guard !candidates.isEmpty else { return [] }
        let queryTerms = Set(MemoryInjector.contentKeys(recent.joined(separator: "\n")).map { $0.lowercased() })
        guard !queryTerms.isEmpty else { return [] }

        // 词袋：content 分词 + 预存 keywords（提取时挑的词更可信，权重 ×2 计入词频）
        let docs: [[String]] = candidates.map { m in
            let terms = MemoryInjector.contentKeys(m.content).map { $0.lowercased() }
            let keys = m.keywords.map { $0.lowercased() }
            return terms + keys + keys
        }

        let n = Double(docs.count)
        var df: [String: Int] = [:]
        for doc in docs { for t in Set(doc) { df[t, default: 0] += 1 } }
        let avgLen = max(1.0, Double(docs.reduce(0) { $0 + $1.count }) / n)

        var scored: [ScoredMemory] = []
        for (i, m) in candidates.enumerated() {
            var tf: [String: Int] = [:]
            for t in docs[i] { tf[t, default: 0] += 1 }
            var score = 0.0
            for t in queryTerms {
                guard let f = tf[t], let d = df[t] else { continue }
                let idf = log(1 + (n - Double(d) + 0.5) / (Double(d) + 0.5))
                let freq = Double(f)
                score += idf * (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * Double(docs[i].count) / avgLen))
            }
            if score > 0 { scored.append(ScoredMemory(memory: m, score: score)) }
        }
        return scored.sorted { $0.score > $1.score }
    }
}

/// 向量语义检索层（M2）：query=最近对话尾部句向量，对候选逐条余弦，阈值+topK。
/// 模型资产未就绪 → 静默返回空并触发下载（绝不打断聊天）。
struct VectorRetriever: MemoryRetriever {
    var id: String { "vector" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 1 }

    /// 实测校准（2026-06-11）：Apple 模型分数尺度偏低——"甜品店橱窗"vs"喜欢蛋糕"只给 0.40。
    /// 0.5 抓不到真相关；0.35 起步，等无关对照组的基线数据再精调
    static let similarityThreshold: Float = 0.35
    static let topK = 20

    /// 最近一次检索的内幕（诊断日志用：抓空时知道断在哪环、差多少）
    static var lastDetail = ""

    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let embedder = AppleMemoryEmbedder.shared
        guard embedder.isReady else {
            embedder.requestAssetsIfNeeded()
            Self.lastDetail = "模型:\(embedder.assetState.rawValue)"
            return []
        }
        let queryText = String(recent.suffix(4).joined(separator: "\n").suffix(300))
        guard let query = embedder.embed(queryText) else {
            Self.lastDetail = "query embed 失败"
            return []
        }
        let rev = embedder.revision

        let candidates = memories.filter { !MemoryInjector.isPersistent($0) }
        var maxSim: Float = -1
        let scored: [ScoredMemory] = candidates
            .compactMap { m in
                guard m.embeddingRevision == rev, let data = m.embeddingData else { return nil }
                let sim = MemoryVector.dot(query, MemoryVector.floats(from: data))
                maxSim = max(maxSim, sim)
                guard sim >= Self.similarityThreshold else { return nil }
                return ScoredMemory(memory: m, score: Double(sim))
            }
            .sorted { $0.score > $1.score }
        let withVec = candidates.filter { $0.embeddingData != nil }.count
        Self.lastDetail = "候选\(candidates.count)·带向量\(withVec)·最高相似\(maxSim < 0 ? "无" : String(format: "%.2f", maxSim))·阈值\(String(format: "%.2f", Self.similarityThreshold))"
        return Array(scored.prefix(Self.topK))
    }
}

/// 全量兜底：按衰减权重排序填满剩余预算。excludePersistent 区分两种模式的候选集（现状语义）
struct FullFallbackRetriever: MemoryRetriever {
    let excludePersistent: Bool   // true=keyword 模式（排除常驻层）；false=纯全量（排除手动钉住）
    var id: String { "fullFallback" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 99 }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let candidates = excludePersistent
            ? memories.filter { !MemoryInjector.isPersistent($0) }
            : memories.filter { !$0.isUserExplicit }
        return candidates
            .sorted { MemoryInjector.score($0) > MemoryInjector.score($1) }
            .map { ScoredMemory(memory: $0, score: MemoryInjector.score($0)) }
    }
}

// MARK: - Memory Injector

struct MemoryInjector {
    static let tokenBudget = 2000

    /// 分类标签中文映射
    private static let categoryLabels: [String: String] = [
        "preference": "偏好",
        "fact": "事实",
        "relationship": "关系",
        "goal": "目标",
        "context": "情境",
    ]

    /// 从 hot 记忆中选择注入内容，按权重排序，不超过 token 预算
    static func buildInjection(memories: [Memory], budget: Int = tokenBudget) -> String {
        guard !memories.isEmpty else { return "" }

        // 分离：用户手动的始终注入，自动的按权重排序
        let explicit = memories.filter { $0.isUserExplicit }
        let auto = memories.filter { !$0.isUserExplicit }
            .sorted { score($0) > score($1) }

        var lines: [String] = []
        var usedTokens = 0

        // 用户手动的始终注入
        for m in explicit {
            let label = categoryLabels[m.category] ?? m.category
            lines.append("- \(m.content) [\(label)]")
            usedTokens += m.tokenCount
        }

        // 自动的按预算注入
        for m in auto {
            if usedTokens + m.tokenCount > budget { break }
            let label = categoryLabels[m.category] ?? m.category
            lines.append("- \(m.content) [\(label)]")
            usedTokens += m.tokenCount
        }

        return lines.joined(separator: "\n")
    }

    /// 拼接到 system prompt
    static func inject(systemPrompt: String?, memories: [Memory]) -> String? {
        let injection = buildInjection(memories: memories)
        let base = systemPrompt ?? ""

        guard !injection.isEmpty else {
            return base.isEmpty ? nil : base
        }

        let block = "[关于用户]\n\(injection)"

        if base.isEmpty {
            return block
        }
        return "\(base)\n\n\(block)"
    }

    /// 打分：decayWeight × log(1 + accessCount)
    static func rrfFuse(_ lists: [[ScoredMemory]]) -> [Memory] {
        var scores: [UUID: Double] = [:]
        var lookup: [UUID: Memory] = [:]
        var firstSeen: [UUID: Int] = [:]
        var counter = 0
        for list in lists {
            for (rank, s) in list.enumerated() {
                scores[s.memory.id, default: 0] += 1.0 / Double(60 + rank + 1)
                if lookup[s.memory.id] == nil {
                    lookup[s.memory.id] = s.memory
                    firstSeen[s.memory.id] = counter
                    counter += 1
                }
            }
        }
        return scores.sorted { a, b in
            a.value != b.value ? a.value > b.value : (firstSeen[a.key] ?? 0) < (firstSeen[b.key] ?? 0)
        }.compactMap { lookup[$0.key] }
    }

    fileprivate static func isPersistent(_ m: Memory) -> Bool {
        m.isUserExplicit || m.category == "relationship" || m.category == "preference"
    }

    fileprivate static func contentKeys(_ content: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = content
        var words: [String] = []
        tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
            let w = String(content[range])
            if w.count >= 2 { words.append(w) }
            return true
        }
        return words
    }

    fileprivate static func score(_ memory: Memory) -> Double {
        DecayEngine.effectiveWeight(memory) * log(1.0 + Double(memory.accessCount))
    }
}

// MARK: - Memory Extractor (AUDN)

enum MemoryAction {
    case add(content: String, category: String, keywords: [String], quote: String?)
    case update(id: UUID, content: String, keywords: [String], quote: String?)
    case delete(id: UUID)
}

struct MemoryExtractor {
    static let extractionPrompt = """
你是记忆管理助手。分析最近的对话，决定是否需要更新用户的记忆库。

## 当前记忆
{{MEMORIES}}

## 规则
1. 提取原子事实 — 每条记忆是一个独立的陈述（"喜欢暖色调"而不是"有各种审美偏好"）
2. 分类：preference（偏好）、fact（事实）、relationship（人际关系）、goal（目标/项目）、context（当前情境，有时效性）
3. 对每条新信息做出一个判断：
   - add: 全新信息，现有记忆未覆盖
   - update: 已有记忆需要修正或补充 — 提供要更新的记忆 ID
   - delete: 已有记忆被明确否定或过时 — 提供要删除的记忆 ID
   - 不操作: 已充分覆盖，或不值得存储
4. 只存用户明确说出或强烈暗示的信息。不要推断敏感信息。
5. 用简洁的第三人称：「用户喜欢...」而不是「你喜欢...」
6. 需要时加时间限定词：「用户目前在做...」
7. 新旧矛盾时，delete 旧记忆 + add 新版本。
8. 不存：日常闲聊、一次性问题、用户在问（而非陈述）的信息。
9. 不存系统状态：报错/重试/网络/工具失败等技术噪音不是用户的事实。安抚性客套话（如随口的"多喝热水"）不是正式决策或偏好。
10. 对话内容明显是在编辑文件库文件（讨论 fs_ 操作/文件内容本身）时，输出空 actions。

## 输出格式
只输出 JSON，不要解释：
{"actions": [{"type": "add", "content": "记忆内容", "category": "分类", "keywords": ["关键词"]}, {"type": "update", "id": "记忆ID", "content": "新内容", "keywords": ["关键词"]}, {"type": "delete", "id": "记忆ID"}]}
如果没有需要操作的，输出：{"actions": []}
"""

    /// 构建提取请求（优先用用户自定义提示词）
    static func buildPrompt(existingMemories: [Memory]) -> String {
        var memoriesJSON = "无"
        if !existingMemories.isEmpty {
            let items = existingMemories.map { m in
                "  {\"id\": \"\(m.id.uuidString)\", \"content\": \"\(m.content)\", \"category\": \"\(m.category)\"}"
            }
            memoriesJSON = "[\n\(items.joined(separator: ",\n"))\n]"
        }

        let customPrompt = UserDefaults.standard.string(forKey: "customMemoryExtractionPrompt") ?? ""
        let defaultTemplate = MemoryFlags.firstPersonExtraction ? firstPersonExtractionPrompt : extractionPrompt
        let template = customPrompt.isEmpty ? defaultTemplate : customPrompt
        // 固定拼接（不进可编辑模板）：custom prompt 用户也生效，否则自定义模板没写 quote 规则会被机械校验全扔
        return template.replacingOccurrences(of: "{{MEMORIES}}", with: memoriesJSON) + quoteRuleAppendix
    }

    /// 出处规则附加段（刀2）：要求逐字 quote，机械校验配套
    static let quoteRuleAppendix = """


## 出处要求（程序会机械校验，不满足将被丢弃）
每条 add 必须带 "quote" 字段：从对话原文【逐字】复制的 10-40 字片段，作为该记忆的出处证据。不许改写、不许拼接多句。找不到逐字出处的信息不要 add。
update 可选带 "quote"，同样要求逐字。
示例：{"type": "add", "content": "...", "category": "...", "keywords": [...], "quote": "对话里逐字出现的原文片段"}
"""

    // MARK: - 机械校验（paramecium extract-memories.mjs:199-218 同款，纯函数可测）

    /// 刀2 风险对冲常量：true = 无有效 quote 的 add 整条扔（宁缺勿滥）；
    /// 日用拦截率离谱时改 false 降级为"无锚存入"
    static let quoteRequiredForAdd = true

    /// norm：去全部空白（hard cap slice 不信 prompt）
    static func normalizeForQuote(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    /// quote 有效 = norm 后 ≥8 字 且 逐字出现在窗口文本里
    static func validateQuote(_ quote: String?, windowText: String) -> Bool {
        guard let quote else { return false }
        let nq = normalizeForQuote(quote)
        guard nq.count >= 8 else { return false }
        return normalizeForQuote(windowText).contains(nq)
    }

    /// 定位 quote 所在消息：窗口内第一条 norm(content) 包含 norm(quote) 的消息 id
    static func locateQuote(_ quote: String, in messages: [(id: String, role: String, content: String)]) -> String? {
        let nq = normalizeForQuote(quote)
        return messages.first { normalizeForQuote($0.content).contains(nq) }?.id
    }

    // MARK: - 写时近似去重（paramecium sim>0.75 同款，2026-06-13）

    /// 近似重复 = 同一事实再确认 → 强化旧条不开新条（全等去重挡不住"喜欢暖奶白"vs"偏好暖奶白色调"）
    static let dedupSimilarityThreshold: Float = 0.75

    /// 纯比对层（可测）：在候选里找与新向量相似度超阈的最相近条。
    /// 排除已失效条——否则"delete旧+add新"的矛盾更新会被去重打穿（新事实被旧版本吸收）。
    static func findNearDuplicate(vector newVec: [Float], revision: Int, in existing: [Memory]) -> Memory? {
        var best: (memory: Memory, sim: Float)? = nil
        for m in existing {
            guard m.supersededAt == nil,
                  let data = m.embeddingData, m.embeddingRevision == revision else { continue }
            let sim = MemoryVector.dot(newVec, MemoryVector.floats(from: data))
            if sim > dedupSimilarityThreshold, sim > (best?.sim ?? 0) { best = (m, sim) }
        }
        return best?.memory
    }

    /// embed 外壳：模型未就绪/无向量 → nil = 跳过去重（app 自包含，向量路静默退场）
    static func findNearDuplicate(of content: String, in existing: [Memory]) -> Memory? {
        guard let newVec = AppleMemoryEmbedder.shared.embed(content) else { return nil }
        return findNearDuplicate(vector: newVec, revision: AppleMemoryEmbedder.shared.revision, in: existing)
    }

    /// 构建发给 LLM 的 system prompt 和 messages（窗口带 node id，定位 quote 出处用；id 不进 prompt）
    static func buildRequest(
        recentMessages: [(id: String, role: String, content: String)],
        existingMemories: [Memory]
    ) -> (systemPrompt: String, messages: [(role: String, content: String)]) {
        let prompt = buildPrompt(existingMemories: existingMemories)

        // 把最近对话格式化为用户消息
        var conversationText = ""
        for msg in recentMessages {
            let label = msg.role == "user" ? "用户" : "AI"
            conversationText += "\(label): \(msg.content)\n\n"
        }

        let messages = [(role: "user", content: "以下是最近的对话，请分析并执行记忆操作：\n\n\(conversationText)")]
        return (systemPrompt: prompt, messages: messages)
    }

    /// 解析 LLM 返回的 JSON 为操作列表
    static func parseActions(_ jsonString: String) -> [MemoryAction] {
        // 尝试直接解析
        if let actions = parseJSON(jsonString) { return actions }

        // Fallback: 从文本中提取 JSON 块
        if let range = jsonString.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
           let actions = parseJSON(String(jsonString[range])) {
            return actions
        }

        return []
    }

    private static func parseJSON(_ json: String) -> [MemoryAction]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = obj["actions"] as? [[String: Any]] else {
            return nil
        }

        var result: [MemoryAction] = []

        for action in actions {
            guard let type = action["type"] as? String else { continue }

            switch type {
            case "add":
                guard let content = action["content"] as? String,
                      let category = action["category"] as? String else { continue }
                let keywords = action["keywords"] as? [String] ?? []
                let quote = action["quote"] as? String
                result.append(.add(content: content, category: category, keywords: keywords, quote: quote))

            case "update":
                guard let idStr = action["id"] as? String,
                      let id = UUID(uuidString: idStr),
                      let content = action["content"] as? String else { continue }
                let keywords = action["keywords"] as? [String] ?? []
                let quote = action["quote"] as? String
                result.append(.update(id: id, content: content, keywords: keywords, quote: quote))

            case "delete":
                guard let idStr = action["id"] as? String,
                      let id = UUID(uuidString: idStr) else { continue }
                result.append(.delete(id: id))

            default:
                break
            }
        }

        return result.isEmpty ? nil : result
    }

    /// 执行操作列表
    static func executeActions(
        _ actions: [MemoryAction],
        store: MemoryStore,
        profileId: String,
        extractedBy: String,
        sourceConversationId: String?,
        recentMessages: [(id: String, role: String, content: String)],
        context: ModelContext
    ) throws {
        // 提取去重：模型偶尔会对已有记忆再次输出 add（实测"焦糖布丁"注入两遍）
        let existing = store.listAll(profileId: profileId, context: context)
        let existingContents = Set(existing.map(\.content))
        let windowText = recentMessages.map(\.content).joined(separator: "\n")

        // delete 先行：模型的矛盾更新是 delete旧+add新 两动作，若 add 先跑、
        // 还活着的旧版本会把新事实近似去重吸收掉 → 随后 delete 失效旧条 = 新事实丢失
        let isDelete: (MemoryAction) -> Bool = { if case .delete = $0 { return true } else { return false } }
        let ordered = actions.filter(isDelete) + actions.filter { !isDelete($0) }

        for action in ordered {
            switch action {
            case .add(let content, let category, let keywords, let quote):
                if existingContents.contains(content) { continue }
                let validQuote = validateQuote(quote, windowText: windowText) ? quote : nil
                if validQuote == nil {
                    CacheDiagLog.shared.log("🧠 quote 校验拦截 add：\(content.prefix(40))（quote=\(quote?.prefix(40) ?? "缺失")）")
                    if quoteRequiredForAdd { continue }
                }
                let nodeId = validQuote.flatMap { locateQuote($0, in: recentMessages) }
                // 写时近似去重：超阈 → 强化旧条（reinforce）不开新条；旧条无锚时顺手补 quote
                if let dup = findNearDuplicate(of: content, in: existing) {
                    CacheDiagLog.shared.log("🧠 写时去重：「\(content.prefix(24))」≈「\(dup.content.prefix(24))」→ 强化旧条")
                    try store.recordAccess(ids: [dup.id], context: context)
                    if dup.sourceQuote == nil, let validQuote {
                        dup.sourceQuote = validQuote
                        dup.sourceNodeId = nodeId
                        context.saveOrReport("记忆")
                    }
                    continue
                }
                try store.add(
                    content: content,
                    category: category,
                    keywords: keywords,
                    profileId: profileId,
                    isUserExplicit: false,
                    extractedBy: extractedBy,
                    sourceConversationId: sourceConversationId,
                    sourceQuote: validQuote,
                    sourceNodeId: nodeId,
                    context: context
                )

            case .update(let id, let content, let keywords, let quote):
                // update 不强制 quote（更新常是改写）；给了且校验过才更新出处
                let validQuote = validateQuote(quote, windowText: windowText) ? quote : nil
                let nodeId = validQuote.flatMap { locateQuote($0, in: recentMessages) }
                try store.update(id: id, content: content, keywords: keywords,
                                 sourceQuote: validQuote, sourceNodeId: nodeId, context: context)

            case .delete(let id):
                // 钉住记忆神圣不可侵犯（软硬两种模式都不动）
                if let target = existing.first(where: { $0.id == id }), target.isUserExplicit {
                    CacheDiagLog.shared.log("🧠 拒绝失效钉住记忆：\(target.content.prefix(40))")
                    continue
                }
                if MemoryFlags.supersedeSoftEnabled {
                    try store.supersede(id: id, context: context)
                } else {
                    try store.delete(id: id, context: context)
                }
            }
        }
    }
}

// MARK: - View 层便捷操作（View 已持有托管对象时免按 id 重查；解耦方向四）

extension SwiftDataMemoryStore {
    /// 钉住/取消钉住。touchUpdatedAt：记忆面板要刷新时间戳，设置页保持原值。
    func togglePin(_ memory: Memory, touchUpdatedAt: Bool, context: ModelContext) {
        memory.isUserExplicit.toggle()
        if memory.isUserExplicit { memory.decayWeight = 1.0 }
        if touchUpdatedAt { memory.updatedAt = Date() }
        context.saveOrReport("记忆")
    }

    /// 按对象删除
    func delete(_ memory: Memory, context: ModelContext) {
        context.delete(memory)
        context.saveOrReport("记忆")
    }

    /// 复活已 supersede 的记忆（清 supersededAt + 刷新时间戳）
    func revive(_ memory: Memory, context: ModelContext) {
        memory.supersededAt = nil
        memory.updatedAt = Date()
        context.saveOrReport("记忆")
    }

    /// 用户手动新增（钉住语义：isUserExplicit + decayWeight 1.0）
    @discardableResult
    func addUserPinned(content: String, category: String, keywords: [String],
                       profileId: String, context: ModelContext) -> Memory {
        let memory = Memory(
            content: content,
            category: category,
            keywords: keywords,
            profileId: profileId,
            isUserExplicit: true
        )
        memory.decayWeight = 1.0
        context.insert(memory)
        context.saveOrReport("记忆")
        return memory
    }
}
