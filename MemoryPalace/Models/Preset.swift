import Foundation

// MARK: - Prompt Slot

struct PromptSlot: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var role: String = "system"           // "system" | "user" | "assistant"
    var content: String = ""
    var isSystemPrompt: Bool = true       // true=骨架（必开），false=可选开关
    var isEnabled: Bool = true
    var isMarker: Bool = false            // 占位符（由角色卡/记忆/对话填充）
    var injectionDepth: Int = 0           // 0=按顺序，>0=从对话末尾数第 N 层插入
    var injectionOrder: Int = 100         // 排序优先级
    var forbidOverrides: Bool = false     // 角色卡能否覆盖

    // Well-known marker identifiers
    static let mainId = "main"
    static let personaDescriptionId = "personaDescription"
    static let charDescriptionId = "charDescription"
    static let charPersonalityId = "charPersonality"
    static let scenarioId = "scenario"
    static let dialogueExamplesId = "dialogueExamples"
    static let memoryInjectionId = "memoryInjection"
    static let chatHistoryId = "chatHistory"
    static let jailbreakId = "jailbreak"
}

// MARK: - Sampling Parameters

struct SamplingParams: Codable, Hashable {
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var topK: Int = 0                     // 0=不发
    var maxTokens: Int = 4096
    var frequencyPenalty: Double = 0
    var presencePenalty: Double = 0
    var contextDepth: Int = 40            // 对话历史条数
    // 新增参数
    var maxContextSize: Int = 100000      // 上下文窗口上限
    var seed: Int = -1                    // -1=随机
    var reasoningEffort: String = "auto"  // "low"/"medium"/"high"/"auto"
    var verbosity: String = "auto"        // "auto"/"concise"/"verbose"
    var streaming: Bool = true
    var squashSystemMessages: Bool = false // 合并连续 system 消息
    var postProcessingMode: String = "none" // "none" | "merge" | "strict"
    var continuePrefill: Bool = false     // 续写时用 assistant prefill
    var continuePostfix: String = " "
    /// Anthropic mcp_servers beta 是否启用. true = 注入 provider 的 mcpServers（默认开启）.
    var mcpEnabled: Bool = true
    /// 缓存命中优化：易变内容（记忆/世界书命中 + 日期时间健康）下沉成伪 user 消息，
    /// system 只留稳定前缀；OpenRouter+Claude 额外 per-block 挂 cache_control 并钉上游。默认关。
    var cacheFriendly: Bool = false
}

// MARK: - Preset

struct Preset: Identifiable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var description: String = ""
    var isBuiltIn: Bool = false           // 内置预设不可删除
    var sampling: SamplingParams = SamplingParams()
    var prompts: [PromptSlot] = []

    // 格式模板（角色卡数据填入 marker 前的包装格式）
    var characterFormat: String = "[角色设定]\n{{description}}\n{{personality}}"
    var scenarioFormat: String = "[当前场景]\n{{scenario}}"
    var personaFormat: String = "[用户信息]\n{{persona}}"
    var regexScripts: [RegexScript] = []     // 预设绑定的正则脚本
}

// MARK: - Built-in Presets

extension Preset {
    /// 默认插槽骨架（三个预设共用）
    private static var defaultSlots: [PromptSlot] {
        [
            PromptSlot(id: PromptSlot.mainId, name: "⭐ 系统指令", role: "system",
                       isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.personaDescriptionId, name: "🧑 用户描述", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 10),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "📝 助手设定", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            PromptSlot(id: PromptSlot.scenarioId, name: "📖 背景设定", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 30),
            PromptSlot(id: PromptSlot.memoryInjectionId, name: "🧠 记忆", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 40),
            PromptSlot(id: PromptSlot.dialogueExamplesId, name: "💬 对话示例", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 50),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "📜 对话历史", role: "system",
                       isSystemPrompt: true, isMarker: true, injectionOrder: 60),
            PromptSlot(id: PromptSlot.jailbreakId, name: "📌 后置提醒", role: "system",
                       content: "保持角色设定，用自然的语气回应。",
                       isSystemPrompt: true, isMarker: false, injectionDepth: 0, injectionOrder: 70),
        ]
    }

    static let balanced = Preset(
        id: "built-in-balanced",
        name: "默认",
        description: "通用预设，可自由调整参数",
        isBuiltIn: true,
        sampling: SamplingParams(temperature: 0.7, topP: 0.95, maxTokens: 4096, contextDepth: 40),
        prompts: defaultSlots
    )

    static let allBuiltIn: [Preset] = [balanced]
}

// MARK: - SillyTavern JSON Import/Export

extension Preset {

    /// 内置 marker identifier 列表
    private static let builtInMarkers: Set<String> = [
        PromptSlot.mainId, PromptSlot.chatHistoryId, PromptSlot.charDescriptionId,
        PromptSlot.charPersonalityId, PromptSlot.scenarioId, PromptSlot.personaDescriptionId,
        PromptSlot.dialogueExamplesId, PromptSlot.memoryInjectionId, PromptSlot.jailbreakId,
        "worldInfoBefore", "worldInfoAfter", "enhanceDefinitions", "nsfw",
    ]

    /// 从酒馆 Chat Completion Preset JSON 导入
    static func fromSillyTavernJSON(_ data: Data) throws -> Preset {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Preset", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无效的 JSON 格式"])
        }

        // 尝试从文件名或 prompts[0].name 推导预设名
        let firstName = (json["prompts"] as? [[String: Any]])?.first?["name"] as? String
        var preset = Preset(name: firstName ?? "导入的预设")

        // 1. 采样参数
        var s = SamplingParams()
        s.temperature = json["temperature"] as? Double ?? 0.7
        s.topP = json["top_p"] as? Double ?? 0.95
        s.topK = json["top_k"] as? Int ?? 0
        s.maxTokens = json["openai_max_tokens"] as? Int ?? 4096
        s.frequencyPenalty = json["frequency_penalty"] as? Double ?? 0
        s.presencePenalty = json["presence_penalty"] as? Double ?? 0
        s.maxContextSize = json["openai_max_context"] as? Int ?? 100000
        s.seed = json["seed"] as? Int ?? -1
        s.reasoningEffort = json["reasoning_effort"] as? String ?? "auto"
        s.verbosity = json["verbosity"] as? String ?? "auto"
        s.streaming = json["stream_openai"] as? Bool ?? true
        s.squashSystemMessages = json["squash_system_messages"] as? Bool ?? false
        s.continuePrefill = json["continue_prefill"] as? Bool ?? false
        s.continuePostfix = json["continue_postfix"] as? String ?? " "
        preset.sampling = s

        // 2. 格式模板
        if let sf = json["scenario_format"] as? String, !sf.isEmpty {
            preset.scenarioFormat = sf
        }
        if let pf = json["personality_format"] as? String, !pf.isEmpty {
            preset.characterFormat = pf
        }

        // 3. Prompts
        let stPrompts = json["prompts"] as? [[String: Any]] ?? []

        // 4. 提取 prompt_order 的 enabled 状态
        var enabledMap: [String: Bool] = [:]
        if let promptOrders = json["prompt_order"] as? [[String: Any]] {
            // 取最后一个 (character-specific) 或唯一的
            if let order = promptOrders.last?["order"] as? [[String: Any]] {
                for item in order {
                    if let identifier = item["identifier"] as? String {
                        enabledMap[identifier] = item["enabled"] as? Bool ?? true
                    }
                }
            }
        }

        // 5. 转换每个 prompt
        var slots: [PromptSlot] = []
        for (index, stPrompt) in stPrompts.enumerated() {
            let identifier = stPrompt["identifier"] as? String ?? UUID().uuidString
            let name = stPrompt["name"] as? String ?? ""
            let role = stPrompt["role"] as? String ?? "system"
            let content = stPrompt["content"] as? String ?? ""
            let isSystem = stPrompt["system_prompt"] as? Bool ?? true
            let depth = stPrompt["injection_depth"] as? Int ?? 0
            let order = stPrompt["injection_order"] as? Int ?? (100 + index)
            let forbid = stPrompt["forbid_overrides"] as? Bool ?? false
            let enabled = enabledMap[identifier] ?? true

            let slot = PromptSlot(
                id: identifier,
                name: name,
                role: role,
                content: content,
                isSystemPrompt: isSystem,
                isEnabled: enabled,
                isMarker: builtInMarkers.contains(identifier),
                injectionDepth: depth,
                injectionOrder: order,
                forbidOverrides: forbid
            )
            slots.append(slot)
        }

        preset.prompts = slots

        // 4. 正则脚本
        if let ext = json["extensions"] as? [String: Any],
           let scripts = ext["regex_scripts"] as? [[String: Any]] {
            preset.regexScripts = scripts.map { RegexScript(from: $0) }
        }

        return preset
    }

    /// 导出为酒馆兼容 JSON
    func toSillyTavernJSON() -> Data? {
        var json: [String: Any] = [:]

        // 采样参数
        json["temperature"] = sampling.temperature
        json["top_p"] = sampling.topP
        json["top_k"] = sampling.topK
        json["openai_max_tokens"] = sampling.maxTokens
        json["frequency_penalty"] = sampling.frequencyPenalty
        json["presence_penalty"] = sampling.presencePenalty
        json["openai_max_context"] = sampling.maxContextSize
        json["seed"] = sampling.seed
        json["reasoning_effort"] = sampling.reasoningEffort
        json["verbosity"] = sampling.verbosity
        json["stream_openai"] = sampling.streaming
        json["squash_system_messages"] = sampling.squashSystemMessages
        json["continue_prefill"] = sampling.continuePrefill
        json["continue_postfix"] = sampling.continuePostfix

        // 格式模板
        json["scenario_format"] = scenarioFormat
        json["personality_format"] = characterFormat

        // Prompts
        json["prompts"] = prompts.map { slot -> [String: Any] in
            var p: [String: Any] = [:]
            p["identifier"] = slot.id
            p["name"] = slot.name
            p["role"] = slot.role
            p["content"] = slot.content
            p["system_prompt"] = slot.isSystemPrompt
            p["injection_position"] = 0
            p["injection_depth"] = slot.injectionDepth
            p["injection_order"] = slot.injectionOrder
            p["forbid_overrides"] = slot.forbidOverrides
            return p
        }

        // Prompt order
        json["prompt_order"] = [
            [
                "character_id": 100001,
                "order": prompts.map { slot -> [String: Any] in
                    ["identifier": slot.id, "enabled": slot.isEnabled]
                }
            ] as [String : Any]
        ]

        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// 序列化为 JSON string（原始模式显示用）
    func toJSONString() -> String {
        guard let data = toSillyTavernJSON(),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// 从 JSON string 解析（原始模式粘贴用）
    static func fromJSONString(_ string: String) throws -> Preset {
        guard let data = string.data(using: .utf8) else {
            throw NSError(domain: "Preset", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无效的文本"])
        }
        return try fromSillyTavernJSON(data)
    }
}
