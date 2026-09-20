import Foundation

/// 文件库工具循环用的结构化块。只在带工具的对话里出现，纯聊天路径不碰这些类型。

/// 模型本轮发起的一次工具调用。
struct ToolCallBlock {
    let id: String
    let name: String
    let argumentsJSON: String   // 原始 JSON 字符串（流式拼接得到）
}

/// app 执行工具后的结果，回灌给模型。
struct ToolResultBlock {
    let toolUseId: String
    let text: String
    let isError: Bool
}

/// 一个工具回合：模型本轮的 tool_use(s) + app 执行后的 result(s)。
/// 按发生顺序追加在原始 messages 之后喂给下一轮请求（保持 use→result 严格配对）。
struct ToolTurn {
    let calls: [ToolCallBlock]
    let results: [ToolResultBlock]
}
