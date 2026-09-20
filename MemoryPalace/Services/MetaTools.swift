import Foundation

/// MCP 工具过多时的「目录化」元工具：不再全量内联每个 MCP 工具的 schema，
/// 只暴露 3 个元工具，让模型先 tool_search 搜目录 → tool_inspect 看参数 → tool_invoke 调用。
/// 只面向会膨胀的 MCP 工具海；fs_* 等核心工具仍直接内联，不走这里。
/// (适配自 SusuPalace：MCPResolvedTool → 我们的 MCPToolDescriptor)
enum MetaTools {
    static let searchName = "tool_search"
    static let inspectName = "tool_inspect"
    static let invokeName = "tool_invoke"

    static let names: Set<String> = [searchName, inspectName, invokeName]

    /// (名字, 描述, JSON-schema properties, required)
    private static let specs: [(String, String, [String: Any], [String])] = [
        (searchName,
         "按关键词搜索可用的外部工具（MCP）。返回匹配工具的名字、所属服务、简介。需要某种外部能力但不确定有哪些工具时先用它；query 留空则列出全部。",
         ["query": ["type": "string", "description": "关键词，如「天气」「发推」；留空列出全部"]],
         []),
        (inspectName,
         "查看一个或多个外部工具的完整参数 schema，调用前用它确认参数。",
         ["names": ["type": "array", "items": ["type": "string"], "description": "工具名列表"]],
         ["names"]),
        (invokeName,
         "调用一个外部工具。name 只填工具名本身（如 current_time），不要带来源、命名空间或方括号；arguments 是符合该工具 schema 的参数对象（无参数填 {}）。",
         ["name": ["type": "string"], "arguments": ["type": "object", "description": "该工具的参数对象"]],
         ["name", "arguments"]),
    ]

    /// 元工具的 MCPToolDescriptor（MCP > 阈值时由 ProviderRouter 塞进 bridgeTools，
    /// 走和普通 MCP 工具一样的 anthropicTools/openAITools 上线路径）。server = "meta"。
    static var toolDescriptors: [MCPToolDescriptor] {
        specs.map { (name, desc, props, req) in
            let schema: [String: Any] = ["type": "object", "properties": props, "required": req]
            let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return MCPToolDescriptor(server: "meta", name: name, description: desc, inputSchemaJSON: schemaJSON)
        }
    }

    // MARK: - 目录搜索 / 查看（纯函数，吃 catalog）

    /// 命名空间：mcp:<server>
    static func namespace(_ t: MCPToolDescriptor) -> String { "mcp:\(t.server)" }

    /// query 模糊匹配 name/description；空 query 返回全部。紧凑文本：名字 · 命名空间 · 简介。
    static func search(query: String, catalog: [MCPToolDescriptor]) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hits = q.isEmpty ? catalog : catalog.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
        if hits.isEmpty {
            return "无匹配工具。可用命名空间：\(namespacesSummary(catalog))"
        }
        return hits.map { "· \($0.name) — \($0.description)  (来源 \(namespace($0)))" }.joined(separator: "\n")
    }

    /// 把模型可能带装饰的 name 归一化到 catalog 里的真实工具名。
    static func resolve(_ raw: String, catalog: [MCPToolDescriptor]) -> String? {
        let names = catalog.map(\.name)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if names.contains(trimmed) { return trimmed }
        let bare = String(trimmed.prefix(while: { $0 != " " && $0 != "[" })).trimmingCharacters(in: .whitespaces)
        if names.contains(bare) { return bare }
        if let last = bare.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init), names.contains(last) {
            return last
        }
        if let m = names.first(where: { $0.lowercased() == trimmed.lowercased() }) { return m }
        if let m = names.first(where: { trimmed.lowercased().contains($0.lowercased()) }) { return m }
        return nil
    }

    /// 返回指定工具的完整参数 schema（JSON）。
    static func inspect(names: [String], catalog: [MCPToolDescriptor]) -> String {
        guard !names.isEmpty else { return "请提供要查看的工具名（names）。" }
        var blocks: [String] = []
        for name in names {
            guard let t = catalog.first(where: { $0.name == name }) else {
                blocks.append("\(name): 未找到（用 tool_search 确认名字）")
                continue
            }
            blocks.append("\(name) [\(namespace(t))] — \(t.description)\n参数 schema:\n\(t.inputSchemaJSON)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// namespace → 工具数量，拼成 "mcp:天气(12)、mcp:推特(8)"
    static func namespacesSummary(_ catalog: [MCPToolDescriptor]) -> String {
        let counts = Dictionary(grouping: catalog, by: { namespace($0) }).mapValues { $0.count }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)(\($0.value))" }.joined(separator: "、")
    }
}
