import Foundation

// MARK: - System Prompt Layers (prompt caching)

/// 分层 system prompt，用于 Anthropic prompt caching 断点。
/// 按"几乎不变 → 低频变 → 每轮变"排序，断点打在层 1/层 2 末尾。
struct SystemPromptLayers {
    var stableCore: String = ""   // 层1：preset 插槽 persona + 项目指令（会话期间字节不变）
    var summaryLayer: String = "" // 层2：上下文摘要（滞回裁剪，30轮变一次，最稳定）
    var semiStable: String = ""   // 层3：记忆 + 世界书（可能每轮变）
    var volatile: String = ""     // 层3：{{date}}/{{time}}/{{health}} 展开（每轮变，不打断点）

    var isEmpty: Bool { stableCore.isEmpty && semiStable.isEmpty && summaryLayer.isEmpty && volatile.isEmpty }

    /// 拼成单字符串，供非 Anthropic provider / 预算估算用。
    var combined: String {
        [stableCore, summaryLayer, semiStable, volatile].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// MARK: - Prompt Assembler

struct PromptAssembler {

    /// 层 2（半稳定）的 tag：记忆 / 世界书 / 上下文摘要。其余（preset 插槽 + 项目指令）归层 1。
    static let semiStableTags: Set<String> = ["contextSummary", "crossWindow"]

    /// 把带 tag 的 systemParts 拆成稳定核心 / 半稳定两层（层内保持原有顺序）。
    static func splitLayers(_ parts: [(tag: String, content: String)]) -> (stable: String, semi: String) {
        var stable: [String] = []
        var semi: [String] = []
        for p in parts where !p.content.isEmpty {
            if semiStableTags.contains(p.tag) { semi.append(p.content) }
            else { stable.append(p.content) }
        }
        return (stable.joined(separator: "\n\n"), semi.joined(separator: "\n\n"))
    }

    /// 组装最终发给 API 的 system prompt + messages
    ///
    /// 逻辑：
    /// 1. 遍历 preset.prompts，按 injectionOrder 排序
    /// 2. 跳过 isEnabled=false 的插槽
    /// 3. marker 插槽用 profile/memories/history 填充
    /// 4. 世界书关键词扫描 + 按 position 注入
    /// 5. injectionDepth > 0 的插槽插入到对话历史指定位置
    /// 6. role=system 拼成 system prompt；role=user/assistant 插入 messages
    static func assemble(
        preset: Preset,
        profile: Profile,
        memories: [Memory],
        chatHistory: [(role: String, content: String)],
        worldBooks: [WorldBook] = [],
        globalEntries: [WorldBookEntry] = [],
        contextSummary: String? = nil,
        crossWindowSummaries: String? = nil,
        projectInstructions: String? = nil,
        styleContent: String? = nil
    ) -> (systemPrompt: String?, systemParts: [(tag: String, content: String)], messages: [(role: String, content: String)]) {

        let contextDepth = preset.sampling.contextDepth
        // 调用方（buildAPIMessages anchored）已做压缩游标锚定窗口，这里不再二次 suffix 截断
        // （二次截断会重新引入滑动窗口，毁掉缓存前缀）。完整窗口直接进 messages。
        let messageHistory = chatHistory
        // 世界书扫描 / marker 解析仍只看最近 contextDepth 条，行为不变。
        let trimmedHistory = chatHistory.count > contextDepth
            ? Array(chatHistory.suffix(contextDepth))
            : chatHistory

        // 按 injectionOrder 排序，过滤禁用的
        let activeSlots = preset.prompts
            .filter { $0.isEnabled || $0.isSystemPrompt }
            .sorted { $0.injectionOrder < $1.injectionOrder }

        // tagged system parts：追踪每个 part 的来源 slot id，世界书需要按 position 插入
        var systemParts: [(tag: String, content: String)] = []
        var preHistoryMessages: [(role: String, content: String)] = []
        var postHistoryInjections: [(depth: Int, role: String, content: String)] = []

        for slot in activeSlots {
            let content = resolveSlotContent(
                slot, profile: profile, preset: preset,
                memories: memories, chatHistory: trimmedHistory
            )

            // chatHistory marker 特殊处理：不拼到 system prompt
            if slot.isMarker && slot.id == PromptSlot.chatHistoryId {
                continue
            }

            // dialogueExamples marker：解析为 messages
            if slot.isMarker && slot.id == PromptSlot.dialogueExamplesId {
                if let examples = content {
                    // 标记对话示例位置，方便世界书 beforeExamples/afterExamples 插入
                    preHistoryMessages.append((role: "_examples_marker_", content: ""))
                    preHistoryMessages += parseChatExamples(examples, profile: profile)
                    preHistoryMessages.append((role: "_examples_end_marker_", content: ""))
                }
                continue
            }

            guard let resolved = content, !resolved.isEmpty else { continue }

            // injection_depth > 0：插入到对话历史指定深度
            if slot.injectionDepth > 0 {
                postHistoryInjections.append((depth: slot.injectionDepth, role: slot.role, content: resolved))
                continue
            }

            // role=system 拼到 system prompt（带 tag）
            if slot.role == "system" {
                systemParts.append((tag: slot.id, content: resolved))
            } else {
                preHistoryMessages.append((role: slot.role, content: resolved))
            }
        }

        // ── 世界书注入 ──
        if !worldBooks.isEmpty || !globalEntries.isEmpty {
            let recentTexts = trimmedHistory.map { $0.content }
            let resolved = WorldBookScanner.scan(
                worldBooks: worldBooks,
                recentMessages: recentTexts,
                profile: profile,
                globalEntries: globalEntries
            )

            for entry in resolved {
                switch entry.position {
                case .beforeCharDef:
                    // 插到 charDescriptionId 之前
                    if let idx = systemParts.firstIndex(where: { $0.tag == PromptSlot.charDescriptionId }) {
                        systemParts.insert((tag: "wb", content: entry.content), at: idx)
                    } else {
                        systemParts.append((tag: "wb", content: entry.content))
                    }

                case .afterCharDef:
                    // 插到 charDescriptionId 之后
                    if let idx = systemParts.firstIndex(where: { $0.tag == PromptSlot.charDescriptionId }) {
                        systemParts.insert((tag: "wb", content: entry.content), at: systemParts.index(after: idx))
                    } else {
                        systemParts.append((tag: "wb", content: entry.content))
                    }

                case .beforeExamples:
                    // 插到对话示例 marker 之前
                    if let idx = preHistoryMessages.firstIndex(where: { $0.role == "_examples_marker_" }) {
                        preHistoryMessages.insert((role: entry.role, content: entry.content), at: idx)
                    } else {
                        preHistoryMessages.append((role: entry.role, content: entry.content))
                    }

                case .afterExamples:
                    // 插到对话示例 end marker 之后
                    if let idx = preHistoryMessages.firstIndex(where: { $0.role == "_examples_end_marker_" }) {
                        preHistoryMessages.insert((role: entry.role, content: entry.content), at: preHistoryMessages.index(after: idx))
                    } else {
                        preHistoryMessages.append((role: entry.role, content: entry.content))
                    }

                case .atDepth:
                    postHistoryInjections.append((depth: entry.depth, role: entry.role, content: entry.content))

                case .authorNoteTop:
                    // jailbreak 之前
                    if let idx = systemParts.firstIndex(where: { $0.tag == PromptSlot.jailbreakId }) {
                        systemParts.insert((tag: "wb", content: entry.content), at: idx)
                    } else {
                        systemParts.append((tag: "wb", content: entry.content))
                    }

                case .authorNoteBot:
                    // jailbreak 之后
                    if let idx = systemParts.firstIndex(where: { $0.tag == PromptSlot.jailbreakId }) {
                        systemParts.insert((tag: "wb", content: entry.content), at: systemParts.index(after: idx))
                    } else {
                        systemParts.append((tag: "wb", content: entry.content))
                    }
                }
            }
        }

        // 清理 marker 占位符
        preHistoryMessages.removeAll { $0.role == "_examples_marker_" || $0.role == "_examples_end_marker_" }

        // 上下文摘要注入 → 独立的 summaryLayer（滞回裁剪，30轮变一次）
        // 不放 semiStable 里，因为摘要的变化频率跟记忆/世界书不同
        if let summary = contextSummary, !summary.isEmpty {
            systemParts.append((tag: "contextSummary", content: "[前情提要]\n\(summary)"))
        }

        // Task H 跨窗口记忆：新对话首轮注入最近 15 个对话的摘要（semiStable 层）
        if let cw = crossWindowSummaries, !cw.isEmpty {
            systemParts.append((tag: "crossWindow", content: cw))
        }

        // 项目指令注入
        if let proj = projectInstructions, !proj.isEmpty {
            systemParts.append((tag: "projectInstructions", content: "[项目指令]\n\(proj)"))
        }

        let systemPrompt = systemParts.isEmpty ? nil : systemParts.map(\.content).joined(separator: "\n\n")

        // 组装 messages：pre-history + chat history(完整锚定窗口) + injections at depth
        var messages = preHistoryMessages + messageHistory

        // 插入 injection_depth > 0 的内容
        for injection in postHistoryInjections.sorted(by: { $0.depth > $1.depth }) {
            let insertIndex = max(0, messages.count - injection.depth)
            messages.insert((role: injection.role, content: injection.content), at: insertIndex)
        }

        // 写作风格：拼进最后一条 user 消息末尾（粟粟同款 <style> 标记）。
        // 走 last user 而非 system 的原因：网关路径只透传 last user（system 由网关端缓存人格接管），
        // 这样直连与网关两条路都能带上风格；历史轮不复读（node 存的原文干净，只在出口拼一次）。
        // 此前 styleContent 参数收进来后没有任何使用——搬运时只搬了签名没搬实现，风格从未生效过。
        if let styleContent, !styleContent.isEmpty {
            let styleText = "\n<style>\(styleContent)</style>"
            if let lastUserIdx = messages.lastIndex(where: { $0.role == "user" }) {
                messages[lastUserIdx].content += styleText
            } else {
                messages.append((role: "user", content: styleText))
            }
        }

        return (systemPrompt: systemPrompt, systemParts: systemParts, messages: messages)
    }

    /// 生成完整 prompt 预览（raw view 用）
    static func preview(
        preset: Preset,
        profile: Profile,
        memories: [Memory],
        chatHistory: [(role: String, content: String)] = [],
        worldBooks: [WorldBook] = [],
        contextSummary: String? = nil
    ) -> String {
        let result = assemble(preset: preset, profile: profile, memories: memories, chatHistory: chatHistory, worldBooks: worldBooks, contextSummary: contextSummary)

        var lines: [String] = []

        if let sys = result.systemPrompt {
            lines.append("═══ SYSTEM ═══")
            lines.append(sys)
            lines.append("")
        }

        for msg in result.messages {
            let label = msg.role.uppercased()
            lines.append("─── \(label) ───")
            lines.append(msg.content)
            lines.append("")
        }

        if chatHistory.isEmpty {
            lines.append("─── (对话历史将在这里，当前深度: \(preset.sampling.contextDepth) 条) ───")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    /// 解析插槽内容：
    /// - 普通插槽用自身 content
    /// 从「当前预设 + 楼层」提取人设文本：把角色人格相关的插槽（系统指令 / 助手设定 /
    /// 用户描述 / 背景设定 / 后置提醒）按 injectionOrder 拼成一段纯文本，供「导入到群聊
    /// 角色设定」用。刻意排除记忆注入 / 对话历史 / 对话示例 / 世界书——那些是运行时上下文，
    /// 不属于人格本身。
    static func personaText(profile: Profile, preset: Preset) -> String {
        let personaSlotIds: Set<String> = [
            PromptSlot.mainId,
            PromptSlot.charDescriptionId,
            PromptSlot.personaDescriptionId,
            PromptSlot.scenarioId,
            PromptSlot.jailbreakId,
        ]
        let slots = preset.prompts
            .filter { ($0.isEnabled || $0.isSystemPrompt) && personaSlotIds.contains($0.id) }
            .sorted { $0.injectionOrder < $1.injectionOrder }

        var parts: [String] = []
        for slot in slots {
            guard let content = resolveSlotContent(
                slot, profile: profile, preset: preset, memories: [], chatHistory: []
            ), !content.isEmpty else { continue }
            parts.append(content)
        }
        return parts.joined(separator: "\n\n")
    }

    /// - marker 插槽：如果自身有 content 优先用（导入的预设），否则 fallback 到 profile 数据
    private static func resolveSlotContent(
        _ slot: PromptSlot,
        profile: Profile,
        preset: Preset,
        memories: [Memory],
        chatHistory: [(role: String, content: String)]
    ) -> String? {
        guard slot.isMarker else {
            return applyMacros(slot.content, profile: profile)
        }

        // Marker 但自身有内容（如导入的酒馆预设）→ 优先用自身 content
        if !slot.content.isEmpty {
            switch slot.id {
            case PromptSlot.chatHistoryId:
                return nil // 对话历史永远不拼到 system prompt
            case PromptSlot.memoryInjectionId:
                break // 记忆始终动态生成
            default:
                return applyMacros(slot.content, profile: profile)
            }
        }

        // Marker fallback：从 profile 数据填充
        switch slot.id {
        case PromptSlot.mainId:
            return profile.systemPrompt.isEmpty ? nil : applyMacros(profile.systemPrompt, profile: profile)

        case PromptSlot.personaDescriptionId:
            guard !profile.userPersona.isEmpty else { return nil }
            let formatted = preset.personaFormat
                .replacingOccurrences(of: "{{persona}}", with: profile.userPersona)
            return applyMacros(formatted, profile: profile)

        case PromptSlot.charDescriptionId:
            guard !profile.characterDescription.isEmpty else { return nil }
            let formatted = preset.characterFormat
                .replacingOccurrences(of: "{{description}}", with: profile.characterDescription)
                .replacingOccurrences(of: "{{personality}}", with: profile.characterPersonality)
            return applyMacros(formatted, profile: profile)

        case PromptSlot.charPersonalityId:
            return nil

        case PromptSlot.scenarioId:
            guard !profile.scenario.isEmpty else { return nil }
            let formatted = preset.scenarioFormat
                .replacingOccurrences(of: "{{scenario}}", with: profile.scenario)
            return applyMacros(formatted, profile: profile)

        case PromptSlot.memoryInjectionId:
            // 本地记忆三态开关：on 才注入（recordOnly 只提取不注入 / off 全关）
            if !LocalMemoryMode.current.injects { return nil }
            // PR-5: 启用后端记忆系统时，记忆注入改由网关 retriever+gatekeeper 在服务端完成；
            // App 端本地记忆只存不注入（离线 / 开关关闭时仍走本地注入）。
            if UserDefaults.standard.bool(forKey: "useBackendMemory") { return nil }
            let injection = MemoryInjector.buildInjection(memories: memories)
            return injection.isEmpty ? nil : "[关于用户]\n\(injection)"

        case PromptSlot.dialogueExamplesId:
            return profile.chatExamples.isEmpty ? nil : profile.chatExamples

        case PromptSlot.chatHistoryId:
            return nil

        default:
            return nil
        }
    }

    /// 宏替换：{{user}} / {{char}}
    private static func applyMacros(_ text: String, profile: Profile) -> String {
        MacroExpander.expand(text, userName: profile.userName, charName: profile.assistantName)
    }

    /// 解析对话示例为 user/assistant 消息对
    ///
    /// 格式支持：
    /// - `{{user}}: 内容` / `{{char}}: 内容`
    /// - `用户: 内容` / `AI: 内容`
    /// - `<START>` 分隔符（忽略）
    private static func parseChatExamples(_ text: String, profile: Profile) -> [(role: String, content: String)] {
        let lines = text.components(separatedBy: "\n")
        var messages: [(role: String, content: String)] = []

        let userPrefixes = ["{{user}}:", "\(profile.userName):", "用户:"]
        let charPrefixes = ["{{char}}:", "\(profile.assistantName):", "AI:"]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "<START>" || trimmed.hasPrefix("[Start") { continue }

            var matched = false
            for prefix in userPrefixes {
                if trimmed.hasPrefix(prefix) {
                    let content = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty { messages.append((role: "user", content: content)) }
                    matched = true
                    break
                }
            }
            if matched { continue }

            for prefix in charPrefixes {
                if trimmed.hasPrefix(prefix) {
                    let content = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty { messages.append((role: "assistant", content: content)) }
                    matched = true
                    break
                }
            }
        }

        return messages
    }
}
