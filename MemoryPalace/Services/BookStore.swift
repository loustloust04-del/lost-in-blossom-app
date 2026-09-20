import Foundation
import SwiftData

/// 读书功能的文件库子目录管理 + index/notes JSON 读写。
///
/// 物理布局（楼层独立）：
/// ```
/// filesystem/
///   books/
///     {safeName}/                    ← 一本书一个目录
///       index.json                   ← 元数据 + 章节列表 + 进度
///       chapter_0001.txt             ← 章节正文
///       chapter_0002.txt
///       ...
///       notes.json                   ← 笔记/批注列表
///       cover.jpg                    ← 可选封面原图
/// ```
///
/// 设计要点：
/// - 章节正文/笔记**不进 SwiftData**——SwiftData 只放 BookEntry 索引行供 SwiftUI 反应式更新
/// - 走文件库的 filesystem/，自动跟随楼层 iCloud 开关同步
/// - safeName 防路径穿越（思路借鉴 astrbot_plugin_bookshelf；自己实现）
enum BookStore {

    // MARK: - 目录

    static let booksFolderName = "books"

    /// `filesystem/books/`
    static func booksRoot(profileId: String) -> URL {
        let dir = FileLibraryStore.libraryRoot(profileId: profileId)
            .appendingPathComponent(booksFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `filesystem/books/{safeName}/`
    static func bookDir(safeName: String, profileId: String) -> URL {
        booksRoot(profileId: profileId).appendingPathComponent(safeName, isDirectory: true)
    }

    static func indexURL(safeName: String, profileId: String) -> URL {
        bookDir(safeName: safeName, profileId: profileId).appendingPathComponent("index.json")
    }

    static func notesURL(safeName: String, profileId: String) -> URL {
        bookDir(safeName: safeName, profileId: profileId).appendingPathComponent("notes.json")
    }

    static func chapterURL(safeName: String, chapterNo: Int, profileId: String) -> URL {
        let name = String(format: "chapter_%04d.txt", chapterNo)
        return bookDir(safeName: safeName, profileId: profileId).appendingPathComponent(name)
    }

    static func coverURL(safeName: String, profileId: String) -> URL {
        bookDir(safeName: safeName, profileId: profileId).appendingPathComponent("cover.jpg")
    }

    // MARK: - safeName 防穿越

    /// 把书名转换成可作目录名的安全字符串，去掉 `/\:*?"<>|` 和 `..`，截到 80 字符。
    /// 空 → "未命名书籍"。
    static func safeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "..", with: "_")
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        s = s.unicodeScalars
            .map { illegal.contains($0) ? "_" : Character($0) }
            .map { String($0) }
            .joined()
        if s.count > 80 { s = String(s.prefix(80)) }
        return s.isEmpty ? "未命名书籍" : s
    }

    // MARK: - JSON schema（与 plan-read-something-v1.md 对齐）

    struct BookIndex: Codable {
        var name: String
        var author: String
        var format: String
        var createdAt: Date
        var updatedAt: Date
        var currentChapter: Int
        var scrollRatio: Double
        var totalChapters: Int
        var chapters: [ChapterMeta]
        /// CR-7 PDF：false = 扫描版（无文本层，批注走框选+OCR 路线）。txt 书恒 nil。
        var hasTextLayer: Bool? = nil
    }

    struct ChapterMeta: Codable, Identifiable {
        var no: Int
        var title: String
        var chars: Int
        var id: Int { no }
    }

    /// 笔记/批注。kind 含义：
    /// - `highlight`：用户高亮（仅颜色，无内容）
    /// - `note`：用户写的笔记（content 是用户输入）
    /// - `aiBubble`：AI 批注气泡（楼层角色对选段的回应；content 是 AI 输出）
    struct Note: Codable, Identifiable {
        var id: String                  // UUID 字符串
        var chapter: Int
        var anchorText: String          // 选段原文，跨设备/重新解析重定位用
        var anchorStart: Int            // 章节内字符 offset（重新解析后可能漂移）
        var anchorEnd: Int
        var kind: String                // "highlight" | "note" | "aiBubble"
        var content: String
        var role: String                // "user" | "ai"
        var messageId: String?          // 对应楼层主对话的 MessageNode.id（双向锚定）
        var createdAt: Date
        /// CR-1 批注成串：指向父批注 id（nil = 顶层）。老 json 自动 nil。
        var replyTo: String? = nil
        /// CR-7 PDF 保真锚：页坐标矩形组 [x,y,w,h]（cropBox 系，原点左下）。
        /// 非空 = fidelity 卡（PDF 书批注，此时 chapter 语义 = 页码，anchorStart/End 恒 0）。
        var rects: [[Double]]? = nil
    }

    /// F1 书签：标个位置回头看（与自动进度独立）。
    /// txt 书 chapter=章号 + scrollRatio；PDF 书 chapter=页码（scrollRatio 恒 0）。
    struct Bookmark: Codable, Identifiable {
        var id: String
        var chapter: Int
        var scrollRatio: Double
        var title: String               // 自动生成（章名/页头），不让用户起名
        var createdAt: Date
    }

    // MARK: - JSON 读写（原子，借鉴 bookshelf）

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 原子写：写到 .tmp 再 rename，防止中途崩 → JSON 损坏。
    private static func atomicWriteJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func loadIndex(safeName: String, profileId: String) -> BookIndex? {
        let url = indexURL(safeName: safeName, profileId: profileId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(BookIndex.self, from: data)
    }

    static func saveIndex(_ index: BookIndex, safeName: String, profileId: String) throws {
        try atomicWriteJSON(index, to: indexURL(safeName: safeName, profileId: profileId))
    }

    static func loadNotes(safeName: String, profileId: String) -> [Note] {
        let url = notesURL(safeName: safeName, profileId: profileId)
        guard let data = try? Data(contentsOf: url),
              let notes = try? decoder.decode([Note].self, from: data) else { return [] }
        return notes
    }

    static func saveNotes(_ notes: [Note], safeName: String, profileId: String) throws {
        try atomicWriteJSON(notes, to: notesURL(safeName: safeName, profileId: profileId))
    }

    // MARK: - F1 书签

    static func bookmarksURL(safeName: String, profileId: String) -> URL {
        bookDir(safeName: safeName, profileId: profileId).appendingPathComponent("bookmarks.json")
    }

    static func loadBookmarks(safeName: String, profileId: String) -> [Bookmark] {
        guard let data = try? Data(contentsOf: bookmarksURL(safeName: safeName, profileId: profileId)),
              let bms = try? decoder.decode([Bookmark].self, from: data) else { return [] }
        return bms
    }

    static func saveBookmarks(_ bms: [Bookmark], safeName: String, profileId: String) throws {
        try atomicWriteJSON(bms, to: bookmarksURL(safeName: safeName, profileId: profileId))
    }

    /// 当前位置存/删 toggle：同 chapter 已有书签 → 删并返回 false；否则存并返回 true。
    @discardableResult
    static func toggleBookmark(safeName: String, profileId: String,
                               chapter: Int, scrollRatio: Double, title: String) -> Bool {
        var bms = loadBookmarks(safeName: safeName, profileId: profileId)
        if let idx = bms.firstIndex(where: { $0.chapter == chapter }) {
            bms.remove(at: idx)
            try? saveBookmarks(bms, safeName: safeName, profileId: profileId)
            return false
        }
        bms.append(Bookmark(id: UUID().uuidString, chapter: chapter,
                            scrollRatio: scrollRatio, title: title, createdAt: Date()))
        bms.sort { $0.chapter < $1.chapter }
        try? saveBookmarks(bms, safeName: safeName, profileId: profileId)
        return true
    }

    /// 按书名找 safeName（模糊匹配）。Caelum 递批注时只给书名，这里换成目录名。
    static func safeNameMatching(bookName: String, profileId: String) -> String? {
        let root = booksRoot(profileId: profileId)
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var fuzzy: String? = nil
        for d in dirs {
            guard let idx = loadIndex(safeName: d, profileId: profileId) else { continue }
            if idx.name == bookName { return d }
            if fuzzy == nil, idx.name.contains(bookName) || bookName.contains(idx.name) { fuzzy = d }
        }
        return fuzzy
    }

    /// 共读：他按书名+章号要正文（走在她前面读）。书名模糊匹配，chapterNo=0 表示要目录。
    /// 返回 (正文, 书名/章号/总章数/章节标题)；找不到则正文为 nil。
    static func chapterForCompanion(bookName: String, chapterNo: Int)
        -> (String?, (book: String, chapter: Int, total: Int, title: String)) {
        let pid = UserDefaults.standard.string(forKey: "coread.profileId") ?? ""
        let root = booksRoot(profileId: pid)
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        // 先精确后模糊，都按 index.json 里的书名比
        var hit: (safe: String, idx: BookIndex)? = nil
        for d in dirs {
            guard let idx = loadIndex(safeName: d, profileId: pid) else { continue }
            if idx.name == bookName { hit = (d, idx); break }
            if hit == nil, bookName.isEmpty || idx.name.contains(bookName) || bookName.contains(idx.name) {
                hit = (d, idx)
            }
        }
        guard let hit else { return (nil, (bookName, chapterNo, 0, "")) }
        let idx = hit.idx

        // chapterNo <= 0：给目录
        if chapterNo <= 0 {
            let toc = idx.chapters.map { "\($0.no). \($0.title)" }.joined(separator: "\n")
            return ("【目录】共 \(idx.totalChapters) 章，她读到第 \(idx.currentChapter) 章\n\n" + toc,
                    (idx.name, 0, idx.totalChapters, "目录"))
        }
        let title = idx.chapters.first { $0.no == chapterNo }?.title ?? ""
        let text = loadChapterText(safeName: hit.safe, chapterNo: chapterNo, profileId: pid)
        return (text, (idx.name, chapterNo, idx.totalChapters, title))
    }

    static func loadChapterText(safeName: String, chapterNo: Int, profileId: String) -> String? {
        let url = chapterURL(safeName: safeName, chapterNo: chapterNo, profileId: profileId)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func saveChapterText(_ text: String, safeName: String, chapterNo: Int, profileId: String) throws {
        let url = chapterURL(safeName: safeName, chapterNo: chapterNo, profileId: profileId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 目录扫描 + SwiftData 索引同步

    /// 扫 filesystem/books/*/ 与 SwiftData 里的 BookEntry 行做双向 sync：
    /// - 文件夹有 + SwiftData 无 → 建 BookEntry（需要 index 才能建；index 没下下来则跳过本轮等下次）
    /// - SwiftData 有 + 文件夹无 → 删 BookEntry（书被外部删了）
    /// - 都有 → 更新 BookEntry 字段（书名/进度/章数）；index 读不出**不删** entry（爸爸 batch B2）
    ///
    /// ⚠️ iCloud 同步抖动语义：文件夹存在但 index.json 还是占位符 `.icloud`/解析失败 ≠ 书没了。
    /// 把「文件夹真没了」（diskSafeNames）和「index 读不出」分开判：
    /// - 第一阶段：纯扫子目录名 → diskSafeNames（不依赖 index）
    /// - 第二阶段：能读 index 的更新字段；读不出的跳过更新但保留 entry
    ///
    /// 同步路径（async）：扫盘 + JSON 解码在 Task.detached 后台跑（爸爸 batch B3），
    /// SwiftData 写回 MainActor。`refreshEntries(profileId:context:)` 是同步入口（向后兼容），
    /// 内部就是 `Task { await refreshEntriesAsync(...) }`——首屏 onAppear 调它不阻塞 UI。
    @MainActor
    static func refreshEntries(profileId: String, context: ModelContext) {
        Task { await refreshEntriesAsync(profileId: profileId, context: context) }
    }

    @MainActor
    static func refreshEntriesAsync(profileId: String, context: ModelContext) async {
        let root = booksRoot(profileId: profileId)

        // 阶段 0（仅 iOS）：给 books/ 下的 .icloud placeholder 触发下载，否则 iOS 永远读不到云端书。
        // macOS 走 Mobile Documents 裸路径，文件自动下，不需 trigger。
        #if os(iOS)
        triggerICloudDownloadIfNeeded(at: root)
        #endif

        // 阶段 1：后台扫盘 + 读 index（IO 不卡 UI）
        struct ScanResult {
            var diskSafeNames: Set<String> = []   // 文件夹真存在的（不依赖 index 解析）
            var loadedIndices: [String: BookIndex] = [:]   // 成功解析的 index
        }

        let scan = await Task.detached(priority: .utility) { () -> ScanResult in
            var r = ScanResult()
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return r
            }
            for dir in dirs {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let safeName = dir.lastPathComponent
                // 文件夹存在就计入——index 读得读不出是另一回事
                r.diskSafeNames.insert(safeName)
                if let idx = loadIndex(safeName: safeName, profileId: profileId) {
                    r.loadedIndices[safeName] = idx
                }
            }
            return r
        }.value

        // 阶段 2：SwiftData 写回（MainActor）
        let pid = profileId
        for (safeName, idx) in scan.loadedIndices {
            let descriptor = FetchDescriptor<BookEntry>(
                predicate: #Predicate<BookEntry> { $0.id == safeName && $0.profileId == pid }
            )
            let entry: BookEntry
            if let existing = (try? context.fetch(descriptor))?.first {
                entry = existing
            } else {
                entry = BookEntry(
                    id: safeName,
                    profileId: profileId,
                    name: idx.name,
                    author: idx.author,
                    format: idx.format,
                    totalChapters: idx.totalChapters
                )
                entry.addedAt = idx.createdAt
                context.insert(entry)
            }
            entry.name = idx.name
            entry.author = idx.author
            entry.format = idx.format
            entry.totalChapters = idx.totalChapters
            entry.currentChapter = idx.currentChapter
            entry.scrollRatio = idx.scrollRatio
        }

        // 阶段 3：清孤儿——只在「文件夹真没了」时删 entry（diskSafeNames，**不**用 loadedIndices）
        let allDescriptor = FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.profileId == pid }
        )
        for entry in (try? context.fetch(allDescriptor)) ?? [] where !scan.diskSafeNames.contains(entry.id) {
            context.delete(entry)
        }

        try? context.save()
    }

    /// M5：iOS 给 books/ 下的 .icloud placeholder 触发下载（书目录 + 内部 index/notes/章节）。
    /// macOS 走 Mobile Documents 裸路径不需要——文件自动下。
    /// 触发后立刻返回，下次 refreshEntries 时（5s 后 Timer 触发）应该已经下完。
    #if os(iOS)
    static func triggerICloudDownloadIfNeeded(at root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: []
        ) else { return }
        for item in items {
            // .icloud 文件名 / 状态非 .current → 触发下载
            if item.lastPathComponent.hasSuffix(".icloud") || isNotDownloaded(item) {
                try? fm.startDownloadingUbiquitousItem(at: item)
                continue
            }
            // 子目录递归（书目录里的 index.json / chapter_*.txt / notes.json）
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if let inner = try? fm.contentsOfDirectory(
                    at: item, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]
                ) {
                    for f in inner {
                        if f.lastPathComponent.hasSuffix(".icloud") || isNotDownloaded(f) {
                            try? fm.startDownloadingUbiquitousItem(at: f)
                        }
                    }
                }
            }
        }
    }

    private static func isNotDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }
    #endif

    /// 永久删一本书：物理删文件夹 + cascade 删 BookEntry 行。
    @MainActor
    static func deleteBook(safeName: String, profileId: String, context: ModelContext) {
        let dir = bookDir(safeName: safeName, profileId: profileId)
        try? FileManager.default.removeItem(at: dir)

        let pid = profileId
        let descriptor = FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.id == safeName && $0.profileId == pid }
        )
        if let entry = (try? context.fetch(descriptor))?.first {
            context.delete(entry)
            try? context.save()
        }
    }
}
