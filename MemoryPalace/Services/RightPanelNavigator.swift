import Foundation

/// 搜索结果点击后，协调「打开右栏 + 切 tool + 滚动到条目 + 高亮闪烁」的跳板。
/// 各面板 onChange(pendingTarget) 消费后置 nil，并自行做 scrollTo + 1.5s 高亮动画。
@Observable
final class RightPanelNavigator {
    struct Target: Equatable {
        let tool: String     // "memory" / "worldBook" / "cardLibrary"
        let id: String       // 面板内滚动目标 id（要和 row 的 `.id(...)` 对齐）
    }

    var pendingTarget: Target? = nil
}
