import Foundation

// MARK: - Right Panel Tool

struct RightPanelTool: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var icon: String          // SF Symbol name
    var isPinned: Bool = true // 兼容旧字段，但现在和 isEnabled 同步
    var isEnabled: Bool = true // 唯一开关：false = toolbar + 抽屉 + 设置页联动关闭
    var order: Int = 0
}

// MARK: - Right Panel Tool Manager

@Observable
final class RightPanelToolManager {
    private static let storageKey = "rightPanelTools"

    var tools: [RightPanelTool]

    /// 已启用的工具（toolbar 显示，按 order 排序）
    var pinnedTools: [RightPanelTool] {
        tools.filter(\.isEnabled).sorted { $0.order < $1.order }
    }

    /// 全部工具（抽屉/设置页显示，按 order 排序）
    var allToolsSorted: [RightPanelTool] {
        tools.sorted { $0.order < $1.order }
    }

    init() {
        self.tools = Self.load()
    }

    // MARK: - Enable / Disable（toolbar 移除 和 设置页 Toggle 统一入口）

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let idx = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[idx].isEnabled = enabled
        tools[idx].isPinned = enabled // 同步
        persist()
    }

    // MARK: - Drag Reorder（拖拽排序）

    /// 把 fromId 移到 toId 的位置（toolbar 和抽屉共用）
    func reorder(fromId: String, toId: String) {
        guard fromId != toId else { return }
        var sorted = allToolsSorted
        guard let fromIdx = sorted.firstIndex(where: { $0.id == fromId }),
              let toIdx = sorted.firstIndex(where: { $0.id == toId }) else { return }

        let moving = sorted.remove(at: fromIdx)
        sorted.insert(moving, at: toIdx)

        // 重新编号 order
        for (i, tool) in sorted.enumerated() {
            if let ti = tools.firstIndex(where: { $0.id == tool.id }) {
                tools[ti].order = i
            }
        }
        persist()
    }

    // MARK: - Query

    func tool(byId id: String) -> RightPanelTool? {
        tools.first { $0.id == id }
    }

    /// 当前选中的工具被禁用后，回落到第一个可用工具
    func fallbackToolId(from current: String) -> String? {
        let pinned = pinnedTools
        if pinned.contains(where: { $0.id == current }) { return nil }
        return pinned.first?.id
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(tools) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [RightPanelTool] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([RightPanelTool].self, from: data),
           !saved.isEmpty {
            var result = saved
            for builtin in builtInTools {
                if !result.contains(where: { $0.id == builtin.id }) {
                    result.append(builtin)
                }
            }
            return result
        }
        return builtInTools
    }

    // MARK: - Built-in Tools

    static let builtInTools: [RightPanelTool] = [
        RightPanelTool(id: "calendar",    name: "日历",    icon: "calendar",                       order: 0),
        RightPanelTool(id: "health",      name: "健康",    icon: "heart.fill",                     order: 1),
        RightPanelTool(id: "memory",      name: "记忆",    icon: "brain",                          order: 2),
        RightPanelTool(id: "worldBook",   name: "世界书",  icon: "book.closed",                    order: 3),
        RightPanelTool(id: "cardLibrary", name: "卡库",    icon: "person.crop.rectangle.stack",    order: 4),
        RightPanelTool(id: "sticker",     name: "贴纸",    icon: "star.circle",                    order: 5),
        RightPanelTool(id: "prompt",      name: "Prompt", icon: "text.bubble",  isEnabled: false, order: 6),
        RightPanelTool(id: "ccTerminal",  name: "CC 终端", icon: "terminal",                        order: 7),
        RightPanelTool(id: "fileLibrary", name: "文件库",  icon: "folder.fill",                     order: 8),
        RightPanelTool(id: "browser",     name: "浏览器",  icon: "safari",                              order: 9),
        RightPanelTool(id: "reading",     name: "读书",    icon: "book.fill",                           order: 10),
        RightPanelTool(id: "music",       name: "音乐",    icon: "music.note",                          order: 11),
        RightPanelTool(id: "marks",       name: "刻痕",    icon: "heart.text.square",                   order: 12),
    ]
}

// MARK: - Tool Selection

/// 右栏当前选中的工具 id。
///
/// 09-03：从 ContentView 的 `@State` 搬出来。原来改它 ⇒ ContentView(942 行) body 全量重算
/// ⇒ PagingContainerView.updateUIViewController ⇒ updatePages 三页大锤 ⇒ 三个
/// UIHostingController.rootView 全换 ⇒ CardFlowView(2679 行整棵聊天树) + 写作间 + 桌面页
/// 全部重 diff。对话越长这一锤越沉 = 「反复切才卡」。
///
/// @Observable 的订阅**按属性读取**建立：ContentView 只在闭包里**写** `id`、body 里从不
/// **读**，⇒ 不订阅 ⇒ 切工具不重算 ContentView ⇒ 大锤不落。
/// 同款手法先例：ProviderManager / PresetManager 的订阅从 ContentView 收敛到
/// Representable 层（ContentView.swift:28-30）。
@Observable
final class ToolSelection {
    var id: String = "home"
}
