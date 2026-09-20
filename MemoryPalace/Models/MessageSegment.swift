import Foundation

/// Claude 导入 v2 写入的结构化分段。按 `content[]` 原顺序保存。
/// 渲染时（MessageSegmentsView）按顺序 map 成独立 View，每段独立折叠。
///
/// Codable 用自定义 key "kind" 做 tag，保持向后兼容（新增 case 时老解码跳过即可）。
enum MessageSegment: Codable, Hashable {
    case text(String)
    case thinking(text: String, signature: String?)
    case toolUse(
        id: String,
        name: String,
        inputJSON: String,
        integrationName: String?,
        iconName: String?
    )
    case toolResult(
        toolUseId: String,
        text: String,
        isError: Bool,
        integrationName: String?
    )
    case flag(
        kind: String,
        helplineName: String?,
        helplinePhone: String?,
        helplineUrl: String?
    )
    case attachment(
        name: String,
        type: String?,
        extractedContent: String?
    )
    case file(name: String, uuid: String)
    /// 图片段（2026-08-30 气泡整套搬运补缺，对齐粟粟 MessageSegment.image）：
    /// 字节内联。我们此前图片塞 multimodal_text JSON，她的气泡/附件条全靠这个 case。
    case image(name: String, type: String?, data: Data)
    /// 原始字节内联的任意文件（CC↔app 互发；区别于 .file 的 uuid 引用、.attachment 的纯文本）
    case fileData(name: String, mime: String, data: Data)

    // MARK: - Codable

    /// 语音条：AI 表演脚本经 TTS 生成的音频。字节在文件库，
    /// script 存表演脚本原文——「换一版」靠它重跑，失败降级时也保住文字。
    case audioRef(name: String, mime: String, path: String, duration: Double?, script: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case signature
        case id
        case name
        case inputJSON
        case integrationName
        case iconName
        case toolUseId
        case isError
        case helplineName
        case helplinePhone
        case helplineUrl
        case type
        case extractedContent
        case uuid
        case path
        case duration
        case script
        case data
        case mime
    }

    private enum Kind: String, Codable {
        case text
        case thinking
        case toolUse
        case toolResult
        case flag
        case attachment
        case file
        case audioRef
        case image
        case fileData
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .thinking(let text, let sig):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(sig, forKey: .signature)
        case .toolUse(let id, let name, let inputJSON, let integration, let icon):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .inputJSON)
            try c.encodeIfPresent(integration, forKey: .integrationName)
            try c.encodeIfPresent(icon, forKey: .iconName)
        case .toolResult(let useId, let text, let isErr, let integration):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(useId, forKey: .toolUseId)
            try c.encode(text, forKey: .text)
            try c.encode(isErr, forKey: .isError)
            try c.encodeIfPresent(integration, forKey: .integrationName)
        case .flag(let kind, let hName, let hPhone, let hUrl):
            try c.encode(Kind.flag, forKey: .kind)
            try c.encode(kind, forKey: .name)
            try c.encodeIfPresent(hName, forKey: .helplineName)
            try c.encodeIfPresent(hPhone, forKey: .helplinePhone)
            try c.encodeIfPresent(hUrl, forKey: .helplineUrl)
        case .attachment(let name, let type, let extracted):
            try c.encode(Kind.attachment, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encodeIfPresent(extracted, forKey: .extractedContent)
        case .file(let name, let uuid):
            try c.encode(Kind.file, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(uuid, forKey: .uuid)
        case .image(let name, let type, let data):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encode(data, forKey: .data)
        case .fileData(let name, let mime, let data):
            try c.encode(Kind.fileData, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .mime)
            try c.encode(data, forKey: .data)
        case .audioRef(let name, let mime, let path, let duration, let script):
            try c.encode(Kind.audioRef, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(duration, forKey: .duration)
            try c.encodeIfPresent(script, forKey: .script)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            let s = try c.decode(String.self, forKey: .text)
            self = .text(s)
        case .thinking:
            let s = try c.decode(String.self, forKey: .text)
            let sig = try c.decodeIfPresent(String.self, forKey: .signature)
            self = .thinking(text: s, signature: sig)
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .inputJSON),
                integrationName: try c.decodeIfPresent(String.self, forKey: .integrationName),
                iconName: try c.decodeIfPresent(String.self, forKey: .iconName)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                text: try c.decode(String.self, forKey: .text),
                isError: try c.decode(Bool.self, forKey: .isError),
                integrationName: try c.decodeIfPresent(String.self, forKey: .integrationName)
            )
        case .flag:
            self = .flag(
                kind: try c.decode(String.self, forKey: .name),
                helplineName: try c.decodeIfPresent(String.self, forKey: .helplineName),
                helplinePhone: try c.decodeIfPresent(String.self, forKey: .helplinePhone),
                helplineUrl: try c.decodeIfPresent(String.self, forKey: .helplineUrl)
            )
        case .attachment:
            self = .attachment(
                name: try c.decode(String.self, forKey: .name),
                type: try c.decodeIfPresent(String.self, forKey: .type),
                extractedContent: try c.decodeIfPresent(String.self, forKey: .extractedContent)
            )
        case .file:
            self = .file(
                name: try c.decode(String.self, forKey: .name),
                uuid: try c.decode(String.self, forKey: .uuid)
            )
        case .image:
            self = .image(
                name: try c.decode(String.self, forKey: .name),
                type: try c.decodeIfPresent(String.self, forKey: .type),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .fileData:
            self = .fileData(
                name: try c.decode(String.self, forKey: .name),
                mime: try c.decode(String.self, forKey: .mime),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .audioRef:
            self = .audioRef(
                name: try c.decode(String.self, forKey: .name),
                mime: try c.decode(String.self, forKey: .type),
                path: try c.decode(String.self, forKey: .path),
                duration: try c.decodeIfPresent(Double.self, forKey: .duration),
                script: try c.decodeIfPresent(String.self, forKey: .script)
            )
        }
    }
}

extension Array where Element == MessageSegment {
    /// 气泡是否该走 segmented 渲染：audioRef 不算数——语音条在气泡外侧胶囊渲染，
    /// 只挂了语音条的消息正文仍走纯文本分支（否则挂 segment 瞬间正文蒸发）。
    var hasRenderableSegments: Bool {
        contains { seg in
            if case .audioRef = seg { return false }
            return true
        }
    }

    /// 粟粟接口对齐（搬运垫片）：她那边 imageRef/fileDataRef 存文件库引用，显示前要「注水」
    /// 成内联字节；我们暂无引用型段，原样返回。签名保持一致让她的调用点原文编译。
    func hydratedForDisplay(profileId: String) -> [MessageSegment] { self }
}
