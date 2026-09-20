import Foundation

/// 群聊参与者。存在 Conversation.participantsData（JSON 编码）。
struct GroupParticipant: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var characterCardID: String
    var model: String               // provider model combined id
    var presetId: String
    var colorHex: String            // 气泡颜色
    var systemPrompt: String        // 每个参与者独立的 system prompt
    var intro: String               // 一句话简介（群名片）：成员互感/选人用，替代长人设截断
    var talkativeness: Double       // 0.0（沉默）~1.0（话痨），默认 0.5

    init(id: String = UUID().uuidString,
         name: String,
         characterCardID: String = "",
         model: String,
         presetId: String = "",
         colorHex: String,
         systemPrompt: String = "",
         intro: String = "",
         talkativeness: Double = 0.5) {
        self.id = id
        self.name = name
        self.characterCardID = characterCardID
        self.model = model
        self.presetId = presetId
        self.colorHex = colorHex
        self.systemPrompt = systemPrompt
        self.intro = intro
        self.talkativeness = talkativeness
    }

    // 向后兼容
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        characterCardID = try c.decodeIfPresent(String.self, forKey: .characterCardID) ?? ""
        model = try c.decode(String.self, forKey: .model)
        presetId = try c.decodeIfPresent(String.self, forKey: .presetId) ?? ""
        colorHex = try c.decode(String.self, forKey: .colorHex)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        intro = try c.decodeIfPresent(String.self, forKey: .intro) ?? ""
        talkativeness = try c.decodeIfPresent(Double.self, forKey: .talkativeness) ?? 0.5
    }
}
