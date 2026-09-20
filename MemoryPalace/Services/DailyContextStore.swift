import Foundation
import SwiftData

/// DailyContext（控制台每日上下文）的 SwiftData 数据访问层。
/// 解耦方向四：ConsoleView 不再直接 insert modelContext。
enum DailyContextStore {

    /// 确保今天的 DailyContext 存在并返回（沿用原行为：只 insert 不显式 save，交给 autosave）
    @discardableResult
    static func ensureToday(context: ModelContext) -> DailyContext? {
        let today = Calendar.current.startOfDay(for: Date())
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else { return nil }
        let desc = FetchDescriptor<DailyContext>(
            predicate: #Predicate<DailyContext> { $0.date >= today && $0.date < tomorrow }
        )
        if let existing = try? context.fetch(desc).first { return existing }
        let ctx = DailyContext(date: today)
        context.insert(ctx)
        return ctx
    }
}
