import Foundation

/// 统一工具定义：一份 spec，双家 schema 渲染（Toolbase Phase 0，搬运自 SusuPalace
/// plan-pi-style-toolbase P0.1）。只管「模型看到什么」——执行分发仍在
/// ToolCallLoop / Provider 的 tool_use 回调，不动。
/// 迁移动机：此前每个工具手写 OpenAI + Anthropic 两份 JSON schema，
/// 改一边忘另一边会静默漂移（粟粟家迁移时就抓到过一个活标本）。
struct ToolDefinition {
    let name: String
    let description: String
    /// JSON-schema properties 原样字典（含 enum/items 等嵌套，渲染器不解释只包装）
    let properties: [String: Any]
    let required: [String]
}

/// 注入门控输入。工具自身的开关（如联网搜索总开关）由 enabledIf 闭包自己读，
/// 这里只装「按调用点变化」的量。
/// （粟粟版还有 deferMCP——Bunny 没有 MetaTools 元工具目录，暂不需要。）
struct ToolGateContext {
    enum Family { case openAI, anthropic }
    let family: Family
}

/// 双家渲染器：输出形状与迁移前各工具手写版本一致。
enum ToolSchemaRenderer {
    /// OpenAI: {type:function, function:{name,description,parameters}}
    static func openAI(_ d: ToolDefinition) -> [String: Any] {
        ["type": "function", "function": [
            "name": d.name, "description": d.description,
            "parameters": ["type": "object", "properties": d.properties, "required": d.required]
        ] as [String: Any]]
    }

    /// Anthropic: {name,description,input_schema}
    static func anthropic(_ d: ToolDefinition) -> [String: Any] {
        ["name": d.name, "description": d.description,
         "input_schema": ["type": "object", "properties": d.properties, "required": d.required] as [String: Any]]
    }

    static func render(_ defs: [ToolDefinition], family: ToolGateContext.Family) -> [[String: Any]] {
        switch family {
        case .openAI: return defs.map(openAI)
        case .anthropic: return defs.map(anthropic)
        }
    }
}
