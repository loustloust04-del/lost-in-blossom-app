import Foundation
import SwiftData

/// 开工卡：聊出一个故事后，Caelum 生成的一张「今天可以怎么写」的卡。
/// 不是大纲（大纲有压迫感），是一句话主线 + 几个可以先写的片段 + 一个不吓人的今日目标。
@Model
final class WorkCard {
    #Index<WorkCard>([\.profileId], [\.draftId])

    var id: String = UUID().uuidString
    var profileId: String = ""
    /// 绑定的稿子（点「开始写」时创建并绑定）
    var draftId: String = ""
    var title: String = ""
    /// 一句话主线
    var premise: String = ""
    /// 可以先写的片段（3–5 个）
    var beats: [String] = []
    /// 已写完的片段序号
    var doneBeats: [Int] = []
    var dailyGoal: Int = 0
    var createdAt: Date = Date()
    var archived: Bool = false

    init(profileId: String, title: String, premise: String, beats: [String], dailyGoal: Int) {
        self.id = UUID().uuidString
        self.profileId = profileId
        self.title = title
        self.premise = premise
        self.beats = beats
        self.dailyGoal = dailyGoal
        self.createdAt = Date()
    }

    var progress: Double {
        beats.isEmpty ? 0 : Double(doneBeats.count) / Double(beats.count)
    }
}
