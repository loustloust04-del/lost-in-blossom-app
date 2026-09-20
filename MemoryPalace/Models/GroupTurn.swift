import Foundation
import SwiftData

/// 群聊轮次（V6 刀1，PLAN-GROUPCHAT-V6 病灶1）。
///
/// V5 之前整轮群聊只是 `runGroupRound` 里的一个 while 循环，状态全在内存：
/// App 切走/崩溃/退后台 → 整轮蒸发得像从没发生过，重进也没人记得聊到哪、谁还欠一句。
/// 落库之后：中断可被发现、「停止」是事实而不是内存布尔、兔兔插话 = 旧轮 superseded。
///
/// ⚠️ 字段命名避开 SwiftData PersistentModel 保留属性（isDeleted 血案，e6fdb81d）。
@Model
final class GroupTurn {
    #Index<GroupTurn>([\.conversationId], [\.startedAt])

    @Attribute(.unique) var id: String
    var conversationId: String
    var profileId: String
    /// 触发这一轮的消息节点（兔兔那句话）
    var triggerNodeId: String
    var startedAt: Date
    var endedAt: Date?
    /// running | done | cancelled | superseded | interrupted
    var state: String
    /// 已经接了几手（兔兔说话 = 0）
    var chainDepth: Int
    var maxChainDepth: Int
    /// mention_only | relay | free（开轮时快照，中途改设置不影响进行中的轮次）
    var speechMode: String

    init(id: String = UUID().uuidString,
         conversationId: String,
         profileId: String,
         triggerNodeId: String,
         maxChainDepth: Int,
         speechMode: String) {
        self.id = id
        self.conversationId = conversationId
        self.profileId = profileId
        self.triggerNodeId = triggerNodeId
        self.startedAt = Date()
        self.endedAt = nil
        self.state = "running"
        self.chainDepth = 0
        self.maxChainDepth = maxChainDepth
        self.speechMode = speechMode
    }

    var isRunning: Bool { state == "running" }
}

/// 发言权（V6 刀2 预置，病灶2）：谁欠一句话、说没说、为什么没说上。
/// 落库之后模型报错不再静默消失——UI 能显示「小狐狸没说上话（模型超时）」并支持重试。
@Model
final class SpeakClaim {
    #Index<SpeakClaim>([\.turnId], [\.createdAt])

    @Attribute(.unique) var id: String
    var turnId: String
    var conversationId: String
    var participantId: String
    var participantName: String
    /// mentioned（被显式 @）| selected（选人选中）| observe（自由档旁听机会）| requested（长按定向）
    var reason: String
    /// pending | speaking | done | passed | failed
    var state: String
    /// 失败原因（模型未找到 / 超时 / 网络等），UI 直接显示
    var failureNote: String?
    var createdAt: Date
    var finishedAt: Date?
    /// 说出来的那条消息节点（done 时有）
    var resultNodeId: String?

    init(id: String = UUID().uuidString,
         turnId: String,
         conversationId: String,
         participantId: String,
         participantName: String,
         reason: String) {
        self.id = id
        self.turnId = turnId
        self.conversationId = conversationId
        self.participantId = participantId
        self.participantName = participantName
        self.reason = reason
        self.state = "pending"
        self.failureNote = nil
        self.createdAt = Date()
        self.finishedAt = nil
        self.resultNodeId = nil
    }
}
