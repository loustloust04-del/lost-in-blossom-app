import Foundation
import SwiftData
import PDFKit

/// 把外部书文件（txt 等）导进文件库 books/。
///
/// 流程：编码嗅探 → 文本归一化 → 章节切分 → 每章写 chapter_NNNN.txt → 写 index.json → 创建 BookEntry。
///
/// 章节切分思路（借鉴 astrbot_plugin_bookshelf，自己实现）：
/// 1. 优先匹配 `第N章/节/卷/回/篇/幕` （中文，N 可中文数字或阿拉伯数字）
/// 2. 兜底匹配 `CHAPTER X` （英文）
/// 3. 都找不到 → 按 4000 字均匀切，章节标题写"第 N 章"
enum BookImporter {

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsupportedEncoding
        case emptyText
        case fileTooLarge(Int)
        case duplicateName(String)   // 同 safeName 目录已存在

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "无法读取文件：\(detail)"
            case .unsupportedEncoding: return "无法识别文件编码（试过 UTF-8 / UTF-16 / GBK / GB18030 / Big5 都失败）"
            case .emptyText: return "文件内容为空"
            case .fileTooLarge(let bytes): return "文件过大（\(bytes / 1_000_000)MB），第一版限制 50MB"
            case .duplicateName(let name): return "书架里已经有一本《\(name)》了——换个书名再导，或者先删掉旧的"
            }
        }
    }

    static let maxFileBytes = 50 * 1024 * 1024
    static let fallbackChunkSize = 4000

    // MARK: - 章节正则

    /// 中文章节标题：`第一章` `第123章` `第1卷` 等，可后接副标题文字
    private static let chineseChapter = try! NSRegularExpression(
        pattern: #"(?m)^\s*第\s*[一二三四五六七八九十百千万零〇0-9]+\s*[章节卷回篇幕][^\n]{0,40}\s*$"#,
        options: []
    )

    /// 英文章节标题：`CHAPTER 1` `Chapter IV` 等
    private static let englishChapter = try! NSRegularExpression(
        pattern: #"(?m)^\s*CHAPTER\s+[0-9IVXLCDM]+[^\n]{0,60}\s*$"#,
        options: [.caseInsensitive]
    )

    // MARK: - 编码嗅探

    private static func cfEnc(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    /// 编码嗅探：系统自动识别（读 BOM）优先，再手动试 UTF-8 / UTF-16 / GB18030 / GB2312 / Big5。
    static func readTextSniffEncoding(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.isEmpty { throw ImportError.emptyText }

        // 0. 系统自动嗅探——认 BOM（UTF-8/16 记事本另存的文件最常见），最省事的第一道
        var usedEnc: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &usedEnc), !s.isEmpty {
            return s
        }

        // 1. 手动候选（不含会"永远成功但可能乱码"的 latin1——宁可报错也不给乱码）
        let candidates: [String.Encoding] = [
            .utf8,
            .utf16, .utf16LittleEndian, .utf16BigEndian,
            cfEnc(.GB_18030_2000),
            cfEnc(.GB_2312_80),
            cfEnc(.big5),
        ]
        for enc in candidates {
            if let s = String(data: data, encoding: enc), !s.isEmpty {
                // GBK/Big5 对 UTF-8 文件不返 nil 但会乱码——含太多 replacement char 判乱码
                let replacementCount = s.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
                if Double(replacementCount) / Double(max(s.count, 1)) < 0.01 { return s }
            }
        }
        throw ImportError.unsupportedEncoding
    }

    // MARK: - 文本归一化

    /// CRLF→LF + 折叠超过 2 个连续换行
    static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
        // 3+ \n → 2
        while t.contains("\n\n\n") {
            t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 章节切分

    struct Chapter {
        let title: String
        let content: String
    }

    static func splitChapters(_ text: String) -> [Chapter] {
        let normalized = normalize(text)
        if normalized.isEmpty { return [] }

        // 找所有匹配（合并中英文规则的位置）
        let range = NSRange(normalized.startIndex..., in: normalized)
        var matches: [(NSRange, String)] = []
        for m in chineseChapter.matches(in: normalized, range: range) {
            let r = m.range
            if let swiftRange = Range(r, in: normalized) {
                matches.append((r, String(normalized[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for m in englishChapter.matches(in: normalized, range: range) {
            let r = m.range
            if let swiftRange = Range(r, in: normalized) {
                matches.append((r, String(normalized[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        matches.sort { $0.0.location < $1.0.location }

        if matches.isEmpty {
            // Fallback: 按 4000 字切
            return chunkByLength(normalized, chunkChars: fallbackChunkSize)
        }

        var result: [Chapter] = []
        // 首章前的内容（前言/序）也单独成章
        if matches.first!.0.location > 200 {
            let preamble = String(normalized.prefix(matches.first!.0.location)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !preamble.isEmpty {
                result.append(Chapter(title: "序", content: preamble))
            }
        }

        for (i, match) in matches.enumerated() {
            let titleRange = match.0
            let title = match.1
            let bodyStart = titleRange.location + titleRange.length
            let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].0.location : (normalized as NSString).length
            let bodyNSRange = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
            guard let bodyRange = Range(bodyNSRange, in: normalized) else { continue }
            let body = String(normalized[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Chapter(title: title, content: body.isEmpty ? title : body))
        }

        return result
    }

    private static func chunkByLength(_ text: String, chunkChars: Int) -> [Chapter] {
        var result: [Chapter] = []
        let chars = Array(text)
        var start = 0
        var no = 1
        while start < chars.count {
            let end = min(start + chunkChars, chars.count)
            let body = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result.append(Chapter(title: "第 \(no) 章", content: body))
                no += 1
            }
            start = end
        }
        return result
    }

    // MARK: - 主入口

    struct ImportResult {
        let safeName: String
        let totalChapters: Int
        let totalChars: Int
    }

    /// 导入一个 txt 文件——**async**，IO 重活在后台 queue，SwiftData 写回 MainActor。
    ///
    /// - parameter url: 源文件本地路径
    /// - parameter bookName: 显示书名（用户填）
    /// - parameter author: 作者（可空）
    /// - parameter profileId: 当前楼层
    /// - parameter context: SwiftData ctx（用来插 BookEntry）— **必须是 MainActor 上的 ctx**
    /// - parameter progress: 进度回调（@MainActor，可安全更新 UI）
    /// CR-7：PDF 导入——原文件拷入 books/{safe}/book.pdf（不转不抽），
    /// index.json：章节表 = outline 顶层条目（tap 跳页），无 outline 退化为空表（纯页码导航）。
    /// hasTextLayer 抽样检测（前中后 12 页），false = 扫描版（批注走框选+OCR 路线）。
    static let maxPDFBytes = 500 * 1024 * 1024

    static func importPDF(
        url: URL,
        bookName: String,
        author: String = "",
        profileId: String,
        context: ModelContext,
        progress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ImportResult {
        let safeName = BookStore.safeName(bookName)
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            throw ImportError.duplicateName(bookName)
        }

        await progress?("读取 PDF…")

        let (pageCount, outlineChapters, hasText) = try await Task.detached(priority: .userInitiated) { () -> (Int, [BookStore.ChapterMeta], Bool) in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > maxPDFBytes {
                throw ImportError.fileTooLarge(size)
            }
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                throw ImportError.emptyText
            }

            // outline 顶层 → 章节表（no = 1-based 页码）
            var chapters: [BookStore.ChapterMeta] = []
            if let root = doc.outlineRoot {
                for i in 0..<root.numberOfChildren {
                    guard let child = root.child(at: i),
                          let label = child.label, !label.isEmpty,
                          let page = child.destination?.page,
                          let pageIdx = doc.index(for: page) as Int? else { continue }
                    chapters.append(.init(no: pageIdx + 1, title: label, chars: 0))
                }
            }

            // 文本层抽样：前/中/后各几页，任一页有实质文本即视为有文本层
            var sampled = 0
            let count = doc.pageCount
            let samples = [0, 1, 2, count / 4, count / 2, count * 3 / 4, count - 3, count - 2, count - 1,
                           count / 8, count * 3 / 8, count * 5 / 8].filter { $0 >= 0 && $0 < count }
            for idx in Set(samples) {
                sampled += doc.page(at: idx)?.string?.count ?? 0
            }

            // 扫描版抽样恒为 0，阈值只需挡住零星 OCR 噪声/页眉水印
            return (count, chapters, sampled > 100)
        }.value

        await progress?("拷贝文件…\(pageCount) 页")

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: bookDir.appendingPathComponent("book.pdf"))
            let now = Date()
            var index = BookStore.BookIndex(
                name: bookName,
                author: author,
                format: "pdf",
                createdAt: now,
                updatedAt: now,
                currentChapter: 1,          // PDF 语义 = 当前页（1-based）
                scrollRatio: 0,
                totalChapters: pageCount,   // PDF 语义 = 总页数
                chapters: outlineChapters
            )
            index.hasTextLayer = hasText
            try BookStore.saveIndex(index, safeName: safeName, profileId: profileId)
            try BookStore.saveNotes([], safeName: safeName, profileId: profileId)
        }.value

        await progress?("完成")

        await MainActor.run {
            BookStore.refreshEntries(profileId: profileId, context: context)
        }
        return ImportResult(safeName: safeName, totalChapters: pageCount, totalChars: 0)
    }

    /// EPUB：解压 → 按 spine 顺序取章 → 与 txt 同样落盘
    static func importEPUB(
        url: URL,
        bookName: String,
        author: String = "",
        profileId: String,
        context: ModelContext,
        progress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ImportResult {
        let safeName = BookStore.safeName(bookName)
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            throw ImportError.duplicateName(bookName)
        }

        await progress?("解压 EPUB…")

        let (chapters, metaAuthor) = try await Task.detached(priority: .userInitiated) {
            () -> ([Chapter], String) in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > maxFileBytes {
                throw ImportError.fileTooLarge(size)
            }
            let parsed = try EPUBImporter.parse(url: url)
            let chs = parsed.chapters.map { Chapter(title: $0.title, content: $0.content) }
            return (chs, parsed.author)
        }.value

        await progress?("读到 \(chapters.count) 章")

        let finalAuthor = author.isEmpty ? metaAuthor : author
        try await Task.detached(priority: .userInitiated) { [chapters] in
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            var chapterMeta: [BookStore.ChapterMeta] = []
            for (i, ch) in chapters.enumerated() {
                let no = i + 1
                try BookStore.saveChapterText(ch.content, safeName: safeName, chapterNo: no, profileId: profileId)
                chapterMeta.append(.init(no: no, title: ch.title, chars: ch.content.count))
            }
            let now = Date()
            let index = BookStore.BookIndex(
                name: bookName, author: finalAuthor, format: "epub",
                createdAt: now, updatedAt: now,
                currentChapter: 1, scrollRatio: 0,
                totalChapters: chapters.count, chapters: chapterMeta
            )
            try BookStore.saveIndex(index, safeName: safeName, profileId: profileId)
            try BookStore.saveNotes([], safeName: safeName, profileId: profileId)
        }.value

        await progress?("写入文件库…完成")
        await MainActor.run { BookStore.refreshEntries(profileId: profileId, context: context) }

        let totalChars = chapters.reduce(0) { $0 + $1.content.count }
        return ImportResult(safeName: safeName, totalChapters: chapters.count, totalChars: totalChars)
    }

    static func importTxt(
        url: URL,
        bookName: String,
        author: String = "",
        profileId: String,
        context: ModelContext,
        progress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ImportResult {
        // ① 查重——同 safeName 目录已存在 → 拒绝覆盖（爸爸 batch B1）
        let safeName = BookStore.safeName(bookName)
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            throw ImportError.duplicateName(bookName)
        }

        await progress?("读取文件…")

        // ② IO 重活全部 detach 到后台（爸爸 batch B3）
        let (chapters, _) = try await Task.detached(priority: .userInitiated) { () -> ([Chapter], Int) in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > maxFileBytes {
                throw ImportError.fileTooLarge(size)
            }
            let raw = try readTextSniffEncoding(url)
            let chs = splitChapters(raw)
            if chs.isEmpty { throw ImportError.emptyText }
            return (chs, raw.count)
        }.value

        await progress?("切分章节… \(chapters.count) 章")

        // ③ 写盘也走后台
        try await Task.detached(priority: .userInitiated) { [chapters] in
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            var chapterMeta: [BookStore.ChapterMeta] = []
            for (i, ch) in chapters.enumerated() {
                let no = i + 1
                try BookStore.saveChapterText(ch.content, safeName: safeName, chapterNo: no, profileId: profileId)
                chapterMeta.append(.init(no: no, title: ch.title, chars: ch.content.count))
            }
            let now = Date()
            let index = BookStore.BookIndex(
                name: bookName,
                author: author,
                format: "txt",
                createdAt: now,
                updatedAt: now,
                currentChapter: 1,
                scrollRatio: 0,
                totalChapters: chapters.count,
                chapters: chapterMeta
            )
            try BookStore.saveIndex(index, safeName: safeName, profileId: profileId)
            try BookStore.saveNotes([], safeName: safeName, profileId: profileId)
        }.value

        await progress?("写入文件库…完成")

        // ④ SwiftData 写回 MainActor
        await MainActor.run {
            BookStore.refreshEntries(profileId: profileId, context: context)
        }

        let totalChars = chapters.reduce(0) { $0 + $1.content.count }
        return ImportResult(safeName: safeName, totalChapters: chapters.count, totalChars: totalChars)
    }
}
