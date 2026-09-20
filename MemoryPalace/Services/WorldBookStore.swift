import Foundation
import SwiftData

/// 楼层世界书的 SwiftData 数据访问层。
/// 解耦方向四：WorldBookPanelView 等 View 不再直接 fetch/insert/delete/save modelContext，
/// 统一走这里。后续群聊 per-member 组装也复用此入口。
enum WorldBookStore {

    /// 当前楼层的全部世界书
    static func fetchBooks(profileId: String, context: ModelContext) -> [WorldBook] {
        let pid = profileId
        let descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == pid })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 全库世界书（跨楼层，孤儿清理用）
    static func fetchAllBooks(context: ModelContext) -> [WorldBook] {
        let descriptor = FetchDescriptor<WorldBook>()
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 最近打开的对话 id（"当前对话"作用域绑定用）
    static func latestConversationId(profileId: String, context: ModelContext) -> String? {
        let pid = profileId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid },
            sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor))?.first?.id
    }

    /// 新建并落盘
    static func insert(_ book: WorldBook, context: ModelContext) {
        context.insert(book)
        persist(context: context)
    }

    /// 删除并落盘
    static func delete(_ book: WorldBook, context: ModelContext) {
        context.delete(book)
        persist(context: context)
    }

    /// 托管对象就地修改（entries/name/scope 等）后的统一落盘出口
    static func persist(context: ModelContext) {
        try? context.save()
    }
}
