import Foundation
import SwiftData

enum ImportMode: String, Codable {
    case normal
    case merge
}

@Model
final class ImportRecord {
    #Index<ImportRecord>(
        [\.profileId, \.importDate]
    )

    var id: UUID = UUID()
    /// 楼层隔离
    var profileId: String = ""
    var fileName: String
    var importDate: Date
    var provider: String          // "chatgpt", "claude"
    var conversationCount: Int
    var nodeCount: Int
    var modeRaw: String = ""
    var supportsUndo: Bool = false
    var addedConversationCount: Int = 0
    var updatedConversationCount: Int = 0
    var skippedConversationCount: Int = 0
    var ignoredConversationCount: Int = 0

    var mode: ImportMode {
        get { ImportMode(rawValue: modeRaw) ?? .normal }
        set { modeRaw = newValue.rawValue }
    }

    var isLegacyRecord: Bool {
        !supportsUndo &&
        addedConversationCount == 0 &&
        updatedConversationCount == 0 &&
        skippedConversationCount == 0 &&
        ignoredConversationCount == 0 &&
        conversationCount > 0
    }

    init(
        fileName: String,
        provider: String,
        conversationCount: Int = 0,
        nodeCount: Int = 0,
        mode: ImportMode = .normal,
        supportsUndo: Bool = false,
        addedConversationCount: Int = 0,
        updatedConversationCount: Int = 0,
        skippedConversationCount: Int = 0,
        ignoredConversationCount: Int = 0,
        profileId: String = ""
    ) {
        self.fileName = fileName
        self.importDate = Date()
        self.provider = provider
        self.conversationCount = conversationCount
        self.nodeCount = nodeCount
        self.modeRaw = mode.rawValue
        self.supportsUndo = supportsUndo
        self.addedConversationCount = addedConversationCount
        self.updatedConversationCount = updatedConversationCount
        self.skippedConversationCount = skippedConversationCount
        self.ignoredConversationCount = ignoredConversationCount
        self.profileId = profileId
    }
}
