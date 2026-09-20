import Foundation
import SwiftData

// MARK: - Character Card (全局资产，存 UserDefaults)

struct CharacterCard: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var description: String = ""
    var personality: String = ""
    var scenario: String = ""
    var firstMes: String = ""
    var alternateGreetings: [String] = []
    var mesExample: String = ""
    var systemPrompt: String = ""
    var postHistoryInstructions: String = ""
    var creatorNotes: String = ""
    var imageData: Data?
    var characterBookName: String?
    var characterBookEntriesData: Data?  // JSON encoded [[String: Any]]
    var createdAt: Date = Date()

    /// 是否包含世界书
    var hasWorldBook: Bool {
        if let data = characterBookEntriesData,
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return !entries.isEmpty
        }
        return false
    }

    /// 世界书条目数
    var worldBookEntryCount: Int {
        guard let data = characterBookEntriesData,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return entries.count
    }

    /// 世界书原始条目
    var characterBookEntries: [[String: Any]] {
        guard let data = characterBookEntriesData,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries
    }

    /// 从 TavernCard 解析结果转换
    init(from card: TavernCard) {
        self.name = card.name
        self.description = card.description
        self.personality = card.personality
        self.scenario = card.scenario
        self.firstMes = card.firstMes
        self.alternateGreetings = card.alternateGreetings
        self.mesExample = card.mesExample
        self.systemPrompt = card.systemPrompt
        self.postHistoryInstructions = card.postHistoryInstructions
        self.creatorNotes = card.creatorNotes
        self.imageData = card.imageData
        self.characterBookName = card.characterBookName
        // characterBookEntries 是 [[String: Any]]，不能直接 Codable，转 JSON Data
        if !card.characterBookEntries.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: card.characterBookEntries) {
            self.characterBookEntriesData = data
        }
    }
}

// MARK: - Character Card Manager

@Observable
final class CharacterCardManager {
    private static let storageKey = "savedCharacterCards"

    var cards: [CharacterCard]

    init() {
        self.cards = Self.loadCards()
    }

    /// 从文件导入角色卡到卡库
    @discardableResult
    func importFromFile(url: URL) throws -> CharacterCard {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let tavernCard = try TavernCard.parseFile(url: url)
        let card = CharacterCard(from: tavernCard)
        cards.append(card)
        persist()
        return card
    }

    func update(_ card: CharacterCard) {
        guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[idx] = card
        persist()
    }

    func delete(_ card: CharacterCard) {
        cards.removeAll { $0.id == card.id }
        persist()
    }

    /// 从卡库中的卡创建楼层
    func createFloor(from card: CharacterCard, profileManager: ProfileManager) {
        var profile = Profile(
            name: card.name,
            emoji: "🎭",
            description: "\(card.name)的楼层",
            userName: "你",
            assistantName: card.name,
            systemPrompt: card.systemPrompt,
            characterDescription: card.description,
            characterPersonality: card.personality,
            scenario: card.scenario,
            chatExamples: card.mesExample,
            postInstructions: card.postHistoryInstructions,
            characterCardID: card.name,
            coverImageData: card.imageData
        )
        profileManager.addProfile(profile)

        // 创建对话 + 世界书
        let context = ModelContext(profileManager.container)

        // 对话：first_mes + alternate_greetings
        var greetings: [(title: String, content: String)] = []
        if !card.firstMes.isEmpty {
            greetings.append((title: card.name, content: card.firstMes))
        }
        for (i, greeting) in card.alternateGreetings.enumerated() {
            guard !greeting.isEmpty else { continue }
            greetings.append((title: "\(card.name) #\(i + 2)", content: greeting))
        }

        for greeting in greetings {
            let convId = UUID().uuidString
            let nodeId = UUID().uuidString
            let now = Date()
            let conversation = Conversation(
                id: convId, title: greeting.title,
                createTime: now, updateTime: now,
                currentNodeId: nodeId, provider: "sillytavern", profileId: profile.id
            )
            conversation.nodeCount = 1
            let node = MessageNode(
                id: nodeId, role: "assistant",
                content: Self.normalizeNewlines(greeting.content),
                contentType: "text", createTime: now,
                parentId: nil, childrenIds: [], conversationId: convId, profileId: profile.id
            )
            context.insert(conversation)
            context.insert(node)
        }

        // 世界书
        if card.hasWorldBook {
            let entries = card.characterBookEntries.enumerated().map { (i, dict) in
                WorldBookEntry(from: dict, index: i)
            }
            let bookName = card.characterBookName ?? "\(card.name)的世界书"
            let worldBook = WorldBook(name: bookName, profileId: profile.id, entries: entries)
            context.insert(worldBook)
            profile.linkedWorldBookIDs = [worldBook.id.uuidString]
            profileManager.updateProfile(profile)
        }

        try? context.save()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func loadCards() -> [CharacterCard] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([CharacterCard].self, from: data) else {
            return []
        }
        return saved
    }

    /// 角色卡文本换行规范化：\r\n → \n，单个 \n → \n\n（Markdown 段落）
    private static func normalizeNewlines(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\n\n", with: "\u{0000}PARA\u{0000}")
        s = s.replacingOccurrences(of: "\n", with: "\n\n")
        s = s.replacingOccurrences(of: "\u{0000}PARA\u{0000}", with: "\n\n")
        return s
    }
}
