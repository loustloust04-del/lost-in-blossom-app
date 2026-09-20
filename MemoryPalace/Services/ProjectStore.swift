import Foundation
import SwiftData

/// 项目（Project）的 SwiftData 数据访问层。
/// 解耦方向四：ProjectsView 不再直接 insert/delete modelContext。
/// 沿用原行为——只 insert/delete 不显式 save，交给主 context 的 autosave。
enum ProjectStore {

    static func insert(_ project: Project, context: ModelContext) {
        context.insert(project)
    }

    static func delete(_ project: Project, context: ModelContext) {
        context.delete(project)
    }
}
