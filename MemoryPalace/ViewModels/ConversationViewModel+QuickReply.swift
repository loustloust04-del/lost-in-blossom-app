import Foundation
import SwiftData

// MARK: - 通知快速回复：立刻落库
//
// 2026-09-06 兔兔第一次报：「通过通知回复的话，不会落在我们的对话框里，
// 只有主人的在，我的不在。」
// 当时的修法是「排队等 App 前台补写」——09-07 她再报还是不行。
//
// 查明真正的原因：他的回复走 appendCCMessage，是**收到就立刻落库**的；
// 而我把她的话排进队列等前台。于是她看到的永远是「只有他的，没有我的」，
// 而且切回 App 那一刻队列才补，时机对不上就更乱。
//
// 她的原话：「我觉得从那里回复，应该跟我就在那个 chat 页面回复的消息一样。
// 我看微信和 QQ 都能做到及时地出现。」——对，就该一样。
//
// 现在改成：通知 handler 里直接写 SwiftData，与 appendCCMessage 同一条路
// （建 container → 找 conversation → 挂 parentId → insert）。
// 后台唤醒有约 30 秒，插一条记录用不了一秒。
enum QuickReplyStore {

    /// 通知里回复后立刻落库。返回是否成功。
    /// 在通知 handler（App 可能在后台）里调用，自己建 ModelContainer。
    @discardableResult
    static func appendUserMessage(chatId: String, text: String) -> Bool {
        guard !chatId.isEmpty, !text.isEmpty else { return false }
        let container = ProfileManager.makeUnifiedContainer()
        let ctx = ModelContext(container)

        // 找到那个会话
        let convoDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == chatId }
        )
        guard let convo = try? ctx.fetch(convoDesc).first else { return false }

        // 挂在当前节点后面——与 appendCCMessage 同一套：
        // 拿不到 parent 就用 conversation.currentNodeId，绝不在空路径上造新根
        // （那会让整条历史被绕过，兔兔实测过「聊天记录被整个吞掉」）
        let parentId: String? = convo.currentNodeId.isEmpty ? nil : convo.currentNodeId

        let nodeId = UUID().uuidString
        let node = MessageNode(
            id: nodeId,
            role: "user",
            content: text,
            contentType: "text",
            createTime: Date(),
            parentId: parentId,
            childrenIds: [],
            conversationId: convo.id,
            profileId: convo.profileId
        )
        ctx.insert(node)

        // 接上父节点的 childrenIds
        if let pid = parentId {
            let pDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == pid })
            if let parent = try? ctx.fetch(pDesc).first,
               !parent.childrenIds.contains(nodeId) {
                parent.childrenIds.append(nodeId)
            }
        }
        convo.currentNodeId = nodeId
        convo.updateTime = Date()

        do { try ctx.save(); return true }
        catch { return false }
    }
}
