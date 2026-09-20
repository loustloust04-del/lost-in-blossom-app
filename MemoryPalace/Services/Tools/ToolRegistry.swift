import Foundation

/// 内建工具注册表（Toolbase Phase 0，搬运自 SusuPalace P0.2）：
/// 注入侧单一入口——内建工具的定义 + 可用性门控。
/// 不含：MCP bridge 动态工具（ToolCallLoop 自渲染）/ Anthropic server 搜索工具
/// （web_search_20250305 形状特殊，AnthropicProvider 注入处特例）。
///
/// 注意顺序：**保持插入序，不排序**——providers 现有注入顺序是
/// bridge 工具 → search_web → browse_url，prompt cache 前缀按这个字节序稳定；
/// 按名排序会交换 search/browse 顺序，白白打一次缓存失效。
///
/// 门控闭包用 nonisolated 可读的状态（WebSearchSettings.isSearchEnabledFlag），
/// 因为 provider 的工具轮在 URLSession delegate 线程重建请求（Bunny 特有约束，
/// 也是 isSearchEnabledFlag 当初做成 nonisolated 的原因）。
enum ToolRegistry {

    struct Entry {
        let definition: ToolDefinition
        let enabledIf: (ToolGateContext) -> Bool
    }

    /// 全部内建工具（目前 2 件；FileLibraryTools/RecallTool 在 Bunny 未接线，
    /// 接线时再入注册表）。
    static var all: [Entry] {
        [
            // 联网搜索 client function：只发 OpenAI 系（anthropic 直连走 server tool 特例）
            Entry(definition: WebSearchToolService.definition, enabledIf: { ctx in
                ctx.family == .openAI && WebSearchSettings.isSearchEnabledFlag
            }),
            // browse_url：同上
            Entry(definition: BrowseURLTool.definition, enabledIf: { ctx in
                ctx.family == .openAI && WebSearchSettings.isSearchEnabledFlag
            }),
            // 选择卡：两家模型都给（执行在 ToolCallLoop 挂起等用户点选）
            Entry(definition: AskUserTool.definition, enabledIf: { _ in true }),
        ] + NotebookTool.definitions.map { def in
            // 笔记本 fs_* 工具：两家模型都给，网关 token 配好就开
            Entry(definition: def, enabledIf: { _ in NotebookTool.isConfigured })
        }
    }

    static func enabledDefinitions(_ ctx: ToolGateContext) -> [ToolDefinition] {
        all.filter { $0.enabledIf(ctx) }.map(\.definition)
    }
}
