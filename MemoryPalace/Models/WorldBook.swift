import Foundation
import SwiftData

// MARK: - World Book Entry (Codable, stored as JSON inside WorldBook)

struct WorldBookEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var isEnabled: Bool = true

    // --- 触发条件 ---
    var keys: [String] = []                         // 主关键词（OR，命中任一即触发）
    var secondaryKeys: [String] = []                // 次关键词
    var selectiveLogic: SelectiveLogic = .andAny     // 主次关键词组合逻辑
    var scanDepth: Int?                              // 扫描最近几条消息（nil = 全局默认 10）
    var matchWholeWords: Bool = false
    var caseSensitive: Bool = false
    var isConstant: Bool = false                     // 常驻注入（跳过关键词匹配）

    // --- 注入内容 ---
    var content: String = ""
    var position: InsertionPosition = .afterCharDef
    var insertionOrder: Int = 100                    // 排序权重（小的先注入）
    var depth: Int = 4                               // atDepth 时从末尾往前数几条

    // --- 元数据 ---
    var comment: String = ""
    var probability: Int = 100                       // 0-100 触发概率

    // MARK: - Enums

    enum SelectiveLogic: Int, Codable, Hashable {
        case andAny  = 0    // 主词命中 AND 至少一个次词命中
        case notAll  = 1    // 主词命中 AND 非全部次词命中
        case notAny  = 2    // 主词命中 AND 无次词命中
        case andAll  = 3    // 主词命中 AND 全部次词命中
    }

    enum InsertionPosition: Int, Codable, Hashable {
        case beforeCharDef  = 0     // 角色描述之前
        case afterCharDef   = 1     // 角色描述之后
        case authorNoteTop  = 2     // Author's Note 顶部
        case authorNoteBot  = 3     // Author's Note 底部
        case atDepth        = 4     // 对话历史指定深度
        case beforeExamples = 5     // 对话示例之前
        case afterExamples  = 6     // 对话示例之后
    }
}

// MARK: - TavernCard JSON → WorldBookEntry 解析

extension WorldBookEntry {
    /// 从 TavernCard character_book.entries[] 的 JSON 字典解析
    init(from dict: [String: Any], index: Int) {
        self.id = UUID()
        self.isEnabled = dict["enabled"] as? Bool ?? true
        self.keys = dict["keys"] as? [String] ?? []
        self.secondaryKeys = dict["secondary_keys"] as? [String] ?? []
        self.comment = dict["comment"] as? String ?? ""
        self.content = dict["content"] as? String ?? ""
        self.isConstant = dict["constant"] as? Bool ?? false
        self.insertionOrder = dict["insertion_order"] as? Int ?? 100
        self.probability = 100
        self.matchWholeWords = false
        self.caseSensitive = false

        let ext = dict["extensions"] as? [String: Any] ?? [:]

        // position: extensions.position (数值) 优先，fallback 到顶层 position (字符串)
        if let posInt = ext["position"] as? Int,
           let pos = InsertionPosition(rawValue: posInt) {
            self.position = pos
        } else if let posStr = dict["position"] as? String {
            self.position = posStr == "before_char" ? .beforeCharDef : .afterCharDef
        } else {
            self.position = .afterCharDef
        }

        self.depth = ext["depth"] as? Int ?? 4
        self.scanDepth = ext["scan_depth"] as? Int

        if let logic = ext["selectiveLogic"] as? Int,
           let sl = SelectiveLogic(rawValue: logic) {
            self.selectiveLogic = sl
        }

        if let prob = ext["probability"] as? Int {
            self.probability = prob
        }
        if let mww = ext["match_whole_words"] as? Bool {
            self.matchWholeWords = mww
        }
        if let cs = ext["case_sensitive"] as? Bool {
            self.caseSensitive = cs
        }
    }
}

// MARK: - World Book (SwiftData Model)

@Model
final class WorldBook {
    #Index<WorldBook>([\.profileId])

    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var profileId: String                            // 所属楼层
    var scopeConversationId: String?                 // nil=楼层全体，有值=仅该对话生效
    var entriesData: Data                            // JSON encoded [WorldBookEntry]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 解码条目列表
    var entries: [WorldBookEntry] {
        get {
            (try? JSONDecoder().decode([WorldBookEntry].self, from: entriesData)) ?? []
        }
        set {
            entriesData = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    init(name: String, profileId: String, entries: [WorldBookEntry] = []) {
        self.name = name
        self.profileId = profileId
        self.entriesData = (try? JSONEncoder().encode(entries)) ?? Data()
    }
}
