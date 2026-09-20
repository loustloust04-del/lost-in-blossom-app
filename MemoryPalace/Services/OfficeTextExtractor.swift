import Foundation
import Compression

/// docx / xlsx / pptx 原生抽文本（09-12 多附件线）：三者都是 zip 套 xml，用一个 80 行的 zip 读取器
/// + Compression 框架的 raw deflate 解开，不引第三方库。抽不出（加密 / 损坏 / 非 deflate）返回 nil，
/// 上层按「抽不出文本」处理（API 车道拒发提示只有 Caelum 能读；CC 车道照发原始字节）。
enum OfficeTextExtractor {
    static let supportedExtensions: Set<String> = ["docx", "xlsx", "pptx"]

    static func extract(data: Data, ext: String) -> String? {
        guard let zip = MiniZip(data: data) else { return nil }
        switch ext.lowercased() {
        case "docx":
            guard let xml = zip.string("word/document.xml") else { return nil }
            // 段落结束换行，其余标签剥掉
            let withBreaks = xml.replacingOccurrences(of: "</w:p>", with: "\n")
                                .replacingOccurrences(of: "<w:tab/>", with: "\t")
                                .replacingOccurrences(of: "<w:br/>", with: "\n")
            return clean(stripTags(withBreaks))
        case "pptx":
            // ppt/slides/slideN.xml 按 N 排序；每页一段
            let names = zip.entryNames.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { slideIndex($0) < slideIndex($1) }
            guard !names.isEmpty else { return nil }
            var pages: [String] = []
            for (i, n) in names.enumerated() {
                guard let xml = zip.string(n) else { continue }
                // <a:t>文字</a:t> 逐个取，段落 </a:p> 换行
                let texts = xml.replacingOccurrences(of: "</a:p>", with: "\n")
                let t = clean(stripTags(texts, keepOnlyInside: "a:t"))
                if !t.isEmpty { pages.append("[第 \(i + 1) 页]\n\(t)") }
            }
            return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
        case "xlsx":
            let shared: [String] = zip.string("xl/sharedStrings.xml").map { xml in
                // <si>…<t>文本</t>…</si>（富文本时一个 si 里多个 t，拼起来）
                matches(xml, pattern: "<si>(.*?)</si>").map { clean(stripTags($0, keepOnlyInside: "t")) }
            } ?? []
            let sheets = zip.entryNames.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { slideIndex($0) < slideIndex($1) }
            guard !sheets.isEmpty else { return nil }
            var out: [String] = []
            for (i, n) in sheets.enumerated() {
                guard let xml = zip.string(n) else { continue }
                var rows: [String] = []
                for row in matches(xml, pattern: "<row[^>]*>(.*?)</row>") {
                    var cells: [String] = []
                    for cell in matches(row, pattern: "<c [^>]*>(.*?)</c>", includeWhole: true) {
                        let isShared = cell.contains("t=\"s\"")
                        let v = matches(cell, pattern: "<v>(.*?)</v>").first
                            ?? matches(cell, pattern: "<t[^>]*>(.*?)</t>").first ?? ""
                        if isShared, let idx = Int(v), idx < shared.count { cells.append(shared[idx]) }
                        else { cells.append(decodeEntities(v)) }
                    }
                    let line = cells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { rows.append(line) }
                }
                if !rows.isEmpty { out.append("[表 \(i + 1)]\n" + rows.joined(separator: "\n")) }
            }
            return out.isEmpty ? nil : out.joined(separator: "\n\n")
        default:
            return nil
        }
    }

    // MARK: - xml 小工具
    private static func slideIndex(_ name: String) -> Int {
        Int(name.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }
    private static func matches(_ s: String, pattern: String, includeWhole: Bool = false) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = includeWhole ? m.range : m.range(at: 1)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
    /// 剥标签。keepOnlyInside 给定时只保留该标签内的文字（pptx 的 a:t / xlsx 的 t），其余全丢
    private static func stripTags(_ s: String, keepOnlyInside tag: String? = nil) -> String {
        if let tag {
            let inner = matches(s, pattern: "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>")
            let joined = inner.joined()
            return decodeEntities(joined) + (s.contains("\n") ? "\n" : "")
        }
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(stripped)
    }
    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func clean(_ s: String) -> String {
        s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
         .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// 最小 zip 读取器：读 End of Central Directory → 中央目录 → 按名取条目，stored 直接给、deflate 用
/// Compression（COMPRESSION_ZLIB 就是 raw deflate）解开。不支持 zip64 / 加密（Office 文件没有这些）。
struct MiniZip {
    private struct Entry { let offset: Int; let method: UInt16; let compSize: Int; let size: Int }
    private let data: Data
    private var entries: [String: Entry] = [:]
    var entryNames: [String] { Array(entries.keys) }

    init?(data: Data) {
        self.data = data
        // EOCD 签名 0x06054b50，从尾部往前找（注释最多 64KB）
        guard data.count >= 22 else { return nil }
        var eocd = -1
        var i = data.count - 22
        let stop = max(0, data.count - 22 - 65_536)
        while i >= stop { if u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return nil }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))   // 中央目录起点
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(p) == 0x02014b50 else { return nil }
            let method = u16(p + 10)
            let compSize = Int(u32(p + 20)), size = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28)), extraLen = Int(u16(p + 30)), commentLen = Int(u16(p + 32))
            let localOffset = Int(u32(p + 42))
            guard p + 46 + nameLen <= data.count else { return nil }
            let name = String(data: data[(p + 46)..<(p + 46 + nameLen)], encoding: .utf8) ?? ""
            entries[name] = Entry(offset: localOffset, method: method, compSize: compSize, size: size)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func bytes(_ name: String) -> Data? {
        guard let e = entries[name], e.offset + 30 <= data.count, u32(e.offset) == 0x04034b50 else { return nil }
        let nameLen = Int(u16(e.offset + 26)), extraLen = Int(u16(e.offset + 28))
        let start = e.offset + 30 + nameLen + extraLen
        guard start + e.compSize <= data.count else { return nil }
        let comp = data[start..<(start + e.compSize)]
        switch e.method {
        case 0: return Data(comp)
        case 8: return inflate(Data(comp), expected: e.size)
        default: return nil
        }
    }
    func string(_ name: String) -> String? { bytes(name).flatMap { String(data: $0, encoding: .utf8) } }

    private func inflate(_ src: Data, expected: Int) -> Data? {
        let cap = max(expected, 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = src.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst, cap, base, src.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }
    private func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | (UInt16(data[i + 1]) << 8) }
    private func u32(_ i: Int) -> UInt32 {
        UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }
}
