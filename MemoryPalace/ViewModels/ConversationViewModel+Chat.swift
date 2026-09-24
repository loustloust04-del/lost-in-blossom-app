import UIKit
import Foundation
import SwiftData

// MARK: - Chat (API)

extension ConversationViewModel {

    /// 用 PromptAssembler 组装完整 prompt
    private func assemblePrompt(
        profile: Profile,
        preset: Preset,
        excludingNodeId: String? = nil,
        context: ModelContext,
        globalEntries: [WorldBookEntry] = []
    ) -> (systemPrompt: String?, systemLayers: SystemPromptLayers?, messages: [(role: String, content: String)], sampling: SamplingParams) {
        // memoryEnabled=false 的对话不注入记忆；全局三态非 on 也不注入（省一次 fetch）
        let shouldInjectMemory = (selectedConversation?.memoryEnabled ?? true) && LocalMemoryMode.current.injects
        let memories: [Memory] = shouldInjectMemory ? memoryStore.listHot(profileId: profile.id, context: context) : []
        let ids = memories.map(\.id)
        if !ids.isEmpty { try? memoryStore.recordAccess(ids: ids, context: context) }

        let chatHistory = buildAPIMessages(excluding: excludingNodeId, anchored: true)

        // 查询当前楼层的世界书（过滤 conversation scope）
        let profileId = profile.id
        let wbDescriptor = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == profileId })
        let allFloorBooks = (try? context.fetch(wbDescriptor)) ?? []
        let currentConvId = selectedConversation?.id ?? ""
        let worldBooks = allFloorBooks.filter { book in
            // nil = 楼层全体生效，有值 = 仅匹配的对话生效
            book.scopeConversationId == nil || book.scopeConversationId == currentConvId
        }

        // 读取上下文摘要
        let contextSummary = ContextSummarizer.load(conversationId: currentConvId)?.summary

        // 读取项目指令
        var projectInstructions: String? = nil
        if let projId = selectedConversation?.projectId, !projId.isEmpty {
            let pid = projId
            let projFetch = FetchDescriptor<Project>(predicate: #Predicate { $0.id == pid })
            if let proj = try? context.fetch(projFetch).first, !proj.instructions.isEmpty {
                projectInstructions = proj.instructions
            }
        }

        // Task H：跨窗口记忆——仅新对话首轮注入最近 15 个对话的摘要
        let isFirstTurn = !chatHistory.contains { $0.role == "assistant" }
        // 深继承的对话已带上文脉络，轻摘要让位（避免重复占 token）
        let isInherited = ContextInheritance.sourceTitle(for: selectedConversation?.id ?? "") != nil
        let crossWindow = (isFirstTurn && !isInherited)
            ? CrossWindowMemory.injectionText(excluding: selectedConversation?.id)
            : nil

        // 写作风格
        let styleContent: String? = {
            guard let styleId = selectedConversation?.currentStyleId, !styleId.isEmpty else { return nil }
            return StyleManager.shared.find(styleId)?.content
        }()

        // 发语音条注入段：走 projectInstructions（volatile 层，不碰缓存前缀）。
        // 三条件（开关+key+楼层选了声音）不满足时 hint 为 nil，一字不注。
        if let voiceHint = VoicePromptInjector.hint(profile: profile) {
            projectInstructions = [projectInstructions, voiceHint].compactMap { $0 }.joined(separator: "\n\n")
        }

        // 健康手账帮记 hint：同 voiceHint 走 projectInstructions（volatile 层，不碰缓存前缀），闸全关一字不注。
        let healthEntryHint = HealthLogStore.chatEntryHint(context: context, profileId: profile.id)
        if !healthEntryHint.isEmpty {
            projectInstructions = [projectInstructions, healthEntryHint].compactMap { $0 }.joined(separator: "\n\n")
        }

        let result = PromptAssembler.assemble(
            preset: preset,
            profile: profile,
            memories: memories,
            chatHistory: chatHistory,
            worldBooks: worldBooks,
            globalEntries: globalEntries,
            contextSummary: contextSummary,
            crossWindowSummaries: crossWindow,
            projectInstructions: projectInstructions,
            styleContent: styleContent
        )

        // ── 分层 + 宏移出缓存前缀 ──
        // {{date}}/{{time}}/{{health}} 只允许出现在 volatile 层；从层 1/层 2 剥离，
        // 否则 {{time}} 精确到分钟会让整个 system 前缀每分钟失效（头号缓存杀手）。
        let (stable0, semi0) = PromptAssembler.splitLayers(result.systemParts)

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 EEEE"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "zh_CN")
        tf.dateFormat = "HH:mm"

        func stripVolatileMacros(_ s: String) -> String {
            var x = s
                .replacingOccurrences(of: "{{health}}", with: "")
                .replacingOccurrences(of: "{{date}}", with: "")
                .replacingOccurrences(of: "{{time}}", with: "")
            while x.contains("\n\n\n") {
                x = x.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            return x.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 只在 preset 真的用了该宏时才注入 volatile（不给没用宏的 preset 平白塞日期/时间）。
        let macroProbe = stable0 + semi0
        let usesHealth = macroProbe.contains("{{health}}")
        let usesDate = macroProbe.contains("{{date}}")
        let usesTime = macroProbe.contains("{{time}}")

        let stableCore = stripVolatileMacros(stable0)
        let semiStable = stripVolatileMacros(semi0)

        var volatileParts: [String] = []
        if usesHealth {
            let h = HealthService.shared.injectedSummary
            if !h.isEmpty { volatileParts.append(h) }
            // 手账注入（体重/吃药/经期/亲密，各闸在 composedHealthSummary 内收口；亲密只报当天、note 不注）
            let hl = HealthLogStore.composedHealthSummary(context: context, profileId: profile.id)
            if !hl.isEmpty { volatileParts.append(hl) }
        }
        // 始终注入当前日期和时间（不再依赖 {{date}}/{{time}} 宏）
        volatileParts.append("当前日期：\(df.string(from: Date()))")
        volatileParts.append("当前时间：\(tf.string(from: Date()))")

        // 时间感：距离上次对话多久了
        if let lastNode = currentPath.last(where: { $0.role == "user" && !$0.content.isEmpty }),
           let lastDate = lastNode.createTime {
            let gap = Date().timeIntervalSince(lastDate)
            let minutes = Int(gap / 60)
            if minutes > 2 {
                let timeAgo: String
                if minutes < 60 {
                    timeAgo = "\(minutes)分钟前"
                } else if minutes < 1440 {
                    timeAgo = "\(minutes / 60)小时\(minutes % 60 > 0 ? "\(minutes % 60)分钟" : "")前"
                } else {
                    timeAgo = "\(minutes / 1440)天前"
                }
                volatileParts.append("用户上一条消息发送于\(timeAgo)")
            }
        }

        let volatileLayer = volatileParts.joined(separator: "\n")

        // 摘要独立层：从 systemParts 里抽出 contextSummary tag，不混在 semiStable 里
        let summaryContent = result.systemParts
            .filter { $0.tag == "contextSummary" }
            .map(\.content)
            .joined(separator: "\n\n")
        // semiStable 去掉摘要（已经在 summaryLayer 里了）
        let semiWithoutSummary = result.systemParts
            .filter { PromptAssembler.semiStableTags.contains($0.tag) && $0.tag != "contextSummary" }
            .map(\.content)
            .joined(separator: "\n\n")
        let cleanSemi = stripVolatileMacros(semiWithoutSummary.isEmpty ? semiStable : semiWithoutSummary)

        let layers = SystemPromptLayers(stableCore: stableCore, summaryLayer: summaryContent, semiStable: cleanSemi, volatile: volatileLayer)

        // cacheFriendly：易变内容（记忆/世界书命中 + 日期时间健康）下沉成一条伪 user 消息，
        // 插在当前用户消息之前；system 只留稳定前缀（stableCore + summaryLayer），保护缓存前缀字节不变。
        if preset.sampling.cacheFriendly {
            let stableLayers = SystemPromptLayers(stableCore: stableCore, summaryLayer: summaryContent, semiStable: "", volatile: "")
            let stableSystem = stableLayers.combined
            let volatileBody = [cleanSemi, volatileLayer].filter { !$0.isEmpty }.joined(separator: "\n\n")
            var msgs = result.messages
            if !volatileBody.isEmpty {
                let insertAt = max(0, msgs.count - 1)  // 倒数第二位（当前 user 之前）
                msgs.insert((role: "user", content: "[动态上下文｜仅供参考，不要复述]\n" + volatileBody), at: insertAt)
            }
            return (
                systemPrompt: stableSystem.isEmpty ? nil : stableSystem,
                systemLayers: stableLayers.isEmpty ? nil : stableLayers,
                messages: msgs,
                sampling: preset.sampling
            )
        }

        let combined = layers.combined
        return (
            systemPrompt: combined.isEmpty ? nil : combined,
            systemLayers: layers.isEmpty ? nil : layers,
            messages: result.messages,
            sampling: preset.sampling
        )
    }

    /// ccBridge 路径：把 PromptAssembler 的输出后处理成只发 raw user 文字，
    /// 同时构造 router 的 additionalHeaders（chat_id/message_id/user）。
    /// 其他 provider 类型走原路（直接返回 assembled + 空 headers）。
    private func prepareRouterPayload(
        assembled: (systemPrompt: String?, systemLayers: SystemPromptLayers?, messages: [(role: String, content: String)], sampling: SamplingParams),
        model: ProviderModel,
        conversation: Conversation,
        profile: Profile,
        providerManager: ProviderManager,
        messageNodeId: String
    ) -> (
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        systemLayers: SystemPromptLayers?,
        sampling: SamplingParams,
        additionalHeaders: [String: String]
    ) {
        guard let provider = providerManager.provider(for: model),
              provider.type == .ccBridge else {
            // 非 ccBridge：默认无额外 header。cacheFriendly + OpenRouter 时钉 x-session-id（=对话UUID），
            // 把请求固定到同一上游 provider，保证 prompt cache 命中。
            var headers: [String: String] = [:]
            if assembled.sampling.cacheFriendly,
               let p = providerManager.provider(for: model),
               p.baseURL.lowercased().contains("openrouter") {
                headers["x-session-id"] = conversation.id
            }
            return (assembled.messages, assembled.systemPrompt, assembled.systemLayers, assembled.sampling, headers)
        }
        // ccBridge：只取最后一条 user 的 raw 文字，丢掉 system prompt 和历史
        let lastUser = assembled.messages.last(where: { $0.role == "user" })?.content ?? ""
        let userLabel = profile.userName.isEmpty ? "tianyi" : profile.userName
        var headers: [String: String] = [
            "X-MP-ChatId": conversation.id,
            "X-MP-MessageId": messageNodeId,
            "X-MP-User": userLabel,
        ]
        // PR-3: 注入最近 10 条原始对话（不用摘要），让 CC 接话时知道刚聊了什么
        let ctxUserLabel = profile.userName.isEmpty ? "兔兔" : profile.userName
        let ctxAsstLabel = profile.assistantName.isEmpty ? "Caelum" : profile.assistantName
        let history = currentPath.filter {
            ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty
        }
        // 去掉最后一条（= 本次要发的 user 消息，已作为 content 单独发送）
        let priorHistory = history.count > 1 ? Array(history.dropLast()) : []
        let recentContext = priorHistory.suffix(20).map { node -> String in
            let label = node.role == "user" ? ctxUserLabel : (node.senderName ?? ctxAsstLabel)
            let clean = ContentCleaner.extractThinking(from: node.content).content
            return "[\(label)]: \(clean)"
        }.joined(separator: "\n")
        if !recentContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["X-MP-Context"] = recentContext
        }
        return (
            messages: [(role: "user", content: lastUser)],
            systemPrompt: nil,
            systemLayers: nil,
            sampling: assembled.sampling,
            additionalHeaders: headers
        )
    }

    /// 主 provider id → 该 provider 下"便宜模型"的 modelId。粟粟批注：暂硬编码，
    /// 未来可扩展成配置。provider 不在表里就没 cheap 可用 → fallback 到主对话模型。
    private static let cheapModelIdByProvider: [String: String] = [
        "anthropic": "claude-haiku-4-5",
        "openai":    "gpt-4o-mini",
        "deepseek":  "deepseek-chat",
        "gemini":    "gemini-2.5-flash",
        "groq":      "llama-3.3-70b-versatile",
    ]

    /// 选择记忆提取 / 上下文总结等 backend agent 用的便宜模型。
    /// **只在 enabledProviders（有 key）里找**，避免落到没 key 没拨款的 provider。
    /// 顺序：用户旧设置 `memoryExtractModelId`（限 enabled）→ 主 provider 的 cheap map → fallback。
    private func cheapModel(providerManager: ProviderManager, fallback: ProviderModel) -> ProviderModel {
        let enabledModels = providerManager.enabledProviders.flatMap(\.models)

        // 老 UserDefaults key 兼容（Picker 现已被 MemoryModelConfig 替代，但之前选过的仍尊重）
        let userChoice = UserDefaults.standard.string(forKey: "memoryExtractModelId") ?? ""
        if !userChoice.isEmpty, let model = enabledModels.first(where: { $0.id == userChoice }) {
            return model
        }

        if let cheapId = Self.cheapModelIdByProvider[fallback.providerId],
           let provider = providerManager.enabledProviders.first(where: { $0.id == fallback.providerId }),
           let model = provider.models.first(where: { $0.modelId == cheapId }) {
            return model
        }

        return fallback
    }

    /// Build API message history from currentPath, excluding a specific node, limited to recent messages
    private func buildAPIMessages(excluding excludeId: String? = nil, maxMessages: Int = 40, anchored: Bool = false) -> [(role: String, content: String)] {
        // 旧图转述（粟粟 M7）：最近 3 条 user 消息里的图照发原图，更早的有描述就换成文字
        let userIds = currentPath.filter { $0.role == "user" && $0.id != excludeId }.map(\.id)
        let recentUserIds = Set(userIds.suffix(3))
        let relevant = currentPath.compactMap { node -> (role: String, content: String)? in
            guard node.role == "user" || node.role == "assistant" else { return nil }
            if node.id == excludeId { return nil }
            guard !node.content.isEmpty else { return nil }
            // Strip thinking blocks from assistant messages before sending
            let content: String
            if node.role == "assistant" {
                let result = ContentCleaner.extractThinking(from: node.content)
                content = result.content
            } else if node.contentType == "multimodal_text", !recentUserIds.contains(node.id),
                      let summary = ImageSummaryStore.summary(for: node.id) {
                let t = ImageSummaryStore.textPart(of: node.content)
                content = (t.isEmpty ? "" : t + "\n") + "[图片：\(summary)]"
            } else {
                content = node.content
            }
            guard !content.isEmpty else { return nil }
            return (role: node.role, content: content)
        }

        // 锚定窗口（chat 发送路径）：从压缩游标取窗口，而不是 suffix。
        // 游标只在压缩推进时按 chunk 跳变，其余时间历史前缀字节不变 →
        // Anthropic prompt cache 命中，缓存读只收 0.1× 输入价。
        // suffix(maxMessages) 是缓存杀手：每来一条新消息最旧一条滑出，前缀每轮都变。
        if anchored {
            let convId = selectedConversation?.id ?? ""
            let cursor = min(ContextSummarizer.windowStart(conversationId: convId), relevant.count)
            var window = Array(relevant.suffix(from: cursor))
            // hard cap：压缩故障导致游标卡死时，防止窗口无限增长烧 token。
            let hardCap = 120
            if window.count > hardCap {
                window = Array(window.suffix(hardCap))
            }
            return window
        }

        // 非锚定路径（如摘要传 maxMessages: Int.max 要全量）：保留旧的 suffix 行为。
        if relevant.count > maxMessages {
            return Array(relevant.suffix(maxMessages))
        }
        return relevant
    }

    /// 文本文件多编码解码链：UTF-8 → UTF-16（带/不带 BOM，备忘录导出 /
    /// Windows 记事本常见）→ GB18030/GBK（中文旧文件）→ Latin-1 兜底。
    /// 全部失败返回 nil（调用方给出人话错误）。
    static func decodeTextFile(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf16LittleEndian), !s.contains("\0") { return s }
        if let s = String(data: data, encoding: .utf16BigEndian), !s.contains("\0") { return s }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return s }
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbk)) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return nil
    }

    /// 扩展名 → MIME（CC 落盘文件的 media_type 提示；不认得就用通用二进制）。
    static func attachmentMime(ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "txt", "log", "text": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "json", "jsonl": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        case "swift", "py", "js", "jsx", "ts", "tsx", "css", "sh", "java", "kt",
             "c", "h", "cpp", "hpp", "rs", "go", "rb", "php", "sql":
            return "text/plain"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// 清洗输入法偷偷插入的零宽字符，但**不拆散 emoji**。
    ///
    /// 09-03 兔兔报的 bug：😵‍💫 发出去变成 😵💫。旧版一句正则把
    /// `[\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00AD}]` 全删了——U+200D（ZWJ）恰恰是
    /// emoji 组合序列的粘合剂，😵‍💫 就是 😵 + ZWJ + 💫，删掉粘合剂它就散成两个。
    ///
    /// 现在分两类处理：
    /// - ZWSP / BOM / 软连字符：任何位置都是杂散，照删
    /// - ZWJ / ZWNJ：**左右两侧都是 emoji 相关字符才保留**，否则算杂散删掉
    ///   （左侧要跳过变体选择符 U+FE0F 和肤色修饰符——❤️‍🔥 里 ZWJ 的前一个 scalar
    ///   是 FE0F 不是 emoji 本体，不跳就会误删）
    static func stripStrayInvisibles(_ s: String) -> String {
        /// emoji 序列里的合法邻居：emoji 本体、变体选择符、肤色修饰符、区域指示符
        func emojiish(_ u: Unicode.Scalar) -> Bool {
            if u.properties.isEmoji { return true }
            let v = u.value
            return v == 0xFE0F || v == 0xFE0E
                || (0x1F3FB...0x1F3FF).contains(v)
                || (0x1F1E6...0x1F1FF).contains(v)
        }

        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)

        for (i, u) in scalars.enumerated() {
            switch u.value {
            case 0x200B, 0xFEFF, 0x00AD:
                continue
            case 0x200C, 0x200D:
                // 左邻：跳过变体选择符 / 肤色修饰符，找到真正的前一个字符
                var j = i - 1
                while j >= 0 {
                    let v = scalars[j].value
                    if v == 0xFE0F || v == 0xFE0E || (0x1F3FB...0x1F3FF).contains(v) { j -= 1; continue }
                    break
                }
                let prev: Unicode.Scalar? = j >= 0 ? scalars[j] : nil
                let next: Unicode.Scalar? = i + 1 < scalars.count ? scalars[i + 1] : nil
                guard let p = prev, let n = next, emojiish(p), emojiish(n) else { continue }
            default:
                break
            }
            out.append(u)
        }
        return String(out)
    }

    /// Send a user message and get a streaming response.
    /// 返回 true = 已受理（发出或排队）；false = 被 guard 拦下（无对话 / 预算闸 / 空群）。
    /// drainPendingSends 用返回值决定是否把 pending 塞回队列，不静默丢消息。
    @discardableResult
    func sendMessage(_ text: String, imageData: Data? = nil, fileData: Data? = nil, fileName: String? = nil, attachments: [PendingChatAttachment] = [], model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) -> Bool {
        // 清洗零宽字符（iOS输入法切换时偷偷插入）
        // 09-03 兔兔报：😵‍💫 发出去变成 😵💫——旧版把 U+200D 一起删了，
        // 而 ZWJ 正是 emoji 组合序列的粘合剂。改成只删「孤立的」连接符，见 stripStrayInvisibles。
        let text = Self.stripStrayInvisibles(text)
        guard let conversation = selectedConversation else { return false }

        // 群聊 V3：串行门控编排（API 车道），不走单聊逻辑
        if conversation.kind == "group" {
            if assistantTurnInFlight {
                // 同一个群的轮次正在跑 → 插话：直接入树，不排队。轮次循环每圈实时重取
                // groupHistoryItems()，所以后续角色发言自然看到这条（像真群里插话）。
                if streamingConversationId == conversation.id {
                    let userName = UserDefaults.standard.string(forKey: "userName") ?? "我"
                    // sendMessage 的两个调用方都在主线程（SwiftUI action / drain 的 @MainActor Task），
                    // 同步入树保证插话先于 pending 标志生效
                    MainActor.assumeIsolated {
                        _ = insertGroupNode(role: "user", content: text,
                                            senderId: nil, senderName: userName,
                                            conversation: conversation, context: context)
                    }
                    BreadcrumbLog.shared.add("👥", "群聊插话: \(text.prefix(30))...")
                    groupInterjectionPending = true
                    return true
                }
                // 别的对话在跑 → 仍排队（跨对话并发会打架全局流式状态，防护保留）
                queuePendingSend(text, imageData: imageData, fileData: fileData, fileName: fileName,
                                 attachments: attachments,
                                 model: model, profile: profile, preset: preset,
                                 providerManager: providerManager, context: context,
                                 conversation: conversation)
                return true
            }
            let participants = conversation.participants
            guard !participants.isEmpty else { return false }
            assistantTurnInFlight = true
            streamingConversationId = conversation.id
            Task { @MainActor in
                await self.runGroupRound(conversation: conversation, userText: text,
                                         participants: participants,
                                         providerManager: providerManager, context: context)
                self.finishAssistantTurn()
            }
            return true
        }

        // 车道判定：CC 走 Hub/tmux 线路，与 API providers 物理隔离（CC 豁免，
        // 两条车道互不排队——CC 等回复不挡 API 对话，API 流式不挡 CC 对话）。
        let isCCLane = providerManager.provider(for: model)?.type == .ccBridge

        // 发送排队闸门（分车道）：
        // - API 消息只在 API turn 进行中排队（同 provider 并发 resetState 掐死前一条流；
        //   跨 provider 并发则 streamingText/streamingNodeId 全局单值被两条流打架）
        // - CC 消息只在已有 CC turn 等待时排队（CCBridgeProvider 单实例，
        //   双发会互相打架 replyTimer/replyHandler）
        if isCCLane ? (ccTurnConversationId != nil) : assistantTurnInFlight {
            queuePendingSend(text, imageData: imageData, fileData: fileData, fileName: fileName,
                             attachments: attachments,
                             model: model, profile: profile, preset: preset,
                             providerManager: providerManager, context: context,
                             conversation: conversation)
            return true
        }

        // 多附件 · API 车道拒发抽不出文本的文件（兔兔 09-12 拍板：只允许能抽文本的；CC 车道不限，
        // 因为 hub 落盘后 Caelum 用 Read 什么都能读）
        if !isCCLane {
            let unreadable = attachments.filter { !$0.isImage && $0.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !unreadable.isEmpty {
                transientNotice = TransientNotice("「\(unreadable.map(\.name).joined(separator: "、"))」抽不出文字，这类文件只有 Caelum 能读")
                return false
            }
        }

        guard preCheckBudget(text: text, model: model, profile: profile, preset: preset, providerManager: providerManager) else { return false }

        // 1. Determine parent node (last node in path, or nil for first message)
        let parentId = currentPath.last?.id

        // 2. Build content and contentType
        // 附件管线对齐粟粟：content = 用户文字 + [附件] 全文（发给模型），
        // attachmentSegments = 文字段 + 附件卡段（气泡渲染折叠卡片，不再把全文铺进气泡）。
        let (userContent, userContentType, attachmentSegments): (String, String, [MessageSegment]?) = {
            // ── 多附件（09-12，兔兔要粟粟那边的「一次发多张/多文件」）──
            // 图 → 每张一个 image block（OpenAI 兼容层 / CC 都按 block 数组吃，早就是多张就绪）；
            // 非图 → CC 车道每个一个 file block（hub saveInboundFiles 整批落盘）+ 文字里附抽取文本；
            //        API 车道只走抽取文本（抽不出的在上面已拒）。气泡：附件卡段。
            if !attachments.isEmpty {
                let images = attachments.filter(\.isImage)
                let others = attachments.filter { !$0.isImage }
                var blocks: [[String: Any]] = []
                for img in images {
                    guard let d = img.imageData else { continue }
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": img.mimeType ?? "image/jpeg", "data": d.base64EncodedString()]])
                }
                if isCCLane {
                    for f in others {
                        guard let d = f.fileData else { continue }
                        blocks.append(["type": "file", "name": f.name, "media_type": f.mimeType ?? "application/octet-stream", "data": d.base64EncodedString()])
                    }
                }
                // CC 车道：正文只放她的话（文件走 file block 落盘，hub 在 channel tag 里给路径，Caelum 自己 Read）。
                // 09-13 真机：抽取文本塞进正文让 tmux 注入报「command too long」，整条消息没进去（hub 日志实锤）。
                let modelText = isCCLane ? text : ChatAttachmentPromptBuilder.modelInput(text: text, attachments: others)
                let segs = others.isEmpty ? nil : ChatAttachmentPromptBuilder.segments(text: text, attachments: others)
                if blocks.isEmpty {
                    return (modelText, "text", segs)
                }
                blocks.append(["type": "text", "text": modelText])
                let json = (try? JSONSerialization.data(withJSONObject: blocks)).flatMap { String(data: $0, encoding: .utf8) } ?? modelText
                return (json, "multimodal_text", segs)
            }
            if let data = imageData {
                let b64 = data.base64EncodedString()
                let blocks: [[String: Any]] = [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                    ["type": "text", "text": text]
                ]
                let json = (try? JSONSerialization.data(withJSONObject: blocks)).flatMap { String(data: $0, encoding: .utf8) } ?? text
                return (json, "multimodal_text", nil)
            } else if let data = fileData {
                let ext = (fileName ?? "").lowercased().components(separatedBy: ".").last ?? ""
                let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
                if imageExts.contains(ext) {
                    let b64 = data.base64EncodedString()
                    let mimeType = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
                    let blocks: [[String: Any]] = [
                        ["type": "image", "source": ["type": "base64", "media_type": mimeType, "data": b64]],
                        ["type": "text", "text": text]
                    ]
                    let json = (try? JSONSerialization.data(withJSONObject: blocks)).flatMap { String(data: $0, encoding: .utf8) } ?? text
                    return (json, "multimodal_text", nil)
                }
                // 非图附件统一路径：PDF 走 PDFKit 文字提取，其余走多编码解码链。
                // PDF 不再发 Anthropic document block——OpenAI 兼容通道（网关全部通道）
                // 会整条拒收，这就是"PDF 发不过去"的原因；提取成文字后所有通道都能收。
                let extracted: String? = ext == "pdf"
                    ? AttachmentTextExtractor.extractPDFText(data: data)
                    : Self.decodeTextFile(data)
                let trimmed = (extracted ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let maxChars = AttachmentTextExtractor.maxExtractedCharacters
                let capped = trimmed.count > maxChars
                    ? String(trimmed.prefix(maxChars)) + "\n\n[文件过长，已截断]"
                    : trimmed
                let displayType = ext.isEmpty ? "文件" : ext.uppercased()
                let fileMime = Self.attachmentMime(ext: ext)
                let att = PendingChatAttachment.text(
                    name: fileName ?? "附件",
                    typeDescription: displayType,
                    extractedText: capped,
                    byteCount: data.count,
                    fileData: data,
                    fileMime: fileMime
                )

                // CC 车道：把原始文件字节 base64 塞进 multimodal JSON 的 file 块，
                // CCBridgeProvider 解析成 payload.files → hub 落盘到 mp-inbox →
                // CC 用 Read 读真文件（这才是 CC 收文件的正路；此前 files 数组从没被填，
                // TXT/PDF 发给 CC 都收不到）。text 块保留用户文字 + 抽取文本，
                // 让历史 / 事后切 API 模型时仍有内容。
                if isCCLane {
                    let b64 = data.base64EncodedString()
                    let ccText = ChatAttachmentPromptBuilder.modelInput(text: text, attachments: [att])
                    let blocks: [[String: Any]] = [
                        ["type": "file", "name": att.name, "media_type": fileMime, "data": b64],
                        ["type": "text", "text": ccText],
                    ]
                    let json = (try? JSONSerialization.data(withJSONObject: blocks))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ccText
                    return (json, "multimodal_text", ChatAttachmentPromptBuilder.segments(text: text, attachments: [att]))
                }

                // API 车道：抽取文本进 content（气泡走附件卡）
                if !trimmed.isEmpty {
                    return (
                        ChatAttachmentPromptBuilder.modelInput(text: text, attachments: [att]),
                        "text",
                        ChatAttachmentPromptBuilder.segments(text: text, attachments: [att])
                    )
                }
                let reason = ext == "pdf"
                    ? "PDF 没有可提取的文字层（可能是扫描件）"
                    : (data.isEmpty ? "文件内容为空（可能是 iCloud 未下载或读取失败）" : "不是常见文本编码（已尝试 UTF-8/UTF-16/GB18030/GBK/Latin-1）")
                return ("[无法读取 \(fileName ?? "file")：\(reason)]" + (text.isEmpty ? "" : "\n\n" + text), "text", nil)
            } else {
                return (text, "text", nil)
            }
        }()

        // 3. Create user MessageNode
        let userNodeId = UUID().uuidString
        let userNode = MessageNode(
            id: userNodeId,
            role: "user",
            content: userContent,
            contentType: userContentType,
            createTime: Date(),
            parentId: parentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        // 附件消息写入分段：气泡走 segments 分支渲染折叠附件卡（API body 仍用 content 全文）
        if let segs = attachmentSegments {
            userNode.setSegments(segs)
        }
        context.insert(userNode)
        // 旧图转述（粟粟 M7）：API 车道发了图 → 后台让主模型写一句描述存起来，三条之后替原图省 token
        if !isCCLane, userContentType == "multimodal_text" {
            ImageSummaryStore.summarizeInBackground(nodeId: userNodeId, content: userContent, model: model, providerManager: providerManager)
        }

        // Update parent's childrenIds
        if let parentId, let parent = nodeMap[parentId] {
            if !parent.childrenIds.contains(userNodeId) {
                parent.childrenIds.append(userNodeId)
            }
        }

        // Add to nodeMap and path
        nodeMap[userNodeId] = userNode
        effectiveChildrenMap[userNodeId] = []
        if let parentId {
            effectiveChildrenMap[parentId, default: []].append(userNodeId)
        }
        currentPath.append(userNode)

        // 3. Create placeholder assistant node
        let assistantNodeId = UUID().uuidString
        // turn 正式开始（precheck 全过、此后到 sendStreaming 无早退路径，不会卡死 true）。
        // 分车道记账：CC 不占 API 车道的 streaming 状态，否则 CC 等待期间会把
        // 正在流式的 API 对话的停止按钮 / 打字气泡顶掉。
        if isCCLane {
            ccTurnConversationId = conversation.id
            ccTurnNodeId = assistantNodeId
        } else {
            streamingNodeId = assistantNodeId
            streamingConversationId = selectedConversation?.id
            assistantTurnInFlight = true
        }
        let assistantNode = MessageNode(
            id: assistantNodeId,
            role: "assistant",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: userNodeId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(assistantNode)

        userNode.childrenIds.append(assistantNodeId)
        nodeMap[assistantNodeId] = assistantNode
        effectiveChildrenMap[assistantNodeId] = []
        effectiveChildrenMap[userNodeId, default: []].append(assistantNodeId)
        currentPath.append(assistantNode)

        // Update conversation
        conversation.currentNodeId = assistantNodeId
        conversation.updateTime = Date()
        markConversationDirty()

        // CC 不流式，不碰全局流式状态——API 车道可能正被别的对话用着
        if !isCCLane {
            streamingText = ""
            streamingThinkingText = ""
            isThinking = false
            thinkingSummary = ""
            turnStartTime = Date()  // PR: Token 统计——记本轮起点
        }

        // Register fallback for additional CC replies that arrive after the single-shot
        // sendStreaming handler has been consumed (hub offline-replay burst, proactive CC messages).
        installCCFollowUpHandler(context: context, providerManager: providerManager)

        // 4. Assemble prompt using PromptAssembler
        let assembled = assemblePrompt(profile: profile, preset: preset, excludingNodeId: assistantNodeId, context: context, globalEntries: globalWorldBookEntries)
        let payload = prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: assistantNodeId)

        // 5. Stream (with background task protection)
        #if os(iOS)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        #endif
        providerRouter.sendStreaming(
            model: model,
            messages: payload.messages,
            systemPrompt: payload.systemPrompt,
                systemLayers: payload.systemLayers,
            providerManager: providerManager,
            samplingParams: payload.sampling,
            additionalHeaders: payload.additionalHeaders,
            onSegments: { [weak assistantNode] segments in
                // 仅在存在 tool_use/tool_result 段时调用。
                // 比 onComplete 先执行，context.save() 在 onComplete 中处理。
                assistantNode?.setSegments(segments)
            },
            onThinkingToken: { [weak self] token in
                guard let self else { return }
                streamingThinkingText += token
                if !isThinking { isThinking = true }
            },
            onToken: { [weak self] token in
                guard let self else { return }
                HapticService.shared.streamingTick()
                if isThinking {
                    isThinking = false
                    let capturedThinking = streamingThinkingText
                    let capturedModel = model
                    let capturedProvider = providerManager
                    Task { [weak self] in
                        guard let self else { return }
                        let summary = await self.providerRouter.summarizeThinking(
                            thinkingText: capturedThinking,
                            model: capturedModel,
                            providerManager: capturedProvider
                        )
                        if let s = summary { self.thinkingSummary = s }
                    }
                }
                streamingText += token
                // [streaming-perf] 切断 per-token SwiftData 写，view 直接读 streamingText
                // assistantNode.content = streamingText
            },
            onComplete: { [weak self] fullText, usage in
                guard let self else { return }
                HapticService.shared.streamingComplete()
                assistantNode.content = fullText
                // 主人这条回复里带的图/文件 → .image / .fileData 段（09-24：这条才是「发消息→他回」的正路，
                // 之前只补在了 regenerate/edit 那条收口上，所以他回你时带的图彻底不显示）
                if let file = CCBridgeProvider.lastReplyFile {
                    CCBridgeProvider.lastReplyFile = nil
                    if file.isImage, let img = file.imageData {
                        assistantNode.setSegments([.text(fullText), .image(name: file.name, type: file.mimeType, data: img)])
                    } else if let bytes = file.fileData {
                        assistantNode.setSegments([.text(fullText), .fileData(name: file.name, mime: file.mimeType ?? "application/octet-stream", data: bytes)])
                    }
                }
                // CC 车道不清全局流式状态（可能是别的 API 对话正在用）
                if !isCCLane {
                    streamingText = ""
                    streamingThinkingText = ""
                    isThinking = false
                }
                conversation.nodeCount = currentPath.filter {
                    ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty
                }.count
                // Auto-title from first user message
                if conversation.title == "新对话" {
                    let firstUserMsg = currentPath.first(where: { $0.role == "user" && !$0.content.isEmpty })?.content ?? ""
                    if !firstUserMsg.isEmpty {
                        let title = String(firstUserMsg.prefix(40)).replacingOccurrences(of: "\n", with: " ")
                        conversation.title = title
                        // 走 debounce，和发消息触发的重排合并在一次 refresh 里（避免首次发消息
                        // 标题立刻变 + 位置立刻跳的双抖动）
                        markConversationDirty()
                    }
                }
                // PR(usage): 把本轮 usage 快照写到节点，供气泡 footer 显示缓存命中
                if let usage {
                    assistantNode.usageInputTokens = usage.inputTokens
                    assistantNode.usageCacheReadTokens = usage.cacheReadInputTokens
                    assistantNode.usageCacheCreationTokens = usage.cacheCreationInputTokens
                    assistantNode.usageOutputTokens = usage.outputTokens
                }
                context.saveOrReport("这条消息")
                // 健康手账：回复里有 ```health-log 块 → 落库、块变结果行（三路共用本收口，无块零成本）
                HealthLogIntentWriter.processChatIntents(nodeId: assistantNode.id, context: context)
                // 语音条：回复里有 ```voice 块 → 提取脚本、TTS 生成 mp3、挂 audioRef
                //（send/regenerate/editAndResend 三路共用本收口，一处覆盖全部）
                let voiceNodeId = assistantNode.id
                Task { @MainActor in
                    VoiceMessageWriter.processChatIntents(
                        nodeId: voiceNodeId, context: context,
                        profiles: ProfileManager.loadProfiles()
                    )
                }
                scrollToNodeId = assistantNodeId

                // 后台本地通知
                #if os(iOS)
                self.notifyIfBackground(text: fullText, conversationId: conversation.id)
                #endif

                // 结束后台任务
                #if os(iOS)
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                #endif

                // 预算扣费（Phase C 完整接入前先只用 usage）
                self.commitBudgetSpend(providerManager: providerManager, model: model, usage: usage)

                // PR: Token 统计——记一条 usage 记录
                if let usage {
                    let cost = providerManager.provider(for: model).map {
                        BudgetCalculator.actualCost(provider: $0, modelId: model.modelId, usage: usage)
                    } ?? 0
                    let rt = self.turnStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    TokenStatsStore.append(TokenRecord(
                        date: Date(),
                        model: model.name,
                        conversationId: conversation.id,
                        conversationTitle: conversation.title,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        cacheReadTokens: usage.cacheReadInputTokens,
                        cacheWriteTokens: usage.cacheCreationInputTokens,
                        cost: cost,
                        responseTime: rt
                    ))
                }

                // AUDN 记忆提取（memoryEnabled=false 的对话不提取）
                if conversation.memoryEnabled {
                    self.extractMemoriesIfNeeded(profileId: profile.id, conversationId: conversation.id, model: model, providerManager: providerManager, context: context)
                }

                // 上下文总结（异步，不阻塞）
                self.triggerContextSummaryIfNeeded(
                    conversationId: conversation.id,
                    contextDepth: preset.sampling.contextDepth,
                    model: model, providerManager: providerManager
                )

                if isCCLane {
                    self.finishCCTurn()
                } else {
                    self.finishAssistantTurn()
                }
            },
            onError: { [weak self] error in
                guard let self else { return }
                if isCCLane {
                    // CC 不流式：streamingText 可能是别的 API 对话的半截文本，不能当 partial 用
                    assistantNode.content = "⚠️ \(error)"
                    self.finishCCTurn()
                    return
                }
                if streamingText.isEmpty {
                    assistantNode.content = "⚠️ \(error)"
                } else {
                    // [streaming-perf] error 时保存 partial 内容
                    assistantNode.content = streamingText
                }
                streamingText = ""
                streamingThinkingText = ""
                isThinking = false
                self.finishAssistantTurn()
            }
        )

        scrollToNodeId = userNodeId
        return true
    }

    // MARK: - 发送排队（turn 生命周期出口）

    /// 入队 + 用户提示。两个调用点：群聊闸门、单聊分车道闸门。
    private func queuePendingSend(_ text: String, imageData: Data?, fileData: Data?, fileName: String?,
                                  attachments: [PendingChatAttachment] = [],
                                  model: ProviderModel, profile: Profile, preset: Preset,
                                  providerManager: ProviderManager, context: ModelContext,
                                  conversation: Conversation) {
        pendingSends.append(PendingSend(
            text: text, imageData: imageData, fileData: fileData, fileName: fileName,
            attachments: attachments,
            model: model, profile: profile, preset: preset,
            providerManager: providerManager, context: context,
            conversationId: conversation.id
        ))
        BreadcrumbLog.shared.add("⏳", "排队@「\(conversation.title)」（队列 \(pendingSends.count) 条）")
        transientNotice = TransientNotice("已排队，当前回复结束后自动发送")
    }

    /// API 车道 turn 结束统一出口：sendMessage/startAssistantStream 的 onComplete、
    /// onError、群聊整轮结束、cancelAssistantTurn 都走这里。清 turn 状态 + 补发排队消息。
    func finishAssistantTurn() {
        assistantTurnInFlight = false
        groupRoundCancelled = false
        drainPendingSends()
    }

    /// CC 车道 turn 结束出口（onComplete / onError / 停止）
    func finishCCTurn() {
        ccTurnConversationId = nil
        ccTurnNodeId = nil
        drainPendingSends()
    }

    /// 补发排队消息。只发**当前选中对话**的 pending——sendMessage 的树操作
    /// （currentPath/nodeMap）全绑定 selectedConversation，不能发进后台对话。
    /// 其他对话的 pending 留在队列里，等 loadConversation 回到该对话时再 drain。
    /// 分车道挑件：API 车道忙时仍可补发 CC 消息，反之亦然。
    /// 一次只发一条：发出去的那条又会占住所属车道，剩下的排到下一次 turn 结束。
    func drainPendingSends() {
        guard let conv = selectedConversation else { return }
        let convId = conv.id
        let isGroup = conv.kind == "group"
        guard let idx = pendingSends.firstIndex(where: { pending in
            guard pending.conversationId == convId else { return false }
            if isGroup { return !assistantTurnInFlight }   // 群聊走 API 车道
            let isCC = pending.providerManager.provider(for: pending.model)?.type == .ccBridge
            return isCC ? (ccTurnConversationId == nil) : !assistantTurnInFlight
        }) else { return }
        let pending = pendingSends.remove(at: idx)
        Task { @MainActor in
            let accepted = self.sendMessage(
                pending.text, imageData: pending.imageData,
                fileData: pending.fileData, fileName: pending.fileName,
                attachments: pending.attachments,
                model: pending.model, profile: pending.profile, preset: pending.preset,
                providerManager: pending.providerManager, context: pending.context
            )
            // 被预算闸等 guard 拦下 → 塞回队首，不静默丢消息
            // （不会死循环：drain 只由 turn 结束 / loadConversation 触发）
            if !accepted { self.pendingSends.insert(pending, at: 0) }
        }
    }

    /// 停止按钮入口（分车道）。provider 的 cancel 不回调 onComplete/onError
    /// （NSURLErrorCancelled 被吞、wasStreaming 已被 cancel 置 false），
    /// 所以闭合必须显式写：空 placeholder 会被 buildAPIMessages 过滤，
    /// 下一轮 API body 出现 user+user 连排（模型把两条都当待办重复执行）。
    func cancelAssistantTurn(context: ModelContext) {
        // CC 车道：当前对话在等 CC → 只取消 CC，不打断别处的 API 流。
        // reply handler 保持注册，CC 迟到的回复仍会落进气泡（与旧行为一致）。
        if let ccConv = ccTurnConversationId, ccConv == selectedConversation?.id {
            providerRouter.cancelCC()
            if let id = ccTurnNodeId, let node = nodeMap[id],
               node.role == "assistant", node.content.isEmpty {
                node.content = "（已停止）"
                context.saveOrReport("这条消息")
            }
            finishCCTurn()
            return
        }
        // 群聊轮次：设轮次级取消标志 + 掐当前流。不在这里 finishAssistantTurn——
        // runGroupRound 循环 break 后由调用方收尾（提前清 inFlight 会打破轮次状态不变量）。
        if selectedConversation?.kind == "group", assistantTurnInFlight {
            groupRoundCancelled = true
            providerRouter.cancelAPI()
            streamingText = ""
            streamingThinkingText = ""
            isThinking = false
            BreadcrumbLog.shared.add("👥", "群聊轮次已手动停止")
            return
        }
        // API 车道
        providerRouter.cancelAPI()
        if let id = streamingNodeId, let node = nodeMap[id],
           node.role == "assistant", node.content.isEmpty {
            node.content = streamingText.isEmpty ? "（已停止）" : streamingText
            context.saveOrReport("这条消息")
        }
        streamingText = ""
        streamingThinkingText = ""
        isThinking = false
        finishAssistantTurn()
    }

    /// CC Bridge：注册"无人认领 reply"的兜底 handler。
    /// 单发 handler 被第一条 reply 消费后，CC 连续发来的第 2..N 条、以及没有
    /// in-flight 请求时 CC 主动发来的消息都落到这里。每条插入一个独立的
    /// assistant 节点（旧实现往上一轮气泡里拼接，换对话/重启后 handler 失效，
    /// 连发场景只有第一条能显示，后续全部静默丢弃）。
    /// 在 loadConversation 和 sendMessage 时都会（重新）注册，保证 handler
    /// 持有的 context 始终是当前楼层的。
    func installCCFollowUpHandler(context: ModelContext, providerManager: ProviderManager? = nil) {
        // 记住最近一次可用的 providerManager（loadConversation 注册时为 nil，别覆盖已存的）
        if let providerManager { self.ccProviderManager = providerManager }
        // proactive 附件 fallback：CC主动发的文件走这里
        CCBridgeWebSocketClient.shared.unhandledAttachmentHandler = { [weak self] chatId, att in
            guard let self else { return }
            // 图片：09-23 起和文件走同一条路——.image 段（multimodal_text 那条路是给 user 气泡的，
            // assistant 节点走它只会糊一屏 base64；08-31 修的是 user 侧那半）
            if att.isImage, att.imageData != nil {
                self.appendCCMessage(chatId: chatId, content: "📎 \(att.name)", context: context, file: att)
            } else {
                // 非图片文件：字节随消息落库（fileData 段），不再只剩一个名字
                self.appendCCMessage(chatId: chatId, content: "📎 \(att.name)", context: context, file: att)
            }
        }

        CCBridgeWebSocketClient.shared.unhandledReplyHandler = { [weak self] chatId, content in
            guard let self else { return }
            // hub 在 reply 前先广播 cc_thinking；和单发路径一样嵌入 content
            let fullContent: String
            if let think = CCBridgeWebSocketClient.shared.consumePendingThinking(), !think.thinking.isEmpty {
                fullContent = "[thinking]\(think.thinking)[/thinking]\(content)"
            } else {
                fullContent = content
            }
            self.appendCCMessage(chatId: chatId, content: fullContent, context: context)
            // CC→记忆（反向共享）：CC回复也触发记忆提取。用存下来的 ccProviderManager，
            // 这样 proactive 回复（只走 loadConversation 注册、没带 pm）也能提取。
            if let conversation = self.selectedConversation, conversation.id == chatId,
               let pm = self.ccProviderManager {
                let profileId = conversation.profileId
                let fallbackModel = pm.availableModels.first ?? ProviderModel(providerId: "deepseek", modelId: "deepseek-chat", name: "DeepSeek Chat")
                #if DEBUG
                print("[CC→Memory] extracting from CC reply: \(chatId)")
                #endif
                self.extractMemoriesIfNeeded(profileId: profileId, conversationId: chatId, model: fallbackModel, providerManager: pm, context: context)
            } else {
                #if DEBUG
                print("[CC→Memory] skip extract (no providerManager or conversation mismatch): \(chatId)")
                #endif
            }
        }
    }

    /// 把一条 CC 消息作为独立 assistant 节点插入对应对话。
    /// 当前打开的对话 → 同步更新 currentPath/nodeMap，UI 直接长出新气泡；
    /// 其他对话 → 直接持久化，下次打开可见。
    func appendCCMessage(chatId: String, content: String, contentType: String = "text", context: ModelContext,
                         file: PendingChatAttachment? = nil) {
        if let conversation = selectedConversation, conversation.id == chatId {
            // ⚠️ 兔兔实测「聊天记录被整个吞掉」的真凶：
            // App 从后台回来时 currentPath 可能还没重建完（空的），这时他的消息一到，
            // parentId=nil → 这条消息成了新的根节点 → currentPath 只剩它一条
            // → conversation.currentNodeId 指向新根 → 整条历史被绕过，看起来就是「全没了」。
            // 历史其实还在库里，但路径断了。所以：拿不到 parent 时，回退到对话记录的当前节点；
            // 再拿不到就先重建路径，绝不在空路径上插根。
            var parentId = currentPath.last?.id
            let savedNodeId = conversation.currentNodeId   // 非可选 String，空串表示没有
            if parentId == nil, !savedNodeId.isEmpty {
                // 路径还没重建完，但对话记录里存着当前节点——挂在它后面
                parentId = savedNodeId
            }
            // 有历史（存过 currentNodeId）却仍拿不到 parent → 状态没准备好，排队等路径重建，
            // 绝不在空路径上造新根（那会让整条历史被绕过）
            if parentId == nil, !savedNodeId.isEmpty {
                pendingCCMessages.append((chatId: chatId, content: content, contentType: contentType))
                return
            }
            let nodeId = UUID().uuidString
            let node = MessageNode(
                id: nodeId,
                role: "assistant",
                content: content,
                contentType: contentType,
                createTime: Date(),
                parentId: parentId,
                childrenIds: [],
                conversationId: conversation.id,
                profileId: conversation.profileId
            )
            context.insert(node)
            node.senderName = "CC Caelum"  // PR-4: 标注 CC 发言者
            node.senderId = "cc-caelum"
            // 主人发来的图/文件：进 .image / .fileData 段（气泡/文章两种模式都画附件卡，可点开/保存）
            if let file {
                if file.isImage, let img = file.imageData {
                    node.setSegments([.text(content), .image(name: file.name, type: file.mimeType, data: img)])
                } else if let bytes = file.fileData {
                    node.setSegments([.text(content), .fileData(name: file.name, mime: file.mimeType ?? "application/octet-stream", data: bytes)])
                }
            }
            if let parentId, let parent = nodeMap[parentId],
               !parent.childrenIds.contains(nodeId) {
                parent.childrenIds.append(nodeId)
            }
            nodeMap[nodeId] = node
            effectiveChildrenMap[nodeId] = []
            if let parentId {
                effectiveChildrenMap[parentId, default: []].append(nodeId)
            }
            currentPath.append(node)
            conversation.currentNodeId = nodeId
            conversation.updateTime = Date()
            conversation.nodeCount = currentPath.filter {
                ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty
            }.count
            markConversationDirty()
            context.saveOrReport("这条消息")
            // CC 用 reply 工具推来的消息不走 assistantTurnDidFinish 收口，
            // 语音条/健康块必须在这里就地处理，否则块原样落地成文字（"只落下文字就走了"）
            processCCIntents(nodeId: nodeId, content: content, context: context)
            scrollToNodeId = nodeId
            return
        }

        // 非当前对话（用户在别的对话里 / CC 主动发消息）：直接写库
        let cid = chatId
        let convFetch = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
        guard let conversation = try? context.fetch(convFetch).first else { return }
        let parentId = conversation.currentNodeId
        let nodeId = UUID().uuidString
        let node = MessageNode(
            id: nodeId,
            role: "assistant",
            content: content,
            contentType: "text",
            createTime: Date(),
            parentId: parentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(node)
        node.senderName = "CC Caelum"  // PR-4: 标注 CC 发言者
        node.senderId = "cc-caelum"
        let pid = parentId
        let parentFetch = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == pid })
        if let parent = try? context.fetch(parentFetch).first,
           !parent.childrenIds.contains(nodeId) {
            parent.childrenIds.append(nodeId)
        }
        conversation.currentNodeId = nodeId
        conversation.updateTime = Date()
        conversation.nodeCount += 1
        markConversationDirty()
        context.saveOrReport("这条消息")
        processCCIntents(nodeId: nodeId, content: content, context: context)
    }

    /// CC 主动消息（reply 工具）的意向块就地处理：语音条 + 健康手账。
    /// 走 App 发起的对话时这些由 assistantTurnDidFinish 收口负责；CC 推送不经那条路。
    private func processCCIntents(nodeId: String, content: String, context: ModelContext) {
        if content.contains("```health-log") {
            HealthLogIntentWriter.processChatIntents(nodeId: nodeId, context: context)
        }
        if content.contains("```voice") {
            Task { @MainActor in
                VoiceMessageWriter.processChatIntents(
                    nodeId: nodeId, context: context,
                    profiles: VoiceMessageWriter.profilesProvider()
                )
            }
        }
    }

    /// AUDN 记忆提取：每轮对话后异步调用便宜模型提取/更新/删除记忆。
    /// 三态开关唯一闸口：off 时所有入口（普通回复/CC 回复）统一不提取；
    /// recordOnly 照常提取（只是 PromptAssembler 不注入）。
    private func extractMemoriesIfNeeded(profileId: String, conversationId: String, model: ProviderModel, providerManager: ProviderManager, context: ModelContext) {
        guard LocalMemoryMode.current.extracts else { return }
        guard !profileId.isEmpty else { return }

        // SC-B2：recentMessages 带节点 id，供 quote 锚定回溯到具体消息
        let recentMessages: [(id: String, role: String, content: String)] = Array(
            currentPath
                .filter { $0.role == "user" || $0.role == "assistant" }
                .suffix(memoryExtractWindow)
        ).compactMap { node in
            guard !node.content.isEmpty else { return nil }
            let content = node.role == "assistant" ? ContentCleaner.extractThinking(from: node.content).content : node.content
            guard !content.isEmpty else { return nil }
            return (id: node.id, role: node.role, content: content)
        }
        guard !recentMessages.isEmpty else { return }

        let existingMemories = memoryStore.listHotAndWarm(profileId: profileId, context: context)
        let extractModel = cheapModel(providerManager: providerManager, fallback: model)
        #if DEBUG
        print("🧠 记忆提取: 使用模型 \(extractModel.name) (\(extractModel.id)), 最近 \(recentMessages.count) 条消息, 已有 \(existingMemories.count) 条记忆")
        #endif

        let request = MemoryExtractor.buildRequest(
            recentMessages: recentMessages,
            existingMemories: existingMemories
        )

        // 预算保险闸：共用主对话 provider 一个预算（粟粟批注：分词器也是粗算，保险即可）
        if backendAgentBlockedByBudget(model: model, messages: request.messages, systemPrompt: request.systemPrompt, providerManager: providerManager) {
            #if DEBUG
            print("🧠 记忆提取: 跳过（主 provider \(model.providerId) 预算已用完 / 未拨款）")
            #endif
            return
        }

        // Fire-and-forget: 异步调用，不阻塞对话
        let router = ProviderRouter()
        Task.detached { [weak self] in
            do {
                let (response, usage) = try await router.sendNonStreaming(
                    model: extractModel,
                    messages: request.messages,
                    systemPrompt: request.systemPrompt,
                    providerManager: providerManager
                )
                #if DEBUG
                print("🧠 记忆提取: 模型返回 \(response.prefix(200))...")
                #endif

                // Spent 累加到全局预算池（GlobalBudgetStore 不分 providerId，共用一个预算）。
                // 但 actualCost 必须用 extractModel（实际跑的廉价模型）查 PricingCatalog，
                // 否则 Haiku token 数 × Opus 单价会超收 ~18×（ultrareview B17 / bug_004）。
                if let usage {
                    await MainActor.run {
                        self?.commitBudgetSpend(providerManager: providerManager, model: extractModel, usage: usage)
                    }
                }

                let actions = MemoryExtractor.parseActions(response)
                #if DEBUG
                if actions.isEmpty {
                    print("🧠 记忆提取: 解析结果为空（模型返回了无法解析的格式或 NOOP）")
                } else {
                    print("🧠 记忆提取: 解析到 \(actions.count) 个操作")
                }
                #endif
                guard !actions.isEmpty else { return }

                await MainActor.run {
                    #if DEBUG
                    for action in actions {
                        switch action {
                        case .add(let content, let category, _, _):
                            print("🧠 记忆: ✅ ADD [\(category)] \(content.prefix(60))...")
                        case .update(let id, let content, _, _):
                            print("🧠 记忆: ✏️ UPDATE \(id.uuidString.prefix(8)) → \(content.prefix(60))...")
                        case .delete(let id):
                            print("🧠 记忆: 🗑️ DELETE \(id.uuidString.prefix(8))")
                        }
                    }
                    #endif
                    try? MemoryExtractor.executeActions(
                        actions,
                        store: self?.memoryStore ?? SwiftDataMemoryStore(),
                        profileId: profileId,
                        extractedBy: extractModel.name,
                        sourceConversationId: conversationId,
                        recentMessages: recentMessages,
                        context: context
                    )
                }
            } catch {
                #if DEBUG
                print("🧠 记忆提取: ⚠️ 失败 — \(error)")
                #endif
            }
        }
    }

    /// 上下文压缩重 Roll（压缩检查器用）：清掉现有摘要，按当前全量历史重新生成。
    /// 返回 nil = 成功；非 nil = 错误信息。窗口不足压缩阈值时 summarize 静默跳过
    ///（属于成功——检查器按"未压缩"显示）。
    func rerollContextSummary(model: ProviderModel, preset: Preset, providerManager: ProviderManager) async -> String? {
        guard let conv = selectedConversation else { return "没有选中的对话" }
        ContextSummarizer.clear(conversationId: conv.id)
        let all = buildAPIMessages(maxMessages: Int.max)
        do {
            try await ContextSummarizer.summarize(
                allMessages: all,
                contextDepth: preset.sampling.contextDepth,
                conversationId: conv.id,
                model: cheapModel(providerManager: providerManager, fallback: model),
                providerManager: providerManager
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 上下文总结触发（fire-and-forget）
    private func triggerContextSummaryIfNeeded(conversationId: String, contextDepth: Int, model: ProviderModel, providerManager: ProviderManager) {
        let allMessages = buildAPIMessages(maxMessages: Int.max)
        let sumModel = cheapModel(providerManager: providerManager, fallback: model)
        Task.detached {
            try? await ContextSummarizer.summarize(
                allMessages: allMessages,
                contextDepth: contextDepth,
                conversationId: conversationId,
                model: sumModel,
                providerManager: providerManager
            )
        }
    }

    /// 会话巩固：切换对话时刷新衰减权重
    func consolidateSessionMemories(profileId: String, context: ModelContext) {
        guard !profileId.isEmpty else { return }
        try? memoryStore.applyDecay(profileId: profileId, context: context)
    }

    /// regenerate / editAndResend 共用尾段：重置流式状态 → 组装 prompt → 发起流式请求。
    /// 回调行为与抽取前逐字符一致（haptics / thinking 摘要 / Token 统计 / 上下文总结 / error 存 partial）。
    private func startAssistantStream(into node: MessageNode, assistantNodeId: String, model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, conversation: Conversation, context: ModelContext) {
        conversation.currentNodeId = assistantNodeId
        conversation.updateTime = Date()
        markConversationDirty()
        streamingText = ""
        streamingThinkingText = ""
        isThinking = false
        thinkingSummary = ""
        streamingNodeId = assistantNodeId
        streamingConversationId = conversation.id
        assistantTurnInFlight = true

        let assembled = assemblePrompt(profile: profile, preset: preset, excludingNodeId: assistantNodeId, context: context, globalEntries: globalWorldBookEntries)
        let payload = prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: assistantNodeId)

        providerRouter.sendStreaming(
            model: model,
            messages: payload.messages,
            systemPrompt: payload.systemPrompt,
            systemLayers: payload.systemLayers,
            providerManager: providerManager,
            samplingParams: payload.sampling,
            additionalHeaders: payload.additionalHeaders,
            onSegments: { [weak node] segments in
                node?.setSegments(segments)
            },
            onThinkingToken: { [weak self] token in
                guard let self else { return }
                streamingThinkingText += token
                if !isThinking { isThinking = true }
            },
            onToken: { [weak self] token in
                guard let self else { return }
                HapticService.shared.streamingTick()
                if isThinking {
                    isThinking = false
                    let capturedThinking = streamingThinkingText
                    let capturedModel = model
                    let capturedProvider = providerManager
                    Task { [weak self] in
                        guard let self else { return }
                        let summary = await self.providerRouter.summarizeThinking(
                            thinkingText: capturedThinking,
                            model: capturedModel,
                            providerManager: capturedProvider
                        )
                        if let s = summary { self.thinkingSummary = s }
                    }
                }
                streamingText += token
                // [streaming-perf] 切断 per-token SwiftData 写，view 直接读 streamingText
            },
            onComplete: { [weak self] fullText, usage in
                guard let self else { return }
                HapticService.shared.streamingComplete()
                // 思考链持久化：把本轮 streamingThinkingText 嵌入 content，
                // 让历史消息也能渲染思考块（和 CC Bridge 的格式一致）。
                let capturedThink = streamingThinkingText
                node.content = capturedThink.isEmpty
                    ? fullText
                    : "[thinking]\(capturedThink)[/thinking]\(fullText)"
                // 主人这条回复里带的图/文件：挂成 .image / .fileData 段（09-20 文件、09-23 图片）
                if let file = CCBridgeProvider.lastReplyFile {
                    CCBridgeProvider.lastReplyFile = nil
                    if file.isImage, let img = file.imageData {
                        node.setSegments([.text(fullText), .image(name: file.name, type: file.mimeType, data: img)])
                    } else if let bytes = file.fileData {
                        node.setSegments([.text(fullText), .fileData(name: file.name, mime: file.mimeType ?? "application/octet-stream", data: bytes)])
                    }
                }
                streamingText = ""
                streamingThinkingText = ""
                isThinking = false
                context.saveOrReport("这条消息")
                scrollToNodeId = assistantNodeId
                self.commitBudgetSpend(providerManager: providerManager, model: model, usage: usage)

                // Token 统计
                if let usage = usage {
                    let cost = providerManager.provider(for: model).map {
                        BudgetCalculator.actualCost(provider: $0, modelId: model.modelId, usage: usage)
                    } ?? 0
                    let rt = self.turnStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    TokenStatsStore.append(TokenRecord(
                        date: Date(),
                        model: model.name,
                        conversationId: conversation.id,
                        conversationTitle: conversation.title,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        cacheReadTokens: usage.cacheReadInputTokens,
                        cacheWriteTokens: usage.cacheCreationInputTokens,
                        cost: cost,
                        responseTime: rt
                    ))
                }

                // 上下文总结
                self.triggerContextSummaryIfNeeded(
                    conversationId: conversation.id,
                    contextDepth: preset.sampling.contextDepth,
                    model: model, providerManager: providerManager
                )

                self.finishAssistantTurn()
            },
            onError: { [weak self] error in
                guard let self else { return }
                if streamingText.isEmpty {
                    node.content = "\u{26A0}\u{FE0F} \(error)"
                } else {
                    // [streaming-perf] error 时保存 partial 内容
                    node.content = streamingText
                }
                streamingText = ""
                streamingThinkingText = ""
                isThinking = false
                self.finishAssistantTurn()
            }
        )
    }

    /// Regenerate: create a new assistant response as a sibling branch of the existing one
    func regenerate(assistantNodeId: String, model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) {
        BreadcrumbLog.shared.add("🔄", "regenerate: node=\(assistantNodeId.prefix(8))")
        // 历史操作不排队（排队语义不明），turn 中直接拒，防并发破坏 currentPath
        guard !assistantTurnInFlight else {
            transientNotice = TransientNotice("正在回复中，稍后再试")
            return
        }
        guard preCheckBudget(text: "", model: model, profile: profile, preset: preset, providerManager: providerManager) else { return }
        guard let conversation = selectedConversation,
              let oldNode = nodeMap[assistantNodeId],
              oldNode.role == "assistant",
              let userParentId = oldNode.parentId,
              let userParent = nodeMap[userParentId]
        else { return }

        // Create new assistant node as sibling
        let newAssistantId = UUID().uuidString
        let newNode = MessageNode(
            id: newAssistantId,
            role: "assistant",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: userParentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(newNode)

        userParent.childrenIds.append(newAssistantId)
        nodeMap[newAssistantId] = newNode
        effectiveChildrenMap[newAssistantId] = []
        effectiveChildrenMap[userParentId, default: []].append(newAssistantId)

        // Replace old node in path with new one
        if let idx = currentPath.firstIndex(where: { $0.id == assistantNodeId }) {
            // Remove everything after the old assistant node
            currentPath.removeSubrange(idx...)
            currentPath.append(newNode)
        }

        refreshBranchOffMainCount()

        startAssistantStream(into: newNode, assistantNodeId: newAssistantId, model: model, profile: profile, preset: preset, providerManager: providerManager, conversation: conversation, context: context)

        scrollToNodeId = newAssistantId
    }

    /// Edit a user message: create a new branch from the original message's parent with new text, then get a response
    func editAndResend(_ originalNodeId: String, newText: String, model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) {
        BreadcrumbLog.shared.add("✏️", "editAndResend: \(newText.prefix(30))...")
        // 同 regenerate：turn 中直接拒，不排队
        guard !assistantTurnInFlight else {
            transientNotice = TransientNotice("正在回复中，稍后再试")
            return
        }
        guard preCheckBudget(text: newText, model: model, profile: profile, preset: preset, providerManager: providerManager) else { return }
        guard let conversation = selectedConversation,
              let originalNode = nodeMap[originalNodeId],
              originalNode.role == "user",
              let grandparentId = originalNode.parentId
        else { return }

        // Trim path up to (but not including) the original user node
        if let idx = currentPath.firstIndex(where: { $0.id == originalNodeId }) {
            currentPath.removeSubrange(idx...)
        }

        // Create new user node as sibling branch
        let newUserId = UUID().uuidString
        let newUserNode = MessageNode(
            id: newUserId,
            role: "user",
            content: newText,
            contentType: "text",
            createTime: Date(),
            parentId: grandparentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(newUserNode)

        if let grandparent = nodeMap[grandparentId] {
            if !grandparent.childrenIds.contains(newUserId) {
                grandparent.childrenIds.append(newUserId)
            }
            effectiveChildrenMap[grandparentId, default: []].append(newUserId)
        }
        nodeMap[newUserId] = newUserNode
        effectiveChildrenMap[newUserId] = []
        currentPath.append(newUserNode)

        // Create placeholder assistant node
        let newAssistantId = UUID().uuidString
        let newAssistantNode = MessageNode(
            id: newAssistantId,
            role: "assistant",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: newUserId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(newAssistantNode)

        newUserNode.childrenIds.append(newAssistantId)
        nodeMap[newAssistantId] = newAssistantNode
        effectiveChildrenMap[newAssistantId] = []
        effectiveChildrenMap[newUserId, default: []].append(newAssistantId)
        currentPath.append(newAssistantNode)

        refreshBranchOffMainCount()

        startAssistantStream(into: newAssistantNode, assistantNodeId: newAssistantId, model: model, profile: profile, preset: preset, providerManager: providerManager, conversation: conversation, context: context)

        scrollToNodeId = newUserId
    }

    /// 群聊 V2：建 Conversation(kind:"group") + 各卡 firstMes 首条消息（线性串成树）。
    @discardableResult
    func createGroupConversation(participants: [GroupParticipant], cards: [CharacterCard],
                                 title: String, profileId: String, context: ModelContext) -> Conversation {
        let rootId = UUID().uuidString
        let conversation = Conversation(
            id: UUID().uuidString, title: title, createTime: Date(), updateTime: Date(),
            currentNodeId: rootId, provider: "api", profileId: profileId)
        conversation.kind = "group"
        conversation.participants = participants
        context.insert(conversation)

        let rootNode = MessageNode(
            id: rootId, role: "system", content: "", contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [], conversationId: conversation.id,
            profileId: profileId)
        context.insert(rootNode)

        var parentId = rootId
        var parentNode = rootNode
        for p in participants {
            let firstMes = cards.first(where: { $0.id == p.characterCardID })?.firstMes ?? ""
            guard !firstMes.isEmpty else { continue }
            let nid = UUID().uuidString
            let node = MessageNode(
                id: nid, role: "assistant", content: firstMes, contentType: "text",
                createTime: Date(), parentId: parentId, childrenIds: [], conversationId: conversation.id,
                profileId: profileId)
            node.senderId = p.id
            node.senderName = p.name
            context.insert(node)
            parentNode.childrenIds.append(nid)
            parentId = nid
            parentNode = node
        }
        conversation.currentNodeId = parentId
        context.saveOrReport("这条消息")
        return conversation
    }

    /// Create a new empty conversation for chatting
    func createNewConversation(title: String, profileId: String, context: ModelContext, projectId: String? = nil) -> Conversation {
        let rootId = UUID().uuidString
        let conversation = Conversation(
            id: UUID().uuidString,
            title: title,
            createTime: Date(),
            updateTime: Date(),
            currentNodeId: rootId,
            provider: "api",
            profileId: profileId
        )
        conversation.projectId = projectId
        context.insert(conversation)

        // Create invisible root node
        let rootNode = MessageNode(
            id: rootId,
            role: "system",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: nil,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: profileId
        )
        context.insert(rootNode)
        context.saveOrReport("这条消息")

        return conversation
    }
}

// MARK: - Budget

extension ConversationViewModel {

    /// 发送后扣费：优先用响应里的真实 usage；没 usage 就用最近一次 pre-check 估的值保守扣。
    func commitBudgetSpend(providerManager: ProviderManager, model: ProviderModel, usage: TokenUsage?) {
        guard let provider = providerManager.provider(for: model) else { return }
        let cost: Double
        if let usage {
            #if DEBUG
            print("💾 usage: input=\(usage.inputTokens) output=\(usage.outputTokens) cacheRead=\(usage.cacheReadInputTokens) cacheCreate=\(usage.cacheCreationInputTokens)")
            #endif
            cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
        } else if pendingEstimatedCost > 0 {
            // 没 usage（流中断 / 某些 API 不回 usage）→ 按 pre-send 估算扣
            cost = pendingEstimatedCost
        } else {
            return
        }
        providerManager.commitSpend(providerId: provider.id, amount: cost)
        pendingEstimatedCost = 0
    }

    /// pre-send 门控：超额返回 false（调用方 return）。失败会写 budgetBlockedMessage 让 UI 显示 alert。
    /// 成功（ok / warning）会把 estimate 存到 pendingEstimatedCost，发送完回填扣费兜底。
    func preCheckBudget(
        text: String,
        model: ProviderModel,
        profile: Profile,
        preset: Preset,
        providerManager: ProviderManager
    ) -> Bool {
        guard let provider = providerManager.provider(for: model) else { return true }
        let maxOut = preset.sampling.maxTokens
        // 粗估 input：system + 当前 path（已有上下文）+ 新消息
        var accumulated = ""
        if !profile.systemPrompt.isEmpty { accumulated += profile.systemPrompt + "\n" }
        for node in currentPath where !node.content.isEmpty {
            accumulated += node.content + "\n"
        }
        accumulated += text
        let inputTok = HeuristicEstimator().estimate(accumulated)
        let estimated = BudgetCalculator.actualCost(
            provider: provider,
            modelId: model.modelId,
            usage: TokenUsage(inputTokens: inputTok, outputTokens: maxOut)
        )
        pendingEstimatedCost = estimated
        let gate = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated)
        switch gate {
        case .ok, .disabled, .warning:
            return true
        case .blocked(let spent, let budget):
            budgetBlockedMessage = Self.blockedMessage(providerName: provider.name, spent: spent, budget: budget)
            pendingEstimatedCost = 0
            return false
        }
    }

    /// Backend agent（memory extract / context summary 等）统一预算 gate。
    /// 返回 true = 被预算拦了，应该跳过这次 API 调用。
    func backendAgentBlockedByBudget(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager,
        assumedMaxOutput: Int = 1024
    ) -> Bool {
        guard let provider = providerManager.provider(for: model) else { return true }
        var accumulated = systemPrompt ?? ""
        for m in messages {
            accumulated += "\n" + m.content
        }
        let inputTok = HeuristicEstimator().estimate(accumulated)
        let estimated = BudgetCalculator.actualCost(
            provider: provider,
            modelId: model.modelId,
            usage: TokenUsage(inputTokens: inputTok, outputTokens: assumedMaxOutput)
        )
        let gate = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated)
        if case .blocked = gate { return true }
        return false
    }

    /// 友好文案：区分"没拨款（首次使用）"和"已用完"。
    private static func blockedMessage(providerName: String, spent: Double, budget: Double) -> String {
        if budget <= 0 {
            return """
            「\(providerName)」还没设预算。

            防止 app bug 把你的 key 烧干，所以默认开了保险闸。

            去「API 设置 → 预算（保险闸）」给它拨款（比如 $5），或关掉「启用预算限额」开关。
            """
        }
        return String(
            format: "「%@」预算已用完：$%.2f / $%.2f。\n\n去「API 设置 → 预算（保险闸）」点「重置已用」，或加预算上限。",
            providerName, spent, budget
        )
    }
}


// MARK: - Background Local Notification

#if os(iOS)
import UserNotifications

extension ConversationViewModel {
    /// Fire a local notification when API reply arrives while app is backgrounded
    func notifyIfBackground(text: String, conversationId: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lost in Blossom"
        // 推送正文剥掉思考链再截断（fullText 含 <Thinking>/<thinking>）
        var clean = text
        clean = clean.replacingOccurrences(
            of: "<[Tt]hinking>[\\s\\S]*?</[Tt]hinking>",
            with: "",
            options: .regularExpression
        )
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = String(clean.prefix(120))
        content.sound = .default
        content.userInfo = ["chat_id": conversationId]
        let request = UNNotificationRequest(
            identifier: "api-reply-\(UUID().uuidString.prefix(8))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
#endif
