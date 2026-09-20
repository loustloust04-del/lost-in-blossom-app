import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: String
    var profileId: String = ""
    var name: String
    var desc: String
    var icon: String        // SF Symbol name
    var colorHex: String    // hex color string, e.g. "6B7CB3"
    var instructions: String
    var createdAt: Date
    var archivedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        desc: String = "",
        icon: String = "folder",
        colorHex: String = "6B7CB3",
        instructions: String = "",
        profileId: String = ""
    ) {
        self.id = id
        self.name = name
        self.desc = desc
        self.icon = icon
        self.colorHex = colorHex
        self.instructions = instructions
        self.createdAt = Date()
        self.profileId = profileId
    }
}
