import Foundation

enum ChatAttachmentKind: String, Hashable {
    case text
    case image
}

enum ChatAttachmentError: LocalizedError {
    case imageTooLarge(String, Int)
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .imageTooLarge(let name, let limitMB):
            return "\(name) 太大了，当前图片上限 \(limitMB) MB"
        case .invalidImage(let name):
            return "无法读取图片：\(name)"
        }
    }
}

struct PendingChatAttachment: Identifiable, Hashable {
    static let maxImageBytes = 8 * 1024 * 1024

    let id = UUID()
    let name: String
    let kind: ChatAttachmentKind
    let typeDescription: String
    let extractedText: String
    let byteCount: Int
    let mimeType: String?
    let imageData: Data?
    let fileData: Data?

    var previewText: String {
        if extractedText.count > 4000 {
            return String(extractedText.prefix(4000)) + "\n...（已截断）"
        }
        return extractedText
    }

    var isImage: Bool {
        kind == .image && imageData != nil
    }

    var isFile: Bool {
        !isImage && fileData != nil
    }

    static func text(name: String, typeDescription: String, extractedText: String, byteCount: Int,
                     fileData: Data? = nil, fileMime: String? = nil) -> PendingChatAttachment {
        PendingChatAttachment(
            name: name,
            kind: .text,
            typeDescription: typeDescription,
            extractedText: extractedText,
            byteCount: byteCount,
            mimeType: fileMime,
            imageData: nil,
            fileData: fileData
        )
    }

    static func image(name: String, typeDescription: String, mimeType: String, data: Data) throws -> PendingChatAttachment {
        guard data.count <= maxImageBytes else {
            throw ChatAttachmentError.imageTooLarge(name, maxImageBytes / 1024 / 1024)
        }
        return PendingChatAttachment(
            name: name,
            kind: .image,
            typeDescription: typeDescription,
            extractedText: "",
            byteCount: data.count,
            mimeType: mimeType,
            imageData: data,
            fileData: nil
        )
    }
}

enum ChatAttachmentPromptBuilder {
    static func modelInput(text: String, attachments: [PendingChatAttachment]) -> String {
        var parts: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }

        for attachment in attachments {
            if attachment.isImage {
                parts.append("[图片附件：\(attachment.name) · \(attachment.typeDescription)]")
            } else {
                parts.append("""
                [附件：\(attachment.name) · \(attachment.typeDescription)]
                \(attachment.extractedText)
                [/附件]
                """)
            }
        }

        return parts.joined(separator: "\n\n")
    }

    static func segments(text: String, attachments: [PendingChatAttachment]) -> [MessageSegment] {
        var result: [MessageSegment] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(.text(trimmed))
        }
        for att in attachments {
            result.append(.attachment(name: att.name, type: att.typeDescription, extractedContent: att.previewText))
        }
        return result
    }
}
