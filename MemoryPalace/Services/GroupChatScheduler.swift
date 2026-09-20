import Foundation

/// 群聊 V5 调度引擎。
///
/// V4 的问题：N 个角色 × 1 次门控调用 = N 次额外 LLM 请求，慢且贵。
/// V5 改为：1 次 LLM 调用选出下一个说话者（或"无人"），循环直到没人想说。
///
/// 三个核心机制：
/// - **选人**：单次 LLM 调用，从所有角色中选出最该说话的那个
/// - **镜像**：每个角色看到自己的历史是 assistant，别人是 user + [名字]
/// - **互感**：system prompt 注入完整成员列表 + 角色关系描述
enum GroupChatScheduler {

    struct HistoryItem {
        let role: String          // "user" / "assistant"
        let senderId: String?
        let senderName: String?
        let content: String
    }

    // MARK: - 选人（替代 N 次门控）

    /// 单次 LLM 调用选出下一个说话者。返回 participant.id 或 nil（无人想说话）。
    /// 输出清洗（0910 兔兔实拍）：万一后端仍把脚手架/别人的台词吐回来，客户端兜底裁掉。
    /// 触发一条就从那里截断——宁可短，不要把内部剧本贴到群里。
    static func sanitizeGroupReply(_ raw: String) -> String {
        var text = raw
        let cutMarkers = [
            "\n用户:", "\n用户：", "\n助手:", "\n助手：",
            "\n请回复最后一条用户消息", "\n<conversation>", "\n<msg from=",
            "\n以上是已经发生的对话",
        ]
        for marker in cutMarkers {
            if let r = text.range(of: marker) { text = String(text[..<r.lowerBound]) }
        }
        // 开头若带「名字：」前缀也削掉（群规则里已禁，模型偶尔还是加）
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    /// V6 刀3：发言模式（与粟粟 Agora speech_mode 同名，将来服务端化好对齐）
    static var speechMode: String {
        UserDefaults.standard.string(forKey: "groupSpeechMode") ?? "relay"
    }

    static func selectNextSpeaker(
        participants: [GroupParticipant],
        history: [HistoryItem],
        lastSpeakerId: String?,
        providerManager: ProviderManager
    ) async -> GroupParticipant? {
        // @ 提及优先：只认显式 @名字（旧版 contains(p.name) 命中任意子串，
        // 会把只是"提到"某人名字的消息误判为点名，选出没话可说的人 → 空回）。
        if let lastMsg = history.last {
            for p in participants {
                if mentioned(p.name, in: lastMsg.content), p.id != lastSpeakerId {
                    print("[GroupV5] @提及命中: \(p.name)")
                    return p
                }
            }
        }

        // 候选人过滤：排除刚说完话的（防连续发言）
        let candidates = participants.filter { $0.id != lastSpeakerId }
        guard !candidates.isEmpty else { return nil }

        // talkativeness 概率过滤
        let interested = candidates.filter { Double.random(in: 0...1) < $0.talkativeness }
        let pool = interested.isEmpty ? candidates : interested

        // 单候选（含"只有一个 Caelum(CC)"的单角色群）→ 直接返回，无需 LLM 选人。
        // 关键：避免把选人 prompt 发给唯一的 CC 角色（它会以为自己是主持人不回复，
        // 且该调用不带路由头 → 回复飘进别的窗口吞掉上下文）。
        if pool.count == 1 { return pool.first }

        // 构造选人 prompt
        // 群名片优先：长人设的前 80 字是残句、还泄漏私密设定；intro 是用户写给别人看的简介
        let roster = pool.enumerated().map { (i, p) in
            let desc = p.intro.isEmpty ? String(p.systemPrompt.prefix(80)) : p.intro
            return "\(i+1). \(p.name) — \(desc)"
        }.joined(separator: "\n")

        let recentChat = history.suffix(6).map { m in
            let name = m.senderName ?? (m.role == "user" ? "用户" : "AI")
            return "[\(name)]: \(m.content.prefix(100))"
        }.joined(separator: "\n")

        let selectionPrompt = """
        你是群聊主持人。根据最近的对话，从这些角色中选出下一个最该说话的人：
        \(roster)

        最近的对话：
        \(recentChat)

        规则：
        - 选最适合回应当前话题的角色
        - 如果没人特别适合或对话已自然结束，输出"无"
        - 只输出一个角色名或"无"
        """

        // 选人器必须是非 CC 的 API 模型：给 CC 发「你是群聊主持人」选人 prompt 会让它
        // 以为自己是主持人而不回复，且该调用不带路由头 → CC 回复飘进别的窗口、吞掉那边的
        // 上下文（本次惊天 bug 根因，正是"兜底到 pool[0] 的 CC"造成的）。找不到非 CC 选人器
        // 就不跑 LLM，直接从 pool 随机选一个开口——CC 走 groupSpeak 时才带正确路由头。
        guard let model = pool.lazy
                .compactMap({ providerManager.model(byId: $0.model) })
                .first(where: { providerManager.provider(for: $0)?.type != .ccBridge }) else {
            print("[GroupV5] 无非 CC 选人器 → 随机选一个（绝不拿 CC 跑选人 prompt）")
            return pool.randomElement()
        }

        let result = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            var text = ""
            var done = false
            ProviderRouter().sendStreaming(
                model: model,
                messages: [(role: "user", content: selectionPrompt)],
                systemPrompt: "你是群聊选人助手。只输出一个角色名或'无'，不要其他内容。",
                providerManager: providerManager,
                samplingParams: SamplingParams(temperature: 0.3, maxTokens: 20),
                onToken: { token in text += token },
                onComplete: { full, _ in if !done { done = true; cont.resume(returning: full) } },
                onError: { _ in if !done { done = true; cont.resume(returning: "") } }
            )
        }

        let answer = result.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[GroupV5] 选人结果: \"\(answer)\"")

        if answer == "无" || answer.isEmpty { return nil }

        // 模糊匹配角色名
        return pool.first { answer.contains($0.name) } ?? pool.randomElement()
    }

    // MARK: - 镜像 Prompt（增强版）

    /// 站在 speaker 视角重建 messages，加角色关系标注。
    static func buildMirrorMessages(
        for speaker: GroupParticipant,
        history: [HistoryItem],
        participants: [GroupParticipant]
    ) -> [(role: String, content: String)] {
        // 最多保留最近 20 条，防上下文爆
        let recent = history.suffix(20)
        let raw: [(role: String, content: String)] = recent.compactMap { m in
            guard !m.content.isEmpty else { return nil }
            if m.senderId == speaker.id {
                return (role: "assistant", content: m.content)
            } else {
                let name = m.senderName ?? (m.role == "user" ? "用户" : "AI")
                return (role: "user", content: "[\(name)]: \(m.content)")
            }
        }

        // Claude/Anthropic 后端要求 user/assistant 严格交替、首条必须是 user。群聊镜像里
        // 别人的发言都变成 user，多角色时会连续多条 user → Anthropic 直接 400（DeepSeek/
        // OpenAI 容忍，所以之前只有走 Claude 的角色不回）。这里合并连续同 role、并丢弃前导
        // assistant，保证交替，兼容所有后端。
        var merged: [(role: String, content: String)] = []
        for m in raw {
            if !merged.isEmpty, merged[merged.count - 1].role == m.role {
                merged[merged.count - 1].content += "\n" + m.content
            } else {
                merged.append(m)
            }
        }
        while let first = merged.first, first.role != "user" {
            merged.removeFirst()
        }
        return merged
    }

    // MARK: - System Prompt（增强互感）

    /// 组装 system prompt：群聊规则 + 成员列表 + 角色卡 + 长度约束。
    static func buildSystemPrompt(
        for participant: GroupParticipant,
        allParticipants: [GroupParticipant],
        userName: String,
        card: CharacterCard? = nil,
        preset: Preset? = nil,
        /// V6 刀3：自由档给沉默权——「不想说就只回 PASS」（回 PASS 不插消息、不计链深）
        allowPass: Bool = false
    ) -> String {
        var parts: [String] = []

        // 群聊核心规则
        parts.append("""
        你正在一个多人群聊里，你是「\(participant.name)」。
        回复规则：
        - 只以「\(participant.name)」的身份说话，不替别人发言
        - 回复不要加 [\(participant.name)]: 前缀
        - 像微信群聊一样自然简短，通常 1-3 句话
        - 可以用 @名字 来叫其他人说话
        - 如果觉得不需要回复，可以保持沉默
        """)

        if allowPass {
            parts.append("""
            【自由发言】这条消息不是专门找你的。你可以插话，也可以不插——
            **不想说就只回 PASS 两个字母**（不要解释、不要加标点），你的沉默不会留下痕迹。
            只有真的有话要说、或者有人 @ 你时才开口。
            """)
        }

        // 群聊成员列表（增强互感）
        // 0913 兔兔点单：用户也该有人设——以前群里角色只知道她叫什么，不知道她是谁，
        // 于是对她的称呼/态度全靠猜。userPersona 由她自己写（设置-群聊），
        // 和角色的群名片同格式并排列出。
        let userPersona = UserDefaults.standard.string(forKey: "userPersona") ?? ""
        var roster = "## 群聊成员\n"
        if userPersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            roster += "- \(userName)（用户）\n"
        } else {
            roster += "- \(userName)（用户）：\(userPersona)\n"
        }
        for p in allParticipants {
            // 群名片优先（同 selectNextSpeaker）：别人眼里的你 = 你写的简介，不是人设残句
            let desc = p.intro.isEmpty ? String(p.systemPrompt.prefix(60)) : p.intro
            let isMe = p.id == participant.id ? " ← 这是你" : ""
            roster += "- \(p.name)\(isMe)：\(desc)\n"
        }
        parts.append(roster)

        // 角色卡
        if let card {
            if !card.systemPrompt.isEmpty { parts.append(card.systemPrompt) }
            if !card.description.isEmpty { parts.append("【角色设定】\n\(card.description)") }
            if !card.personality.isEmpty { parts.append("【性格】\n\(card.personality)") }
        }

        // 角色设定（人格主体）：本尊可从预设导入、客串手写。加标题让模型明确「这是你的人设」，
        // 而不是把它当成一段无主的文字。
        if !participant.systemPrompt.isEmpty {
            parts.append("## 你的人设\n\(participant.systemPrompt)")
        }

        // preset
        if let preset {
            let presetParts = preset.prompts
                .filter { $0.isSystemPrompt && !$0.isMarker && !$0.content.isEmpty }
                .map(\.content)
            if !presetParts.isEmpty { parts.append(presetParts.joined(separator: "\n")) }
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - @ 提及解析

    /// 从消息内容中提取被 @ 的角色名。
    static func extractMentions(from text: String, participants: [GroupParticipant]) -> [GroupParticipant] {
        participants.filter { mentioned($0.name, in: text) }
    }

    /// 判断 text 是否真的 @ 了名叫 name 的角色。用 contains("@name") 会让短名字误命中长名字
    /// （"B" 命中 "@Bob"、"Haiku" 命中 "@Haiku4.5"）——这里要求 @name 后紧跟的字符不是字母/
    /// 数字（英文名边界），遍历所有出现，任一满足即命中。
    static func mentioned(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        let token = "@\(name)"
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let after = range.upperBound
            if after == text.endIndex { return true }
            let next = text[after]
            if !next.isLetter && !next.isNumber { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
