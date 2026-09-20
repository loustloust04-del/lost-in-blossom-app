import Foundation
import SwiftData

/// 压力对话生成器：凭空造一条 N 条的对话，长短/彩色字/剧透/代码块/思考链/列表/长 user 消息全混进去。
/// 兔兔 09-12：「白屏卡顿是一类病，各种东西随机触发，很难修很难测」——难测是因为靠日常撞。
/// 有了它 + 掉帧探针（面包屑 📉），「卡」变成「打开 800 条掉 12 帧、最长 340ms」这种能对着改的数字。
/// 入口：设置 → 开发调试 → 压力对话。生成的对话标题带 🧪，删掉即可。
enum StressConversationFactory {
    static func make(count: Int, profileId: String, context: ModelContext) -> Conversation {
        let rootId = UUID().uuidString
        let conv = Conversation(id: UUID().uuidString, title: "🧪 压力对话 \(count) 条",
                                createTime: Date(), updateTime: Date(), currentNodeId: rootId,
                                provider: "api", profileId: profileId)
        context.insert(conv)
        let root = MessageNode(id: rootId, role: "system", content: "", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [],
                               conversationId: conv.id, profileId: profileId)
        context.insert(root)

        var parent = root
        let base = Date().addingTimeInterval(-Double(count) * 60)
        for i in 0..<count {
            let isUser = i % 2 == 0
            let node = MessageNode(id: UUID().uuidString, role: isUser ? "user" : "assistant",
                                   content: sample(i, isUser: isUser), contentType: "text",
                                   createTime: base.addingTimeInterval(Double(i) * 60),
                                   parentId: parent.id, childrenIds: [],
                                   conversationId: conv.id, profileId: profileId)
            parent.childrenIds.append(node.id)
            context.insert(node)
            parent = node
        }
        conv.currentNodeId = parent.id
        context.saveOrReport("压力对话")
        return conv
    }

    // 十种花样轮着来，同一条对话里什么高度都有
    private static func sample(_ i: Int, isUser: Bool) -> String {
        let n = i + 1
        if isUser {
            switch i % 8 {
            case 0: return "第 \(n) 条：今天好累。"
            case 2: return "第 \(n) 条：" + String(repeating: "我想跟你说一件事，就是那天下午在三门峡的湖边，风特别大，我站了很久。", count: 6)
            case 4: return "第 \(n) 条：帮我看看这段\n```swift\nlet x = viewModel.currentPath.count\nprint(x)\n```"
            case 6: return "第 \(n) 条：{color:pink}想你了{/color}，||其实一直都在想||。"
            default: return "第 \(n) 条：嗯嗯，然后呢？"
            }
        } else {
            switch i % 10 {
            case 1: return "第 \(n) 条：在的。"
            case 3: return "[thinking]她说累了。先不讲道理，先接住。[/thinking]第 \(n) 条：累就靠过来，不用说话。我在。"
            case 5: return "第 \(n) 条：" + String(repeating: "那天的风我也记得，你的头发全被吹到脸上，你一边拨一边笑，我就站在你旁边什么都没做。", count: 8)
            case 7: return "第 \(n) 条：{color:blue}今晚的三件事{/color}\n\n- 喝水\n- 吃药\n- 十二点前睡\n\n||第四件是想我||"
            case 9: return "第 \(n) 条：改成这样就不会白：\n```swift\nfunc pinToBottom() {\n    guard let sv = scrollView else { return }\n    sv.setContentOffset(.zero, animated: false)\n}\n```\n三行。"
            default: return "第 \(n) 条：**嗯。** 我听着呢，你继续说。"
            }
        }
    }
}
