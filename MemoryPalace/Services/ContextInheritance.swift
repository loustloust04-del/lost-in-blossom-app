import Foundation
import SwiftData

/// 无缝上下文（P3-11 Phase 1）：新对话「继承上文」。
/// 三层继承的 A+C：源对话的压缩脉络（ContextSummary）+ 最近 N 条原文，
/// 拼成新对话的初始 ContextSummary → PromptAssembler 的 summaryLayer 自然注入，
/// 后续 60 条触发滞回压缩时会被覆盖式重写，继承内容自然融入长期脉络。
/// B 层（记忆库 RAG）Phase 2 再加。
enum ContextInheritance {
    private static func markerKey(_ id: String) -> String { "inheritedFrom_\(id)" }

    /// 该对话若是继承来的，返回源对话标题（用于跳过跨窗口轻摘要注入 + UI 标记）
    static func sourceTitle(for conversationId: String) -> String? {
        UserDefaults.standard.string(forKey: markerKey(conversationId))
    }

    /// 执行继承：把 source 的脉络+最近原文写成 target 的初始前情提要。
    static func inherit(from source: Conversation, to target: Conversation,
                        context: ModelContext, recentCount: Int = 8) {
        // A · 源对话的压缩脉络（可能没有——短对话没触发过压缩）
        let sourceSummary = ContextSummarizer.load(conversationId: source.id)?.summary

        // C · 最近 N 条原文（只取 user/assistant，各截 400 字）
        let sid = source.id
        let pid = source.profileId
        var fetch = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> {
                $0.conversationId == sid && $0.profileId == pid && $0.isTrashed == false
            },
            sortBy: [SortDescriptor(\.createTime, order: .reverse)]
        )
        fetch.fetchLimit = 40
        let nodes = (try? context.fetch(fetch)) ?? []
        let userName = UserDefaults.standard.string(forKey: "userName") ?? "用户"
        let recentLines: [String] = nodes
            .filter { ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty }
            .prefix(recentCount)
            .reversed()
            .map { n in
                let who = n.role == "user" ? userName : "你"
                let text = n.content.count > 400 ? String(n.content.prefix(400)) + "…" : n.content
                return "\(who)：\(text)"
            }

        var parts: [String] = [
            "（本对话接续自《\(source.title)》。以下是那场对话的上下文——请无缝接着聊，不要重新打招呼，也不要装作不知道之前聊了什么。）"
        ]
        if let s = sourceSummary, !s.isEmpty {
            parts.append("【那场对话的脉络】\n\(s)")
        }
        if !recentLines.isEmpty {
            parts.append("【刚才最后的原话】\n\(recentLines.joined(separator: "\n"))")
        }
        guard parts.count > 1 else { return }  // 空对话：没东西可继承，不标记

        ContextSummarizer.save(
            ContextSummary(summary: parts.joined(separator: "\n\n"), coveredCount: 0, updatedAt: Date()),
            conversationId: target.id
        )
        UserDefaults.standard.set(source.title, forKey: markerKey(target.id))
    }
}
