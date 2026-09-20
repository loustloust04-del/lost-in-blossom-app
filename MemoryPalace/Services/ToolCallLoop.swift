import Foundation

/// 客户端 tool-calling 循环的共享件：把模型发出的工具调用映射到 MCPService（PR-4 起再加
/// LocalToolRegistry），执行后回传 tool_result。Anthropic（PR-2）与 OpenAI 兼容（PR-3）共用。
enum ToolCallLoop {
    /// 多轮上限：每轮工具调用都要带全量上下文重发，封顶防止失控（见 01-mcp.md R4）。
    static let maxRounds = 5

    struct ToolCall {
        let id: String          // tool_use id / tool_call id，回传 tool_result 时配对
        let name: String
        let argumentsJSON: String
    }
    struct ToolOutcome {
        let id: String
        let name: String
        let text: String
        let isError: Bool
    }

    /// Anthropic `tools` 数组（name/description/input_schema）。工具定义来自 bridge 缓存，
    /// 写法确定，保证 prompt cache 前缀稳定。
    static func anthropicTools(_ tools: [MCPToolDescriptor]) -> [[String: Any]] {
        tools.map { t in
            let schema = parseSchema(t.inputSchemaJSON)
            return ["name": t.name, "description": t.description, "input_schema": schema]
        }
    }

    /// OpenAI function tools 数组（type/function{name,description,parameters}）。
    static func openAITools(_ tools: [MCPToolDescriptor]) -> [[String: Any]] {
        tools.map { t in
            let schema = parseSchema(t.inputSchemaJSON)
            return ["type": "function",
                    "function": ["name": t.name, "description": t.description, "parameters": schema]]
        }
    }

    private static func parseSchema(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            ?? ["type": "object", "properties": [:]]
    }

    /// 执行一批工具调用：按名在 bridgeTools 里查 server → 解析参数 → 调 MCPService。
    /// 失败不抛——返回 isError 的 outcome，让循环把它当 tool_result 回灌，模型自行决定。
    static func execute(_ calls: [ToolCall], bridgeTools: [MCPToolDescriptor], metaToolCatalog: [MCPToolDescriptor] = []) async -> [ToolOutcome] {
        var outcomes: [ToolOutcome] = []
        for call in calls {
            // ── 本地工具：联网搜索 / 读网页（在 MCP 查找之前拦截）──
            if call.name == WebSearchToolService.toolName {
                let result = await WebSearchToolService.execute(inputJSON: call.argumentsJSON)
                outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                            text: result.text, isError: result.isError))
                continue
            }
            if call.name == BrowseURLTool.toolName {
                let result = await BrowseURLTool.execute(inputJSON: call.argumentsJSON)
                outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                            text: result.text, isError: result.isError))
                continue
            }
            // ── 选择卡（ask_user）：挂起工具循环等用户点选（AskUserGate 详注）──
            if call.name == AskUserTool.toolName {
                if let qs = AskUserTool.parse(inputJSON: call.argumentsJSON) {
                    // execute 不在 MainActor 上；闸门是 @MainActor，显式跳过去调用
                    let answers = await MainActor.run { AskUserGate.shared }.ask(qs)
                    let text = answers.map { AskUserTool.resultText(questions: qs, answers: $0) }
                        ?? "（选择卡未能弹出：界面不在前台或已有一张卡挂着。可以直接用文字问她。）"
                    outcomes.append(ToolOutcome(id: call.id, name: call.name, text: text, isError: answers == nil))
                } else {
                    outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                                text: AskUserTool.invalidArgsMessage, isError: true))
                }
                continue
            }
            // ── 笔记本工具（fs_*，走网关 REST，与 CC 共用同一本）──
            if NotebookTool.toolNames.contains(call.name) {
                let result = await NotebookTool.execute(name: call.name, inputJSON: call.argumentsJSON)
                outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                            text: result.text, isError: result.isError))
                continue
            }
            // ── 元工具（MetaTools 目录化）：tool_search / tool_inspect / tool_invoke ──
            if MetaTools.names.contains(call.name) {
                let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                var text = ""
                var isError = false
                switch call.name {
                case MetaTools.searchName:
                    text = MetaTools.search(query: args["query"] as? String ?? "", catalog: metaToolCatalog)
                case MetaTools.inspectName:
                    text = MetaTools.inspect(names: args["names"] as? [String] ?? [], catalog: metaToolCatalog)
                case MetaTools.invokeName:
                    let toolName = args["name"] as? String ?? ""
                    let toolArgs = args["arguments"] as? [String: Any] ?? [:]
                    if let resolved = MetaTools.resolve(toolName, catalog: metaToolCatalog),
                       let server = metaToolCatalog.first(where: { $0.name == resolved })?.server {
                        do {
                            let blocks = try await MCPService.shared.callTool(server: server, tool: resolved, arguments: toolArgs)
                            text = MCPContentBlock.flatten(blocks)
                        } catch {
                            text = "调用 \(resolved) 失败: \(error.localizedDescription)"
                            isError = true
                        }
                    } else {
                        text = "工具 '\(toolName)' 未找到。用 tool_search 搜索可用工具。"
                        isError = true
                    }
                default:
                    text = "未知元工具: \(call.name)"
                    isError = true
                }
                outcomes.append(ToolOutcome(id: call.id, name: call.name, text: text, isError: isError))
                continue
            }
            guard let server = bridgeTools.first(where: { $0.name == call.name })?.server else {
                outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                            text: "未知工具: \(call.name)", isError: true))
                continue
            }
            let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
            do {
                let blocks = try await MCPService.shared.callTool(server: server, tool: call.name, arguments: args)
                outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                            text: MCPContentBlock.flatten(blocks), isError: false))
            } catch {
                outcomes.append(ToolOutcome(id: call.id, name: call.name,
                                            text: "工具执行失败: \(error.localizedDescription)", isError: true))
            }
        }
        return outcomes
    }
}
