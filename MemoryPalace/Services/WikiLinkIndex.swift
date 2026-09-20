import Foundation

/// 文件库 wiki 链接索引：正向（文件 → 引用目标）+ 反向（谁链到我 / backlinks）。
///
/// 2026-08-31 自粟粟搬入并改造。她那版数据源是本地 FileLibraryStore；
/// 我们的文件库主力在服务器（NotebookRemoteStore，gateway /api/notebook），
/// 故改成 async + 可切换数据源，本地库也一并索引。
///
/// - 内存态，惰性全量构建；文件变动后调 invalidate() 失效重建
///   （当前规模十几个 md，全量重建很快，不提前造持久化索引）
/// - 目标解析规则：精确路径 → 文件名匹配（带/不带扩展名，不分大小写）
/// - 已知局限（沿用她的）：正则不排除代码块里的 [[ ]]
actor WikiLinkIndex {
    static let shared = WikiLinkIndex()

    /// path → 该文件里出现的原始 [[目标]] 集合
    private var forward: [String: Set<String>] = [:]
    private var built = false

    private static let pattern = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+)\\]\\]")

    // MARK: - 构建与失效

    func invalidate() {
        built = false
        forward = [:]
    }

    private func ensureBuilt() async {
        guard !built else { return }
        var table: [String: Set<String>] = [:]
        if let metas = try? await NotebookRemoteStore.list() {
            for meta in metas where Self.isIndexable(meta.path) {
                guard let body = try? await NotebookRemoteStore.read(meta.path) else { continue }
                let targets = Self.scan(body)
                if !targets.isEmpty { table[meta.path] = targets }
            }
        }
        forward = table
        built = true
    }

    private static func isIndexable(_ path: String) -> Bool {
        ["md", "markdown", "txt"].contains((path as NSString).pathExtension.lowercased())
    }

    /// 从正文里扫出所有 [[目标]]（纯函数，可单测）
    static func scan(_ content: String) -> Set<String> {
        let ns = content as NSString
        var out: Set<String> = []
        pattern.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.insert(t) }
        }
        return out
    }

    // MARK: - 查询

    /// 这个文件写了哪些 [[目标]]
    func outgoingTargets(of path: String) async -> Set<String> {
        await ensureBuilt()
        return forward[path] ?? []
    }

    /// 谁链到这个文件（backlinks）
    func backlinks(of path: String) async -> [String] {
        await ensureBuilt()
        let full = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()

        var sources: [String] = []
        for (source, targets) in forward where source != path {
            let hit = targets.contains { raw in
                var t = raw.lowercased()
                if URL(fileURLWithPath: t).pathExtension.isEmpty { t += ".md" }
                return t == full
                    || URL(fileURLWithPath: t).lastPathComponent == name
                    || URL(fileURLWithPath: raw.lowercased()).lastPathComponent == base
            }
            if hit { sources.append(source) }
        }
        return sources.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 把 [[目标]] 解析成库里的真实路径。找不到返回 nil。
    func resolveTarget(_ raw: String) async -> String? {
        guard let metas = try? await NotebookRemoteStore.list() else { return nil }
        let want = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var wantWithExt = want
        if URL(fileURLWithPath: want).pathExtension.isEmpty { wantWithExt += ".md" }

        // ① 精确路径
        if let hit = metas.first(where: { $0.path.lowercased() == wantWithExt || $0.path.lowercased() == want }) {
            return hit.path
        }
        // ② 文件名匹配（带扩展名）
        if let hit = metas.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == wantWithExt }) {
            return hit.path
        }
        // ③ 去扩展名的 basename 匹配
        let wantBase = URL(fileURLWithPath: want).deletingPathExtension().lastPathComponent
        return metas.first {
            URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent.lowercased() == wantBase
        }?.path
    }
}
