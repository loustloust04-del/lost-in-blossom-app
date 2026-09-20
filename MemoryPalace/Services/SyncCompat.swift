import Foundation

// MARK: - Compatibility stubs for upstream sync dependencies
// These types exist in 粟儿's upstream but haven't been cherry-picked yet.

/// Stub: SyncProbe — upstream cherry-pick dependency
struct SyncProbe {
    var localCount: Int = 0
    var remoteCount: Int = 0
    var needsSync: Bool { localCount != remoteCount }
    
    static func run() async -> SyncProbe {
        SyncProbe()
    }
    
    static func log(_ message: String) {
        print("[SyncProbe] \(message)")
    }
}

/// Stub: LocalMode — upstream cherry-pick dependency
enum LocalMode {
    case local
    case iCloud
    
    static var isOn: Bool { false }
}

// MARK: - FileLibraryStore iCloud extensions (stub)

extension FileLibraryStore {
    static func primeICloudContainer(completion: @escaping (Bool) -> Void) {
        completion(false)
    }
    
    static func iCloudDocumentsRoot() -> URL? {
        nil
    }
}


// AttachmentStore stub 已删：语音系统搬运带来了完整版（Services/AttachmentStore.swift，
// 自带真实现的 deleteConversationAttachments），同名冲突且 stub 本来就是空的。
