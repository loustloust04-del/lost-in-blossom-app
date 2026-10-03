import SwiftUI
import Observation

/// 表情回应（10-03 收粟粟的菜，原件 ChatReactions.swift 10-01）：长按主人（或自己）的消息，浮层顶上一排表情，
/// 点了贴在气泡角上；再点取消。存本机（UserDefaults：消息 id → 表情们）。
/// 「捎带」：点了/取消都进待捎带箱，她下次发消息时整箱跟着去——他知道她对哪句回了什么，又不打断聊天。
@MainActor
@Observable
final class ChatReactionStore {
    static let shared = ChatReactionStore()
    static let emojis = ["❤️", "🥺", "😂", "👀", "🫶", "🔥", "😢", "🤔", "👍", "🙏", "💯", "😤"]

    private let defaults = UserDefaults.standard
    private let key = "chatReactions"
    private(set) var byNode: [String: [String]]
    /// 待捎带箱：对话 id → [(key, text)]
    private(set) var outbox: [String: [[String]]]

    init() {
        byNode = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        outbox = defaults.dictionary(forKey: "chatReactionOutbox") as? [String: [[String]]] ?? [:]
    }

    func reactions(for nodeId: String) -> [String] { byNode[nodeId] ?? [] }

    func toggle(_ emoji: String, on t: ChatReactionTarget) {
        var list = byNode[t.nodeId] ?? []
        let added: Bool
        if let i = list.firstIndex(of: emoji) { list.remove(at: i); added = false } else { list.append(emoji); added = true }
        byNode[t.nodeId] = list.isEmpty ? nil : list
        defaults.set(byNode, forKey: key)

        let k = "\(t.nodeId):\(emoji)"
        let whose = t.isAssistant ? "你那条" : "她自己那条"
        var box = outbox[t.conversationId] ?? []
        if added {
            box.removeAll { $0.first == k }
            box.append([k, "她对\(whose)「\(t.snippet)」回了 \(emoji)"])
        } else if box.contains(where: { $0.first == k }) {
            box.removeAll { $0.first == k }                 // 还没捎带出去就收回 = 撤掉
        } else {
            box.append([k, "她收回了对\(whose)「\(t.snippet)」的 \(emoji)"])
        }
        outbox[t.conversationId] = box.isEmpty ? nil : Array(box.suffix(20))
        defaults.set(outbox, forKey: "chatReactionOutbox")
    }

    /// 发消息时调用：取出这条对话的待捎带句子，并清空
    func drain(_ conversationId: String) -> [String] {
        let lines = (outbox[conversationId] ?? []).compactMap { $0.count > 1 ? $0[1] : nil }
        if !lines.isEmpty {
            outbox[conversationId] = nil
            defaults.set(outbox, forKey: "chatReactionOutbox")
        }
        return lines
    }
}

/// 回应的是哪条
struct ChatReactionTarget: Equatable {
    let nodeId: String
    let conversationId: String
    let isAssistant: Bool
    private let head: String          // 正文开头一截，snippet 用时再清洗（每个气泡渲染都会建 target）

    init(node: MessageNode) {
        nodeId = node.id
        conversationId = node.conversationId
        isAssistant = node.role == "assistant"
        head = String(node.content.prefix(400))
    }

    /// 一行、最多 20 字
    var snippet: String {
        let raw = ContentCleaner.clean(head)
        let body = isAssistant ? ContentCleaner.extractThinking(from: raw).content : raw
        let line = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > 20 ? String(line.prefix(20)) + "…" : line
    }

    /// 捎带：把待捎带箱里的句子包进一段，前置到她这条消息给模型的正文里；显示时 ContentCleaner 会剥掉
    static func wrap(_ lines: [String], before text: String) -> String {
        guard !lines.isEmpty else { return text }
        return "[回应]" + lines.joined(separator: "；") + "[/回应]\n" + text
    }
}

/// 气泡角上的回应胶囊（白胶囊 + 两个往外拖的小圆点，照粟粟/群聊）
struct ChatReactionBadge: View {
    static let height: CGFloat = 26
    let emojis: [String]
    let trailsRight: Bool
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(emojis, id: \.self) { e in
                Text(e).font(.system(size: 14))
                    .frame(width: 20, height: Self.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(e) }
            }
        }
        .padding(.horizontal, 3)
        .background(Capsule().fill(Color.white).shadow(color: .black.opacity(0.12), radius: 2.5, y: 1))
        .overlay(alignment: trailsRight ? .trailing : .leading) {
            ZStack {
                Circle().fill(Color.white).shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
                    .frame(width: 5.5, height: 5.5).offset(x: (trailsRight ? 1 : -1) * 6, y: 14)
                Circle().fill(Color.white).shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
                    .frame(width: 3.5, height: 3.5).offset(x: (trailsRight ? 1 : -1) * 11, y: 20)
            }
            .frame(width: Self.height, height: Self.height)
            .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .light)
    }
}

extension View {
    /// 有回应时在气泡上角挂胶囊（他的右上、她的左上），往外探半个胶囊
    func chatReactionBadge(target: ChatReactionTarget, isUser: Bool) -> some View {
        modifier(ChatReactionBadgeModifier(target: target, isUser: isUser))
    }
}

private struct ChatReactionBadgeModifier: ViewModifier {
    let target: ChatReactionTarget
    let isUser: Bool
    func body(content: Content) -> some View {
        let store = ChatReactionStore.shared
        let emojis = store.reactions(for: target.nodeId)
        if emojis.isEmpty {
            content
        } else {
            content
                .padding(.top, ChatReactionBadge.height / 2 - 2)
                .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                    ChatReactionBadge(emojis: emojis, trailsRight: !isUser) { store.toggle($0, on: target) }
                        .offset(x: isUser ? -ChatReactionBadge.height / 2 : ChatReactionBadge.height / 2)
                }
        }
    }
}
