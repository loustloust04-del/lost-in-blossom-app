import Foundation
import SwiftData

/// 写作过程录制：每 5 秒若有变动存一帧；以及帧间差异计算（回放高亮用）。
enum DraftSnapshotStore {

    static let interval: TimeInterval = 5
    /// 单篇上限。超过后老帧抽稀（保留里程碑），近 200 帧永远完整。
    static let softCap = 800
    static let keepRecent = 200

    // MARK: - 录制

    /// 若与最新帧内容不同则记一帧。返回是否真的记了。
    @MainActor
    @discardableResult
    static func capture(draft: Draft, context: ModelContext, pinned: Bool = false) -> Bool {
        let latest = latestSnapshot(draftId: draft.id, context: context)
        guard latest?.text != draft.body else { return false }
        // 空稿不开录，避免新建即产生一堆空帧
        guard !(latest == nil && draft.body.isEmpty) else { return false }

        let delta = draft.body.count - (latest?.charCount ?? 0)
        let snap = DraftSnapshot(draftId: draft.id, text: draft.body, delta: delta,
                                 pinned: pinned || latest == nil)
        context.insert(snap)
        try? context.save()
        prune(draftId: draft.id, context: context)
        return true
    }

    @MainActor
    static func latestSnapshot(draftId: String, context: ModelContext) -> DraftSnapshot? {
        var desc = FetchDescriptor<DraftSnapshot>(
            predicate: #Predicate { $0.draftId == draftId },
            sortBy: [SortDescriptor(\.takenAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        return try? context.fetch(desc).first
    }

    @MainActor
    static func all(draftId: String, context: ModelContext) -> [DraftSnapshot] {
        let desc = FetchDescriptor<DraftSnapshot>(
            predicate: #Predicate { $0.draftId == draftId },
            sortBy: [SortDescriptor(\.takenAt)]
        )
        return (try? context.fetch(desc)) ?? []
    }

    /// 抽稀：近 keepRecent 帧全留，更早的隔帧删（里程碑帧永远保留）。
    /// 过程录像的价值在"能看出怎么长出来"，老段落隔 10 秒采一帧完全够。
    @MainActor
    private static func prune(draftId: String, context: ModelContext) {
        let snaps = all(draftId: draftId, context: context)
        guard snaps.count > softCap else { return }
        let old = snaps.dropLast(keepRecent)
        var toggle = false
        for s in old where !s.pinned {
            toggle.toggle()
            if toggle { context.delete(s) }
        }
        try? context.save()
    }

    // MARK: - 差异（回放高亮）

    struct DiffSegment: Identifiable {
        enum Kind { case same, added, removed }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// 两版之间的增删。行级 LCS——中文写作以段落为单位改动，
    /// 行级既够精细又不会像字级 diff 那样把整段打成马赛克。
    static func diff(from oldText: String, to newText: String) -> [DiffSegment] {
        let a = oldText.components(separatedBy: "\n")
        let b = newText.components(separatedBy: "\n")

        // LCS 长度表
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if a.count * b.count <= 400_000 {          // 超大稿降级为整体替换，避免卡顿
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i+1][j+1] + 1 : max(dp[i+1][j], dp[i][j+1])
                }
            }
        } else {
            return [.init(kind: .removed, text: oldText), .init(kind: .added, text: newText)]
        }

        var out: [DiffSegment] = []
        var i = 0, j = 0
        func push(_ kind: DiffSegment.Kind, _ line: String) {
            if let last = out.last, last.kind == kind {
                out[out.count - 1] = .init(kind: kind, text: last.text + "\n" + line)
            } else {
                out.append(.init(kind: kind, text: line))
            }
        }
        while i < a.count && j < b.count {
            if a[i] == b[j] { push(.same, a[i]); i += 1; j += 1 }
            else if dp[i+1][j] >= dp[i][j+1] { push(.removed, a[i]); i += 1 }
            else { push(.added, b[j]); j += 1 }
        }
        while i < a.count { push(.removed, a[i]); i += 1 }
        while j < b.count { push(.added, b[j]); j += 1 }
        return out
    }
}
