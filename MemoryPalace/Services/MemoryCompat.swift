import Foundation

// MARK: - Compatibility stubs for SC-B2 dependencies not yet ported

/// Stub: CacheDiagLog — upstream diagnostic logger, not critical
final class CacheDiagLog {
    static let shared = CacheDiagLog()
    func log(_ msg: String) {
        #if DEBUG
        print("[MemoryDiag] \(msg)")
        #endif
    }
}

/// Stub: firstPersonExtractionPrompt — upstream extraction prompt
let firstPersonExtractionPrompt = """
请从以下对话中提取关于用户的重要信息，以第一人称陈述。
只提取事实性信息、偏好、关系、目标。
忽略技术讨论、代码修复等临时内容。
每条一行，简洁明确。
"""
