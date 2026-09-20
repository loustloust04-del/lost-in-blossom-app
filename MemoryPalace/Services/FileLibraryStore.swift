import Foundation

/// app 自包含的 .md 文件库。每楼层一库：App Support/MemoryPalace/fileLibrary/{profileId}/
/// 纯文件 IO，不依赖 SwiftData。路径一律相对（允许子目录），禁止逃出库根。
enum FileLibraryStore {
    struct FileMeta { let path: String; let bytes: Int; let modifiedAt: Date }

    static func libraryRoot(profileId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MemoryPalace/fileLibrary/\(profileId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把相对路径解析成库内绝对 URL，拒绝 ../ 越狱与绝对路径。返回 nil = 非法。
    /// 粟粟侧同功能函数叫 absoluteURL——语音条等搬运件按这个名字调，转发到 resolve。
    static func absoluteURL(_ relPath: String, profileId: String) -> URL? {
        resolve(relPath, profileId: profileId)
    }

    static func resolve(_ relPath: String, profileId: String) -> URL? {
        let root = libraryRoot(profileId: profileId).standardizedFileURL
        let cleaned = relPath.trimmingCharacters(in: .init(charactersIn: "/ "))
        guard !cleaned.isEmpty else { return nil }
        let target = root.appendingPathComponent(cleaned).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") || target.path == root.path else { return nil }
        return target
    }

    static func list(profileId: String) -> [FileMeta] {
        let root = libraryRoot(profileId: profileId)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        var out: [FileMeta] = []
        for case let url as URL in en where url.pathExtension == "md" {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out.append(.init(path: rel, bytes: v?.fileSize ?? 0, modifiedAt: v?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func read(_ relPath: String, profileId: String) throws -> String {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ relPath: String, content: String, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// old→new 局部替换；old 必须唯一命中，否则报错（仿 CC Edit 语义）。
    static func edit(_ relPath: String, oldString: String, newString: String, profileId: String) throws {
        let body = try read(relPath, profileId: profileId)
        let occurrences = body.components(separatedBy: oldString).count - 1
        guard occurrences == 1 else { throw err(occurrences == 0 ? "未找到要替换的文本" : "要替换的文本命中 \(occurrences) 处，需更具体") }
        try write(relPath, content: body.replacingOccurrences(of: oldString, with: newString), profileId: profileId)
    }

    static func delete(_ relPath: String, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try FileManager.default.removeItem(at: url)
    }

    /// 文件末尾追加内容（日记/笔记用）。文件不存在时自动创建。
    static func append(_ relPath: String, content: String, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(content.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try content.data(using: .utf8)!.write(to: url, options: .atomic)
        }
    }

    /// 重命名或移动文件。目标已存在时报错。
    static func rename(_ oldPath: String, to newPath: String, profileId: String) throws {
        guard let src = resolve(oldPath, profileId: profileId) else { throw err("非法路径: \(oldPath)") }
        guard let dst = resolve(newPath, profileId: profileId) else { throw err("非法路径: \(newPath)") }
        guard !FileManager.default.fileExists(atPath: dst.path) else { throw err("目标已存在: \(newPath)") }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    /// 文件是否存在
    static func exists(_ relPath: String, profileId: String) -> Bool {
        guard let url = resolve(relPath, profileId: profileId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 跨文件关键词搜索，返回 [(path, 命中行)]。大小写不敏感。
    static func search(_ keyword: String, profileId: String) -> [(path: String, line: String)] {
        guard !keyword.isEmpty else { return [] }
        var hits: [(path: String, line: String)] = []
        for meta in list(profileId: profileId) {
            guard let body = try? read(meta.path, profileId: profileId) else { continue }
            for line in body.split(separator: "\n", omittingEmptySubsequences: false)
                where line.range(of: keyword, options: .caseInsensitive) != nil {
                hits.append((meta.path, String(line)))
            }
        }
        return hits
    }

    /// 二进制读写（语音条 mp3 / 附件字节走这对；粟粟侧同名 API 的最小适配版）
    static func writeData(_ relPath: String, data: Data, profileId: String) throws {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func readData(_ relPath: String, profileId: String) throws -> Data {
        guard let url = resolve(relPath, profileId: profileId) else { throw err("非法路径: \(relPath)") }
        return try Data(contentsOf: url)
    }


    // MARK: - 记忆树（只读映射）
    // memory/ 前缀 → App Support/MemoryPalace/memory/{profileId}/。对话摘要/心声/日记等
    // 内部系统写入的内容，工具层只许读（写由 InnerVoice 等内部系统经 memoryWrite 走）。

    static let memoryVirtualPrefix = "memory/"

    static func memoryRoot(profileId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MemoryPalace/memory/\(profileId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把 memory/ 虚拟路径解析成记忆树内绝对 URL，拒绝越狱。返回 nil = 非法。
    private static func resolveMemory(_ virtualPath: String, profileId: String) -> URL? {
        let trimmed = virtualPath.trimmingCharacters(in: .init(charactersIn: " "))
        let rel = (trimmed.hasPrefix(memoryVirtualPrefix) ? String(trimmed.dropFirst(memoryVirtualPrefix.count)) : trimmed)
            .trimmingCharacters(in: .init(charactersIn: "/ "))
        guard !rel.isEmpty else { return nil }
        let root = memoryRoot(profileId: profileId).standardizedFileURL
        let target = root.appendingPathComponent(rel).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") || target.path == root.path else { return nil }
        return target
    }

    /// 记忆树文件清单（路径带 memory/ 前缀，与 fs_* 工具视角一致）
    static func memoryList(profileId: String) -> [FileMeta] {
        let root = memoryRoot(profileId: profileId)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        var out: [FileMeta] = []
        for case let url as URL in en where url.pathExtension == "md" {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out.append(.init(path: memoryVirtualPrefix + rel, bytes: v?.fileSize ?? 0, modifiedAt: v?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func memoryRead(_ virtualPath: String, profileId: String) throws -> String {
        guard let url = resolveMemory(virtualPath, profileId: profileId) else { throw err("非法路径: \(virtualPath)") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func memorySearch(_ keyword: String, profileId: String) -> [(path: String, line: String)] {
        guard !keyword.isEmpty else { return [] }
        var hits: [(path: String, line: String)] = []
        for meta in memoryList(profileId: profileId) {
            guard let body = try? memoryRead(meta.path, profileId: profileId) else { continue }
            for line in body.split(separator: "\n", omittingEmptySubsequences: false)
                where line.range(of: keyword, options: .caseInsensitive) != nil {
                hits.append((meta.path, String(line)))
            }
        }
        return hits
    }

    /// 内部系统写记忆树（心声/日记）。工具层禁止写 memory/，只有 InnerVoice 等走这里。
    static func memoryWrite(_ virtualPath: String, content: String, profileId: String) throws {
        guard let url = resolveMemory(virtualPath, profileId: profileId) else { throw err("非法路径: \(virtualPath)") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "FileLibrary", code: -1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

#if DEBUG
extension FileLibraryStore {
    static func _selfCheck() {
        let pid = "selfcheck"
        try? write("a.md", content: "hello\nworld", profileId: pid)
        assert((try? read("a.md", profileId: pid)) == "hello\nworld", "read 回读失败")
        assert(resolve("../escape.md", profileId: pid) == nil, "../ 越狱未拦截")
        assert(resolve("/etc/passwd", profileId: pid) == nil, "绝对路径未拦截")
        try? edit("a.md", oldString: "world", newString: "susu", profileId: pid)
        assert((try? read("a.md", profileId: pid)) == "hello\nsusu", "edit 替换失败")
        assert(search("HELLO", profileId: pid).count == 1, "search 大小写不敏感失败")
        try? delete("a.md", profileId: pid)
        print("[FileLibraryStore] selfCheck ✅")
    }
}
#endif
