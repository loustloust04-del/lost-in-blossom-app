import Foundation
import SwiftData
import ZIPFoundation

/// EPUB 导入。
/// EPUB 本质是个 zip：META-INF/container.xml 指向 .opf，.opf 里的 spine 给出阅读顺序，
/// 每一项是一个 (X)HTML 文件。我们按 spine 顺序读，剥掉标签取正文，一项一章。
/// 章节标题优先取 HTML 里的 h1/h2/title，取不到就用 toc.ncx 的 navPoint，再不行才用「第 N 章」。
enum EPUBImporter {

    struct Chapter { let title: String; let content: String }

    /// 解析出章节列表 + 书名/作者（元数据取不到时留空，由调用方兜底）
    static func parse(url: URL) throws -> (chapters: [Chapter], title: String, author: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: url, to: tmp)

        // ① container.xml → .opf 路径
        let containerURL = tmp.appendingPathComponent("META-INF/container.xml")
        let containerXML = (try? String(contentsOf: containerURL, encoding: .utf8)) ?? ""
        guard let opfRel = firstMatch(in: containerXML, pattern: #"full-path="([^"]+)""#) else {
            throw BookImporter.ImportError.emptyText
        }
        let opfURL = tmp.appendingPathComponent(opfRel)
        let opfDir = opfURL.deletingLastPathComponent()
        let opf = (try? String(contentsOf: opfURL, encoding: .utf8)) ?? ""
        guard !opf.isEmpty else { throw BookImporter.ImportError.emptyText }

        // ② 元数据
        let title = firstMatch(in: opf, pattern: #"<dc:title[^>]*>([^<]+)</dc:title>"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = firstMatch(in: opf, pattern: #"<dc:creator[^>]*>([^<]+)</dc:creator>"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // ③ manifest: id → href
        var hrefById: [String: String] = [:]
        for m in allMatches(in: opf, pattern: #"<item\s+[^>]*/?>"#) {
            guard let id = firstMatch(in: m, pattern: #"id="([^"]+)""#),
                  let href = firstMatch(in: m, pattern: #"href="([^"]+)""#) else { continue }
            hrefById[id] = href
        }

        // ④ spine 顺序
        var order: [String] = []
        if let spine = firstMatch(in: opf, pattern: #"<spine[^>]*>([\s\S]*?)</spine>"#) {
            for m in allMatches(in: spine, pattern: #"<itemref\s+[^>]*/?>"#) {
                if let idref = firstMatch(in: m, pattern: #"idref="([^"]+)""#) { order.append(idref) }
            }
        }
        if order.isEmpty { order = Array(hrefById.keys) }

        // ⑤ toc.ncx 的标题（href 去锚点 → 标题）
        var tocTitles: [String: String] = [:]
        if let ncxHref = hrefById.values.first(where: { $0.hasSuffix(".ncx") }) {
            let ncx = (try? String(contentsOf: opfDir.appendingPathComponent(ncxHref), encoding: .utf8)) ?? ""
            for np in allMatches(in: ncx, pattern: #"<navPoint[\s\S]*?</navPoint>"#) {
                guard let t = firstMatch(in: np, pattern: #"<text>([^<]+)</text>"#),
                      let src = firstMatch(in: np, pattern: #"src="([^"]+)""#) else { continue }
                tocTitles[src.components(separatedBy: "#")[0]] = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // ⑥ 按 spine 逐项取正文
        var chapters: [Chapter] = []
        for id in order {
            guard let href = hrefById[id] else { continue }
            let ext = (href as NSString).pathExtension.lowercased()
            guard ["xhtml", "html", "htm"].contains(ext) else { continue }
            let fileURL = opfDir.appendingPathComponent(href)
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8), !raw.isEmpty else { continue }

            let body = stripHTML(raw)
            guard body.count > 30 else { continue }   // 跳过封面页、版权页那种

            let t = firstMatch(in: raw, pattern: #"<h[12][^>]*>([\s\S]*?)</h[12]>"#).map(stripHTML)
                ?? tocTitles[href]
                ?? firstMatch(in: raw, pattern: #"<title[^>]*>([^<]+)</title>"#)
                ?? ""
            let cleanTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(Chapter(
                title: cleanTitle.isEmpty ? "第 \(chapters.count + 1) 章" : String(cleanTitle.prefix(60)),
                content: body))
        }
        guard !chapters.isEmpty else { throw BookImporter.ImportError.emptyText }
        return (chapters, title, author)
    }

    /// 剥标签取正文：先去掉 script/style，块级标签转换行，实体解码，再压多余空行
    static func stripHTML(_ html: String) -> String {
        var s = html
        for p in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<head[\s\S]*?</head>"#] {
            s = replace(s, pattern: p, with: "")
        }
        // 块级 → 换行（否则段落会黏成一坨）
        s = replace(s, pattern: #"<br\s*/?>"#, with: "\n")
        s = replace(s, pattern: #"</(p|div|h[1-6]|li|tr|blockquote)>"#, with: "\n")
        s = replace(s, pattern: #"<[^>]+>"#, with: "")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&mdash;": "—", "&hellip;": "…",
                        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = replace(s, pattern: #"&#(\d+);"#, with: "")   // 剩余数字实体直接去掉
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = replace(s, pattern: #"[ \t]+\n"#, with: "\n")
        s = replace(s, pattern: #"\n{3,}"#, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 正则小工具

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
    private static func allMatches(in s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            let idx = $0.numberOfRanges > 1 ? 1 : 0
            guard let r = Range($0.range(at: idx), in: s) else { return nil }
            return String(s[r])
        }
    }
    private static func replace(_ s: String, pattern: String, with t: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
}
