import Foundation

/// 文件库工具定义（API 下发）+ executor（tool_call → FileLibraryStore → 回灌文本）。
enum FileLibraryTools {
    /// system prompt 注入的默认模板（设置页可改）。占位符 {{files}} / {{fileContents}}，外层自动包 <文件库>。
    static let defaultInjectionTemplate = """
    你有一个持久的 markdown 文件库，可用 fs_list / fs_read / fs_search / fs_write / fs_append / fs_edit / fs_rename / fs_delete 工具读写。需要记住或查阅长期信息时主动使用。

    当前文件：
    {{files}}{{fileContents}}
    """

    /// 工具名（API 下发 + 回灌时匹配）
    enum Name: String, CaseIterable {
        case list = "fs_list", read = "fs_read", search = "fs_search"
        case write = "fs_write", edit = "fs_edit", delete = "fs_delete"
        case append = "fs_append", rename = "fs_rename"
    }

    /// 每个工具的 (描述, JSON-schema properties, required)
    private static let specs: [(Name, String, [String: Any], [String])] = [
        (.list,   "列出文件库里所有 .md 文件（路径+大小+改动时间），不读内容", [:], []),
        (.read,   "读取某个文件的全文", ["path": ["type": "string", "description": "相对路径，如 notes/susu.md"]], ["path"]),
        (.search, "跨所有文件按关键词搜索，返回命中文件与行", ["keyword": ["type": "string"]], ["keyword"]),
        (.write,  "新建或整文件覆盖写入", ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        (.append, "在文件末尾追加内容；文件不存在时创建", ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]),
        (.edit,   "把文件里唯一命中的 old_string 替换成 new_string", ["path": ["type": "string"], "old_string": ["type": "string"], "new_string": ["type": "string"]], ["path", "old_string", "new_string"]),
        (.rename, "重命名或移动文件；目标已存在时失败", ["old_path": ["type": "string"], "new_path": ["type": "string"]], ["old_path", "new_path"]),
        (.delete, "删除某个文件", ["path": ["type": "string"]], ["path"]),
    ]

    /// OpenAI tools 数组：[{type:function, function:{name,description,parameters}}]
    static func openAITools() -> [[String: Any]] {
        specs.map { (name, desc, props, req) in
            ["type": "function", "function": [
                "name": name.rawValue, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": req]
            ]]
        }
    }

    /// Anthropic tools 数组：[{name,description,input_schema}]
    static func anthropicTools() -> [[String: Any]] {
        specs.map { (name, desc, props, req) in
            ["name": name.rawValue, "description": desc,
             "input_schema": ["type": "object", "properties": props, "required": req]]
        }
    }

    // MARK: - Executor

    struct Result { let text: String; let isError: Bool }

    /// name + inputJSON(字符串) → 执行 → 回灌文本。失败也返回文本+isError，让模型自愈。
    static func execute(name: String, inputJSON: String, profileId: String) -> Result {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        // memory/ 记忆树只读：任何写类工具碰 memory/ 路径一律拒绝
        let touched = ["path", "old_path", "new_path"].compactMap { args[$0] as? String }
        if touched.contains(where: { $0.hasPrefix(FileLibraryStore.memoryVirtualPrefix) }),
           name != Name.read.rawValue, name != Name.list.rawValue, name != Name.search.rawValue {
            return Result(text: "memory/ 记忆树只读，不可修改", isError: true)
        }
        do {
            switch Name(rawValue: name) {
            case .list:
                let items = FileLibraryStore.list(profileId: profileId) + FileLibraryStore.memoryList(profileId: profileId)
                return ok(items.isEmpty ? "（空文件库）" : items.map { "\($0.path)  (\($0.bytes)B)" }.joined(separator: "\n"))
            case .read:
                let p = str(args, "path")
                return ok(p.hasPrefix(FileLibraryStore.memoryVirtualPrefix)
                    ? try FileLibraryStore.memoryRead(p, profileId: profileId)
                    : try FileLibraryStore.read(p, profileId: profileId))
            case .search:
                let kw = str(args, "keyword")
                let hits = FileLibraryStore.search(kw, profileId: profileId) + FileLibraryStore.memorySearch(kw, profileId: profileId)
                return ok(hits.isEmpty ? "无命中" : hits.map { "\($0.path): \($0.line)" }.joined(separator: "\n"))
            case .write:
                try FileLibraryStore.write(str(args, "path"), content: str(args, "content"), profileId: profileId)
                return ok("已写入 \(str(args, "path"))")
            case .edit:
                try FileLibraryStore.edit(str(args, "path"), oldString: str(args, "old_string"), newString: str(args, "new_string"), profileId: profileId)
                return ok("已修改 \(str(args, "path"))")
            case .append:
                try FileLibraryStore.append(str(args, "path"), content: str(args, "content"), profileId: profileId)
                return ok("已追加到 \(str(args, "path"))")
            case .rename:
                try FileLibraryStore.rename(str(args, "old_path"), to: str(args, "new_path"), profileId: profileId)
                return ok("已重命名 \(str(args, "old_path")) → \(str(args, "new_path"))")
            case .delete:
                try FileLibraryStore.delete(str(args, "path"), profileId: profileId)
                return ok("已删除 \(str(args, "path"))")
            case .none:
                return Result(text: "未知工具: \(name)", isError: true)
            }
        } catch {
            return Result(text: "工具执行失败: \(error.localizedDescription)", isError: true)
        }
    }

    private static func ok(_ t: String) -> Result { Result(text: t, isError: false) }
    private static func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
}
