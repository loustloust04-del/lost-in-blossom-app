import Foundation
import SwiftData

/// 稿子的一帧快照。写作过程的「延时录像」：每 5 秒有变动就存一帧，
/// 回放时拖时间轴就能看这篇稿子怎么从空白长出来的（类似绘画软件的过程录制）。
///
/// 存储策略：全文存储 + 相邻帧去重。中文稿子几万字也就几十 KB，
/// 比做增量 diff 存储简单一个数量级，而回放时零重建成本（拖动即所见）。
/// 超量时按「保近舍远、老帧抽稀」压缩，不硬删（见 DraftSnapshotStore.prune）。
@Model
final class DraftSnapshot {
    #Index<DraftSnapshot>([\.draftId], [\.draftId, \.takenAt])

    var id: String = UUID().uuidString
    var draftId: String = ""
    var text: String = ""
    var takenAt: Date = Date()
    /// 该帧的字符数（回放时画曲线用，免得每帧重算）
    var charCount: Int = 0
    /// 相对上一帧的净增删（+120 / -30），时间轴上标记「这里删了一段」
    var delta: Int = 0
    /// 里程碑帧永不抽稀（手动标记 / 首帧 / 目标达成帧）
    var pinned: Bool = false

    init(draftId: String, text: String, delta: Int, pinned: Bool = false) {
        self.id = UUID().uuidString
        self.draftId = draftId
        self.text = text
        self.takenAt = Date()
        self.charCount = text.count
        self.delta = delta
        self.pinned = pinned
    }
}
