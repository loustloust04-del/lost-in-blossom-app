import Foundation
import Observation

// MARK: - Global World Book (跨楼层，存 UserDefaults)

struct GlobalWorldBook: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var entries: [WorldBookEntry] = []
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var enabledEntryCount: Int {
        entries.filter(\.isEnabled).count
    }
}

// MARK: - Global World Book Manager

@Observable
final class GlobalWorldBookManager {
    private static let storageKey = "globalWorldBooks"

    var books: [GlobalWorldBook]

    /// 当前启用的全局世界书
    var enabledBooks: [GlobalWorldBook] {
        books.filter(\.isEnabled)
    }

    init() {
        self.books = Self.load()
    }

    /// 新建空白全局世界书
    @discardableResult
    func create(name: String) -> GlobalWorldBook {
        let book = GlobalWorldBook(name: name)
        books.append(book)
        persist()
        return book
    }

    func delete(_ book: GlobalWorldBook) {
        books.removeAll { $0.id == book.id }
        persist()
    }

    func toggleEnabled(_ id: String) {
        guard let idx = books.firstIndex(where: { $0.id == id }) else { return }
        books[idx].isEnabled.toggle()
        persist()
    }

    func update(_ book: GlobalWorldBook) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        books[idx].updatedAt = Date()
        persist()
    }

    /// 更新指定书的 entries
    func updateEntries(bookId: String, entries: [WorldBookEntry]) {
        guard let idx = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[idx].entries = entries
        books[idx].updatedAt = Date()
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [GlobalWorldBook] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([GlobalWorldBook].self, from: data) else {
            return []
        }
        return saved
    }
}
