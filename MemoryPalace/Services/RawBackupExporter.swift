import Foundation
import SQLite3
import CryptoKit
import ZIPFoundation

/// 原样整包备份（迁移前保命用，BunnyPalace-Next Phase A）。
///
/// 只读：不修改、不移动、不删除任何主位文件。
/// - Application Support / Documents 下所有普通文件原样打包；
/// - SQLite 文件（unified.store 等）用 SQLite backup API 拍一致快照，-wal/-shm 由快照覆盖、不再单独打包；
/// - UserDefaults 本 App 域导出为 settings/UserDefaults.plist；
/// - Keychain（API Key 等）不导出；
/// - manifest.json 记录每个文件的大小与 SHA256、每个库的 integrity_check 与各表行数。
enum RawBackupExporter {
    static let format = "bunnypalace-raw-backup"
    static let formatVersion = 1

    struct FileRecord: Codable {
        let path: String
        let size: Int64
        let sha256: String
        let kind: String   // file | sqlite-snapshot | userdefaults
    }

    struct SQLiteRecord: Codable {
        let path: String
        let integrity: String
        let tables: [String: Int]
    }

    struct Manifest: Codable {
        let format: String
        let formatVersion: Int
        let createdAt: Date
        let bundleId: String
        let appVersion: String
        let appBuild: String
        let systemVersion: String
        let deviceModel: String
        var files: [FileRecord]
        var sqlite: [SQLiteRecord]
        var userDefaultsKeyCount: Int
        var coveredSidecars: [String]
        var skipped: [String]
        let notes: [String]
    }

    struct Result {
        let zipURL: URL
        let zipSize: Int64
        let zipSHA256: String
        let fileCount: Int
        let totalBytes: Int64
        let skipped: [String]
        let integrityProblems: [String]
    }

    enum ExportError: LocalizedError {
        case sqlite(String)
        case noSpace(need: Int64, have: Int64)
        var errorDescription: String? {
            switch self {
            case .sqlite(let s): return "数据库快照失败：\(s)"
            case .noSpace(let need, let have):
                let f = ByteCountFormatter()
                return "手机剩余空间不够：大约需要 \(f.string(fromByteCount: need))，现在只有 \(f.string(fromByteCount: have))"
            }
        }
    }

    private struct Source {
        let url: URL
        let entryPath: String
        let size: Int64
    }

    /// 在后台线程调用。progress(done, total, 当前项)
    static func run(progress: @escaping (Int, Int, String) -> Void) throws -> Result {
        let fm = FileManager.default
        let workRoot = fm.temporaryDirectory.appendingPathComponent("RawBackup", isDirectory: true)
        try? fm.removeItem(at: workRoot)          // 只清自己上次的临时产物
        let snapshotDir = workRoot.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        // 1. 收集文件
        var roots: [(URL, String)] = []
        if let a = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { roots.append((a, "AppSupport")) }
        if let d = fm.urls(for: .documentDirectory, in: .userDomainMask).first { roots.append((d, "Documents")) }

        var all: [Source] = []
        var skipped: [String] = []
        for (root, prefix) in roots {
            let rootPath = root.resolvingSymlinksInPath().path
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { url, err in
                skipped.append("\(url.lastPathComponent): \(err.localizedDescription)")
                return true
            }) else { continue }
            for case let url as URL in en {
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if v?.isSymbolicLink == true { continue }
                guard v?.isRegularFile == true else { continue }
                let full = url.resolvingSymlinksInPath().path
                guard full.hasPrefix(rootPath + "/") else { continue }
                let rel = String(full.dropFirst(rootPath.count + 1))
                all.append(Source(url: url, entryPath: "\(prefix)/\(rel)", size: Int64(v?.fileSize ?? 0)))
            }
        }

        let sqlitePaths = Set(all.filter { isSQLite($0.url) }.map { $0.url.resolvingSymlinksInPath().path })
        var plain: [Source] = []
        var dbs: [Source] = []
        var covered: [String] = []
        for s in all {
            let p = s.url.resolvingSymlinksInPath().path
            if sqlitePaths.contains(p) { dbs.append(s); continue }
            if let base = sidecarBase(p), sqlitePaths.contains(base) { covered.append(s.entryPath); continue }
            plain.append(s)
        }

        // 2. 空间检查（快照 + zip，保守按原始总量 + 200MB）
        let totalBytes = all.reduce(Int64(0)) { $0 + $1.size }
        let need = totalBytes + 200 * 1024 * 1024
        if let have = (try? workRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           have < need {
            throw ExportError.noSpace(need: need, have: have)
        }

        let total = plain.count + dbs.count + 2
        var done = 0
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let zipURL = workRoot.appendingPathComponent("BunnyBackup-\(stamp).zip")
        let archive = try Archive(url: zipURL, accessMode: .create)

        var files: [FileRecord] = []
        var sqliteRecords: [SQLiteRecord] = []
        var integrityProblems: [String] = []

        // 3. 数据库快照
        for (i, s) in dbs.enumerated() {
            progress(done, total, "数据库快照 \(s.url.lastPathComponent)")
            let snap = snapshotDir.appendingPathComponent("db-\(i).sqlite")
            try snapshotSQLite(src: s.url, dst: snap)
            let (integrity, tables) = inspectSQLite(snap)
            if integrity != "ok" { integrityProblems.append("\(s.entryPath): \(integrity)") }
            sqliteRecords.append(SQLiteRecord(path: s.entryPath, integrity: integrity, tables: tables))
            let size = Int64((try? snap.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            files.append(FileRecord(path: s.entryPath, size: size, sha256: try sha256(of: snap), kind: "sqlite-snapshot"))
            try archive.addEntry(with: s.entryPath, fileURL: snap, compressionMethod: .deflate)
            try? fm.removeItem(at: snap)
            done += 1
        }

        // 4. 普通文件
        for s in plain {
            progress(done, total, s.url.lastPathComponent)
            do {
                try autoreleasepool {
                    let hash = try sha256(of: s.url)
                    try archive.addEntry(with: s.entryPath, fileURL: s.url, compressionMethod: .deflate)
                    files.append(FileRecord(path: s.entryPath, size: s.size, sha256: hash, kind: "file"))
                }
            } catch {
                skipped.append("\(s.entryPath): \(error.localizedDescription)")
            }
            done += 1
        }

        // 5. UserDefaults
        progress(done, total, "设置")
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let domain = UserDefaults.standard.persistentDomain(forName: bundleId) ?? [:]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            let url = snapshotDir.appendingPathComponent("UserDefaults.plist")
            try data.write(to: url)
            let path = "settings/UserDefaults.plist"
            files.append(FileRecord(path: path, size: Int64(data.count), sha256: try sha256(of: url), kind: "userdefaults"))
            try archive.addEntry(with: path, fileURL: url, compressionMethod: .deflate)
        } catch {
            skipped.append("settings/UserDefaults.plist: \(error.localizedDescription)")
        }
        done += 1

        // 6. manifest
        progress(done, total, "清单")
        let info = Bundle.main.infoDictionary ?? [:]
        let manifest = Manifest(
            format: format,
            formatVersion: formatVersion,
            createdAt: Date(),
            bundleId: bundleId,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info["CFBundleVersion"] as? String ?? "",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: machineName(),
            files: files,
            sqlite: sqliteRecords,
            userDefaultsKeyCount: domain.count,
            coveredSidecars: covered,
            skipped: skipped,
            notes: [
                "SQLite 文件为 backup API 一致快照，-wal/-shm 已并入快照，见 coveredSidecars",
                "Keychain（API Key 等凭据）未导出，迁移后需重新填写",
                "本包含私人聊天与设置，请勿上传到公开位置"
            ]
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = snapshotDir.appendingPathComponent("manifest.json")
        try enc.encode(manifest).write(to: manifestURL)
        try archive.addEntry(with: "manifest.json", fileURL: manifestURL, compressionMethod: .deflate)
        done += 1
        progress(done, total, "完成")

        try? fm.removeItem(at: snapshotDir)
        let zipSize = Int64((try? zipURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return Result(zipURL: zipURL, zipSize: zipSize, zipSHA256: try sha256(of: zipURL),
                      fileCount: files.count, totalBytes: totalBytes, skipped: skipped,
                      integrityProblems: integrityProblems)
    }

    // MARK: - Helpers

    static func isSQLite(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 16) else { return false }
        return d == Data("SQLite format 3\u{0}".utf8)
    }

    static func sidecarBase(_ path: String) -> String? {
        for suffix in ["-wal", "-shm", "-journal"] where path.hasSuffix(suffix) {
            return String(path.dropLast(suffix.count))
        }
        return nil
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data = try autoreleasepool { try h.read(upToCount: 1 << 20) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func snapshotSQLite(src: URL, dst: URL) throws {
        var srcDB: OpaquePointer?
        guard sqlite3_open_v2(src.path, &srcDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = srcDB.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            sqlite3_close(srcDB)
            throw ExportError.sqlite("\(src.lastPathComponent) \(msg)")
        }
        defer { sqlite3_close(srcDB) }
        sqlite3_busy_timeout(srcDB, 5000)

        var dstDB: OpaquePointer?
        guard sqlite3_open_v2(dst.path, &dstDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(dstDB)
            throw ExportError.sqlite("\(src.lastPathComponent) 无法创建快照文件")
        }
        defer { sqlite3_close(dstDB) }

        guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
            throw ExportError.sqlite("\(src.lastPathComponent) \(String(cString: sqlite3_errmsg(dstDB)))")
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 256)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(50) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else {
            throw ExportError.sqlite("\(src.lastPathComponent) backup rc=\(rc)")
        }
        // 快照改回普通日志模式：单文件、无 -wal 残留
        sqlite3_exec(dstDB, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
    }

    static func inspectSQLite(_ url: URL) -> (String, [String: Int]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return ("open failed", [:])
        }
        defer { sqlite3_close(db) }
        func query(_ sql: String) -> [String] {
            var stmt: OpaquePointer?
            var out: [String] = []
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            }
            return out
        }
        let integrity = query("PRAGMA integrity_check;").joined(separator: "; ")
        var tables: [String: Int] = [:]
        for name in query("SELECT name FROM sqlite_master WHERE type='table';") {
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if let n = query("SELECT count(*) FROM \(quoted);").first, let v = Int(n) { tables[name] = v }
        }
        return (integrity.isEmpty ? "unknown" : integrity, tables)
    }

    static func machineName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
