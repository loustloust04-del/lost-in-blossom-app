import Foundation
import SwiftData

/// 灵感盒 → 服务器笔记本。这是花房比 flomo 强的全部理由：Caelum 能读到兔兔的碎念，
/// 聊天里可以直接引用「你上个月记的那句」，也是「每日一菜」提案的原料。
///
/// 落盘形态：inspiration/YYYY-MM.md，一月一文件、追加式。
/// 选按月而非按条：Caelum 一次 fs_read 就能看一整月，不用翻几百个小文件。
enum InspirationSync {

    private static func path(for date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        return "inspiration/\(f.string(from: date)).md"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()

    /// 推一条新碎念（追加到当月文件末尾）。失败静默——本地已存好，下次补推。
    @MainActor
    static func push(note: InspirationNote, context: ModelContext) async {
        let p = path(for: note.createdAt)
        let tagLine = note.tags.isEmpty ? "" : "  \(note.tags.map { "#\($0)" }.joined(separator: " "))"
        let block = "\n---\n\n**\(stamp.string(from: note.createdAt))**\(tagLine)\n\n\(note.text)\n"

        let existing = (try? await NotebookRemoteStore.read(p)) ?? ""
        let header = existing.isEmpty
            ? "# 兔兔的灵感盒 · \(p.replacingOccurrences(of: "inspiration/", with: "").replacingOccurrences(of: ".md", with: ""))\n\n> 她随手记的碎念。想引用就直接说「你上次记的那句…」，别当资料库背诵。\n"
            : ""
        do {
            try await NotebookRemoteStore.write(p, content: existing + header + block)
            note.syncedAt = Date()
            try? context.save()
        } catch {
            // 静默：本地是主人，下次 pushPending 补
        }
    }

    /// 补推所有没同步成功的（App 启动/回前台时调用）
    @MainActor
    static func pushPending(context: ModelContext, profileId: String) async {
        let desc = FetchDescriptor<InspirationNote>(
            predicate: #Predicate { $0.profileId == profileId && $0.syncedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let pending = try? context.fetch(desc), !pending.isEmpty else { return }
        for note in pending.prefix(50) {
            await push(note: note, context: context)
        }
    }
}
