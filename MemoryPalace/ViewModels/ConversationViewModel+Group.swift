import Foundation
import SwiftData

// MARK: - 群聊 V5（选人 + 串行 + 镜像 + 互感）

extension ConversationViewModel {

    /// 群聊一轮：用户发消息 → LLM 选人 → 选中者发言 → 再选 → 直到没人想说或达到上限。
    @MainActor
    func runGroupRound(
        conversation: Conversation,
        userText: String,
        participants: [GroupParticipant],
        providerManager: ProviderManager,
        context: ModelContext
    ) async {
        let userName = UserDefaults.standard.string(forKey: "userName") ?? "我"
        // 链深上限（学粟粟 Agora 的 maxChainDepth，语义比「每轮最多 N 条」准）：
        // 兔兔说话 = 深度 0；因兔兔而说 = 1；AI 因 AI 而说 = 逐级 +1，到顶自动断。
        // 可调（设置-群聊「一轮最多接几手」），缺省 3。
        let maxChainDepth = max(1, UserDefaults.standard.integer(forKey: "groupMaxChainDepth") == 0
                                ? 3 : UserDefaults.standard.integer(forKey: "groupMaxChainDepth"))
        print("[GroupV5] ═══ 新一轮 ═══ 用户: \(userText.prefix(50))... 参与者: \(participants.map(\.name))")

        BreadcrumbLog.shared.add("👥", "群聊: \(userText.prefix(30))...")

        // 1. 用户消息入树
        insertGroupNode(role: "user", content: userText,
                        senderId: nil, senderName: userName,
                        conversation: conversation, context: context)

        // 1.5 开轮落库（V6 刀1）：轮次成为实体，中断/停止/抢权都有据可查
        let convId = conversation.id
        // 兔兔又说话了 → 上一轮作废（她的新消息抢权，学粟粟 owner supersede）
        let runningDesc = FetchDescriptor<GroupTurn>(
            predicate: #Predicate<GroupTurn> { $0.conversationId == convId && $0.state == "running" })
        for stale in (try? context.fetch(runningDesc)) ?? [] {
            stale.state = "superseded"
            stale.endedAt = Date()
        }
        let turn = GroupTurn(
            conversationId: convId,
            profileId: conversation.profileId,
            triggerNodeId: currentPath.last?.id ?? "",
            maxChainDepth: maxChainDepth,
            speechMode: UserDefaults.standard.string(forKey: "groupSpeechMode") ?? "relay"
        )
        context.insert(turn)
        try? context.save()

        let cardManager = CharacterCardManager()
        let presetManager = PresetManager()

        // 2. 选人→说话 循环
        var lastSpeakerId: String? = nil
        var repliesThisRound = 0

        while repliesThisRound < maxChainDepth {
            // 手动停止（⋯ 菜单）→ 整轮刹车。V6：内存布尔仍保留（即时性），
            // 同时把停止写进轮次实体——重进 App 也知道这轮是「被停的」而不是「没说完」
            if groupRoundCancelled {
                print("[GroupV6] 🛑 轮次被手动停止")
                turn.state = "cancelled"
                turn.endedAt = Date()
                try? context.save()
                break
            }
            // 别的轮次抢了权（兔兔插话开了新轮）→ 本轮退场
            if turn.state != "running" {
                print("[GroupV6] 轮次被 \(turn.state)，退出")
                break
            }
            // Owner 抢权（学粟粟：她一发言，房间里排队的深链 mention 全 fail）。
            // 我们这边等价语义：兔兔插话 → 链深归零、lastSpeaker 清空，成员**围绕她的新
            // 消息**重选重说；已经在生成的那条让它说完（不打断已开口的人）。
            if groupInterjectionPending {
                groupInterjectionPending = false
                repliesThisRound = 0
                lastSpeakerId = nil
                print("[GroupV5] 💬 兔兔插话 → 抢权：链深归零，围绕新消息重选")
            }
            let history = groupHistoryItems()

            // 选人
            let speaker = await GroupChatScheduler.selectNextSpeaker(
                participants: participants,
                history: history,
                lastSpeakerId: lastSpeakerId,
                providerManager: providerManager
            )

            guard let speaker else {
                print("[GroupV6] 选人返回 nil，本轮结束")
                break
            }

            // V6 刀2：发言权落库。谁欠一句话从此可查——模型报错不再静默消失。
            // reason：被兔兔显式 @ = mentioned；选人选中 = selected。
            let mentionedByUser = GroupChatScheduler.extractMentions(
                from: userText, participants: participants).contains { $0.id == speaker.id }
            let claim = SpeakClaim(
                turnId: turn.id,
                conversationId: convId,
                participantId: speaker.id,
                participantName: speaker.name,
                reason: repliesThisRound == 0 && mentionedByUser ? "mentioned" : "selected"
            )
            context.insert(claim)
            try? context.save()

            // 解析模型
            guard let model = providerManager.model(byId: speaker.model) else {
                // 失败带原因落 claim（UI 显示「XX 没说上话（模型未找到）」），
                // 不再往对话里插一条假装是他说的 ⚠️ 泡
                print("[GroupV6] ❌ \(speaker.name): 模型 '\(speaker.model)' 找不到")
                claim.state = "failed"
                claim.failureNote = "模型 \(speaker.model) 未找到"
                claim.finishedAt = Date()
                try? context.save()
                repliesThisRound += 1
                continue
            }

            // 说话
            claim.state = "speaking"
            try? context.save()
            print("[GroupV6] \(speaker.name): 开始发言 (#\(repliesThisRound + 1))")
            let mode = GroupChatScheduler.speechMode
            let allowPass = (mode == "free" && claim.reason != "mentioned")
            await groupSpeak(
                allowPass: allowPass,
                participant: speaker,
                allParticipants: participants,
                userName: userName,
                card: cardManager.cards.first { $0.id == speaker.characterCardID },
                preset: presetManager.preset(byId: speaker.presetId),
                conversation: conversation,
                model: model,
                providerManager: providerManager,
                context: context
            )
            // 收尾：说出来了就 done（挂上那条消息节点）；一个字都没有 = 失败带因
            // 0910：脚手架泄漏兜底——落库前清洗（真凶已在 gateway/claude-p 修，这是第二道锁）
            if let node = currentPath.last, node.senderId == speaker.id {
                let cleaned = GroupChatScheduler.sanitizeGroupReply(node.content)
                if cleaned != node.content {
                    print("[GroupV6] 🧹 清掉脚手架泄漏 \(node.content.count) → \(cleaned.count)")
                    node.content = cleaned
                    try? context.save()
                }
            }
            let spoken = currentPath.last
            let raw = (spoken?.senderId == speaker.id ? spoken?.content : nil) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 自由档沉默：回 PASS = 他选择不插话——撤掉这条、无痕、不计链深
            let isPass = allowPass && (trimmed.uppercased() == "PASS"
                                       || trimmed.uppercased() == "PASS。"
                                       || trimmed.uppercased() == "PASS.")
            if isPass, let node = spoken {
                node.isTrashed = true
                currentPath.removeAll { $0.id == node.id }
                claim.state = "passed"
                claim.finishedAt = Date()
                try? context.save()
                print("[GroupV6] \(speaker.name): 选择沉默（PASS）")
                lastSpeakerId = speaker.id
                continue        // 不计链深，让下一位有机会
            }
            if !trimmed.isEmpty, let spoken {
                claim.state = "done"
                claim.resultNodeId = spoken.id
            } else {
                claim.state = "failed"
                claim.failureNote = claim.failureNote ?? "没有返回内容"
            }
            claim.finishedAt = Date()
            try? context.save()
            print("[GroupV6] \(speaker.name): 发言完成(\(claim.state))")

            lastSpeakerId = speaker.id
            repliesThisRound += 1
            turn.chainDepth = repliesThisRound
            try? context.save()

            // 最小发言间隔（房间级节奏，学粟粟 min_speak_interval）：
            // 刚有人说过就先别急着接——治「几个角色瞬间刷屏」。被兔兔直接 @ 的豁免。
            let gap = UserDefaults.standard.integer(forKey: "groupMinSpeakIntervalSec")
            if gap > 0 { try? await Task.sleep(for: .seconds(Double(gap))) }

            // mention_only 档：只认兔兔消息里的 @，AI 之间不接力 → 说完这手就收
            if mode == "mention_only" {
                print("[GroupV6] 仅@档：不接力，本轮收")
                break
            }
            // 检查 AI 回复里有没有 @ 提及（自动追加一轮给被提及的人）
            let latestHistory = groupHistoryItems()
            if let lastMsg = latestHistory.last,
               lastMsg.senderId == speaker.id {
                let mentions = GroupChatScheduler.extractMentions(
                    from: lastMsg.content, participants: participants)
                if !mentions.isEmpty && repliesThisRound < maxChainDepth {
                    print("[GroupV5] \(speaker.name) @提及了 \(mentions.map(\.name))，追加一轮")
                    // 下一轮选人会自动命中被 @ 的角色
                }
            }
        }

        groupInterjectionPending = false
        if turn.state == "running" {
            turn.state = "done"
            turn.endedAt = Date()
            try? context.save()
        }
        print("[GroupV6] ═══ 轮次结束(\(turn.state)) ═══ 共 \(repliesThisRound) 条回复")
    }

    /// G3 长按定向回应：指定某个成员接当前话茬（不选人，直接说）。
    @MainActor
    func groupRequestReply(
        participantId: String,
        providerManager: ProviderManager,
        context: ModelContext
    ) {
        guard let conversation = selectedConversation, conversation.kind == "group" else { return }
        guard !assistantTurnInFlight else { return }  // 轮次在跑就忽略，别打架
        let participants = conversation.participants
        guard let speaker = participants.first(where: { $0.id == participantId }),
              let model = providerManager.model(byId: speaker.model) else { return }
        assistantTurnInFlight = true
        streamingConversationId = conversation.id
        BreadcrumbLog.shared.add("👥", "定向接话: \(speaker.name)")
        Task { @MainActor in
            let cardManager = CharacterCardManager()
            let presetManager = PresetManager()
            await self.groupSpeak(
                participant: speaker,
                allParticipants: participants,
                userName: UserDefaults.standard.string(forKey: "userName") ?? "我",
                card: cardManager.cards.first { $0.id == speaker.characterCardID },
                preset: presetManager.preset(byId: speaker.presetId),
                conversation: conversation,
                model: model,
                providerManager: providerManager,
                context: context
            )
            self.finishAssistantTurn()
        }
    }

    /// 单个角色发言。
    @MainActor
    private func groupSpeak(
        allowPass: Bool = false,
        participant: GroupParticipant,
        allParticipants: [GroupParticipant],
        userName: String,
        card: CharacterCard?,
        preset: Preset?,
        conversation: Conversation,
        model: ProviderModel,
        providerManager: ProviderManager,
        context: ModelContext
    ) async {
        // 组装增强版 system prompt（含成员列表）
        let systemPrompt = GroupChatScheduler.buildSystemPrompt(
            for: participant, allParticipants: allParticipants,
            userName: userName, card: card, preset: preset, allowPass: allowPass
        )

        // 车道判定：CC 天生只读消息正文、丢弃 systemPrompt，且需要路由头才发得回。
        let isCC = providerManager.provider(for: model)?.type == .ccBridge

        let messages: [(role: String, content: String)]
        var headers: [String: String] = [:]
        if isCC {
            // CC 读不到 system → 把群规则+成员+角色设定拼进正文；最近对话走 X-MP-Context。
            let ctx = ccGroupContext(userName: userName)
            let ccContent = systemPrompt +
                "\n\n（接着群里最近的对话，以「\(participant.name)」的身份自然说 1-3 句，" +
                "不要加名字前缀；想叫谁接话可以 @名字。如果确实没话可说就只回复「（沉默）」。）"
            messages = [(role: "user", content: ccContent)]
            // 复用正在跑的那个 CC 会话（不设自定义 session_name——群里给每个角色单开 tmux
            // 需要每个都有 claude 进程在跑，兔兔没配；靠正文注入的人设区分角色即可）。
            // chatId 带 participant 后缀让回复路由回本角色、多个 CC 角色互不串台。
            headers = [
                "X-MP-ChatId": "\(conversation.id)__\(participant.id)",
                "X-MP-User": userName,
            ]
            if !ctx.isEmpty { headers["X-MP-Context"] = ctx }
        } else {
            // 镜像 prompt（含角色关系）
            messages = GroupChatScheduler.buildMirrorMessages(
                for: participant, history: groupHistoryItems(),
                participants: allParticipants
            )
        }

        guard !messages.isEmpty else {
            print("[GroupV5] ⚠️ \(participant.name): messages 为空，跳过")
            return
        }

        // 创建 assistant node
        let node = insertGroupNode(
            role: "assistant", content: "",
            senderId: participant.id, senderName: participant.name,
            conversation: conversation, context: context
        )
        if isCC { headers["X-MP-MessageId"] = node.id }
        // 让气泡在流式期间显示实时文本：判定是 streamingNodeId == node.id，
        // 群聊之前没设它 → 整段流式都是空气泡，直到 onComplete 才一次性冒出来。
        // 0913「串台」另一半：streamingNodeId/streamingText 是全局的，她切到别的对话后
        // 仍在写 → 群聊的流式泡出现在主人的聊天页。只在还看着这个群时才挂。
        if selectedConversation?.id == conversation.id {
            streamingNodeId = node.id
        }

        // 流式调用
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            var accumulated = ""
            let resume = {
                if !finished { finished = true; cont.resume() }
            }

            providerRouter.sendStreaming(
                model: model,
                messages: messages,
                systemPrompt: isCC ? nil : systemPrompt,
                providerManager: providerManager,
                samplingParams: SamplingParams(temperature: 0.8, maxTokens: 2000),
                additionalHeaders: headers,
                onToken: { [weak self] token in
                    guard let self else { return }
                    accumulated += token
                    // 切走了就别再往全局流式态写（那会显示在她当前看的那个对话里）
                    if self.selectedConversation?.id == conversation.id {
                        self.streamingText = accumulated
                    }
                    // 不做 per-token SwiftData 写（V5 流式优化）
                },
                onComplete: { [weak self] fullText, usage in
                    guard let self else { resume(); return }
                    // 空回 / 显式沉默 → 删节点，不留空气泡（Bug1：system 允许沉默，
                    // 模型真返回空/「（沉默）」时旧代码照样插空气泡）。
                    let clean = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty || clean == "（沉默）" || clean == "(沉默)" {
                        self.removeGroupNode(node, conversation: conversation, context: context)
                        resume()
                        return
                    }
                    node.content = fullText
                    try? context.save()
                    // Token 统计
                    if let usage {
                        let cost = providerManager.provider(for: model).map {
                            BudgetCalculator.actualCost(provider: $0, modelId: model.modelId, usage: usage)
                        } ?? 0
                        TokenStatsStore.append(TokenRecord(
                            date: Date(), model: model.name,
                            conversationId: conversation.id,
                            conversationTitle: conversation.title,
                            inputTokens: usage.inputTokens,
                            outputTokens: usage.outputTokens,
                            cacheReadTokens: usage.cacheReadInputTokens,
                            cacheWriteTokens: usage.cacheCreationInputTokens,
                            cost: cost, responseTime: 0
                        ))
                    }
                    resume()
                },
                onError: { [weak self] error in
                    guard let self else { resume(); return }
                    if accumulated.isEmpty {
                        // 无内容的失败也删节点，避免一排 "⚠️" 占屏（CC 60s 超时最常见）
                        self.removeGroupNode(node, conversation: conversation, context: context)
                        print("[GroupV5] ⚠️ \(participant.name) 失败/超时，丢弃空节点: \(error)")
                    } else {
                        node.content = accumulated
                        try? context.save()
                    }
                    resume()
                }
            )
        }

        streamingText = ""
        streamingNodeId = nil
    }

    /// CC 群聊上下文：最近若干条群消息格式化成 `[名字]: 内容`（CC 读不到 messages 历史，靠这个）。
    private func ccGroupContext(userName: String) -> String {
        groupHistoryItems().suffix(12).compactMap { m -> String? in
            guard !m.content.isEmpty else { return nil }
            let name = m.senderName ?? (m.role == "user" ? userName : "某角色")
            let clean = ContentCleaner.extractThinking(from: m.content).content
            return "[\(name)]: \(clean)"
        }.joined(separator: "\n")
    }

    /// 删掉一个刚插入但内容为空的群节点（Bug1）。从 path/map/父子关系里摘除并回退 currentNodeId。
    func removeGroupNode(_ node: MessageNode, conversation: Conversation, context: ModelContext) {
        let nodeId = node.id
        let parentId = node.parentId
        currentPath.removeAll { $0.id == nodeId }
        nodeMap[nodeId] = nil
        effectiveChildrenMap[nodeId] = nil
        if let parentId {
            nodeMap[parentId]?.childrenIds.removeAll { $0 == nodeId }
            effectiveChildrenMap[parentId]?.removeAll { $0 == nodeId }
            conversation.currentNodeId = parentId
        }
        context.delete(node)
        try? context.save()
    }

    // MARK: - 工具函数

    /// 提取群聊历史为 HistoryItem 数组。
    func groupHistoryItems() -> [GroupChatScheduler.HistoryItem] {
        currentPath.map { node in
            // 剥离思考链再喂历史——跟单聊一致（ConversationViewModel+Chat 里 assistant
            // 历史走 extractThinking）。否则每个角色都会看到别人拖着的整段思考链，被污染
            // 后顺着编上下文 / 产生幻觉，不像在群里对话。
            let content = node.role == "assistant"
                ? ContentCleaner.extractThinking(from: node.content).content
                : node.content
            return GroupChatScheduler.HistoryItem(
                role: node.role,
                senderId: node.senderId,
                senderName: node.senderName,
                content: content
            )
        }
    }

    /// 群聊消息入树（复用 MessageNode 基建）。
    @MainActor
    @discardableResult
    func insertGroupNode(
        role: String,
        content: String,
        senderId: String?,
        senderName: String?,
        conversation: Conversation,
        context: ModelContext
    ) -> MessageNode {
        let nodeId = UUID().uuidString
        // 兔兔 0913 报「夺舍」：角色正在说话时切到别的对话，群聊消息会落进新对话、
        // 群聊内容被覆盖。真凶就在这行——父节点取 currentPath.last，而 currentPath
        // 在她切对话的那一刻已经换成**另一个对话**的路径了，于是新消息认了别人的爹、
        // 又改写了那个对话的 currentNodeId，两边同时错乱。
        // 修：父节点以**这一轮所属的对话**为准（它自己的 currentNodeId），
        // 与当前在看哪个对话彻底脱钩；UI 状态只在「还在看这个群」时才同步。
        let isStillViewing = (selectedConversation?.id == conversation.id)
        let parentId: String? = isStillViewing
            ? currentPath.last?.id
            : (conversation.currentNodeId.isEmpty ? nil : conversation.currentNodeId)

        let node = MessageNode(
            id: nodeId,
            role: role,
            content: content,
            contentType: "text",
            createTime: Date(),
            parentId: parentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        node.senderId = senderId
        node.senderName = senderName
        context.insert(node)

        if let parentId {
            if isStillViewing, let parent = nodeMap[parentId] {
                parent.childrenIds.append(nodeId)
                effectiveChildrenMap[parentId, default: []].append(nodeId)
            } else {
                // 不在看这个群：nodeMap 装的是别人的树，绝不能碰——直接查库挂爹
                let pid = conversation.profileId
                let desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.id == parentId && $0.profileId == pid })
                if let parent = try? context.fetch(desc).first, !parent.childrenIds.contains(nodeId) {
                    parent.childrenIds.append(nodeId)
                }
            }
        }
        if isStillViewing {
            nodeMap[nodeId] = node
            effectiveChildrenMap[nodeId] = []
            currentPath.append(node)
        }

        conversation.currentNodeId = nodeId
        conversation.updateTime = Date()
        markConversationDirty()
        try? context.save()

        return node
    }
}


// MARK: - V6 轮次善后

extension ConversationViewModel {
    /// App 冷启动/切回时扫描：还挂着 running 但早就没人跑的轮次 = 上次被中断
    /// （App 被杀/崩溃/退后台）。标 interrupted，UI 可据此提示「上次没说完」。
    @MainActor
    static func reconcileStaleGroupTurns(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-180)
        let desc = FetchDescriptor<GroupTurn>(
            predicate: #Predicate<GroupTurn> { $0.state == "running" && $0.startedAt < cutoff })
        guard let stale = try? context.fetch(desc), !stale.isEmpty else { return }
        for t in stale {
            t.state = "interrupted"
            t.endedAt = Date()
            // 这轮里还挂着的发言权一并收尾，免得永远 pending
            let tid = t.id
            let claims = FetchDescriptor<SpeakClaim>(
                predicate: #Predicate<SpeakClaim> { $0.turnId == tid && ($0.state == "pending" || $0.state == "speaking") })
            for c in (try? context.fetch(claims)) ?? [] {
                c.state = "failed"
                c.failureNote = "App 中断"
                c.finishedAt = Date()
            }
        }
        try? context.save()
        print("[GroupV6] 收尾中断轮次 \(stale.count) 条")
    }
}


// MARK: - 冷场破冰（V6 追加，0910）

extension ConversationViewModel {
    /// 群里安静太久，让某个成员自己开口找她。
    ///
    /// 兔兔和 Caelum 常聊着聊着就各忙各的，群一冷就是几小时。有人憋不住先开口，
    /// 比任何功能都更像「真的有人在那儿」。规矩（都是为了不烦人）：
    /// · 只在她**打开着这个群**时触发（不做后台推送——那是另一条线的活）
    /// · 冷场阈值可调，默认 30 分钟；一次冷场只破冰一次，她不回就不再叫
    /// · 挑人按 talkativeness 加权，话痨更可能开口
    /// · 轮次在跑 / 她正在打字 → 让路
    /// · 破冰消息走正常发言链路（会被清洗、会落 claim），不是硬塞的假消息
    @MainActor
    func groupMaybeBreakIce(providerManager: ProviderManager, context: ModelContext) {
        guard let conversation = selectedConversation, conversation.kind == "group" else { return }
        guard !assistantTurnInFlight else { return }
        let enabled = UserDefaults.standard.object(forKey: "groupIceBreakEnabled") as? Bool ?? true
        guard enabled else { return }
        let quietMin = UserDefaults.standard.integer(forKey: "groupIceBreakMinutes")
        let threshold = TimeInterval((quietMin == 0 ? 30 : quietMin) * 60)

        guard let last = currentPath.last, let lastTime = last.createTime else { return }
        let quietFor = Date().timeIntervalSince(lastTime)
        guard quietFor >= threshold else { return }
        // 一次冷场只破一次：上一条已经是 AI 说的 → 说明破过了（她没接话，别追着说）
        guard last.role == "user" || last.senderId == nil else { return }

        let participants = conversation.participants
        guard !participants.isEmpty else { return }
        // 按话痨程度加权抽签
        let pool = participants.flatMap { p in
            Array(repeating: p, count: max(1, Int(p.talkativeness * 10)))
        }
        guard let picked = pool.randomElement() else { return }

        BreadcrumbLog.shared.add("👥", "冷场 \(Int(quietFor / 60)) 分钟 → \(picked.name) 破冰")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "groupLastIceBreakAt")
        groupRequestReply(participantId: picked.id, providerManager: providerManager, context: context)
    }
}
