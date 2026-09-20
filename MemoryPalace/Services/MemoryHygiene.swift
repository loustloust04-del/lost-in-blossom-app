import Foundation
import SwiftData

// MARK: - 记忆卫生工具（简化版，仅 pair 配对去重）

enum MemoryHygiene {

    static let pairThreshold: Float = MemoryExtractor.dedupSimilarityThreshold   // 0.75
    static let maxScanCount = 10000

    struct Report {
        let merged: Int
        let remaining: Int
    }

    enum Failure: Error, LocalizedError {
        case tooManyMemories(Int)
        case noMemories

        var errorDescription: String? {
            switch self {
            case .tooManyMemories(let n): return "记忆条数过多（\(n) > \(MemoryHygiene.maxScanCount)），先手动整理再试"
            case .noMemories:           return "记忆库为空，无需整理"
            }
        }
    }

    /// 一次性清洗：pair 配对去重（sim > 0.75 保新去旧）
    @MainActor
    static func sweep(
        profileId: String,
        context: ModelContext
    ) async throws -> Report {
        let pid = profileId
        var desc = FetchDescriptor<Memory>(predicate: #Predicate<Memory> { $0.profileId == pid })
        desc.sortBy = [SortDescriptor(\Memory.createdAt, order: .reverse)]
        let all = (try? context.fetch(desc)) ?? []

        guard !all.isEmpty else { throw Failure.noMemories }
        guard all.count <= maxScanCount else { throw Failure.tooManyMemories(all.count) }

        // 解码向量缓存
        let vectors: [UUID: [Float]] = {
            var map = [UUID: [Float]]()
            for m in all {
                if let data = m.embeddingData {
                    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    if !floats.isEmpty { map[m.id] = floats }
                }
            }
            return map
        }()

        // pair 配对去重：O(n²)，按 createdAt 倒序，保新去旧
        var toDelete: Set<UUID> = []
        for i in 0..<all.count {
            let a = all[i]
            guard !toDelete.contains(a.id) else { continue }
            guard let vecA = vectors[a.id] else { continue }
            for j in (i+1)..<all.count {
                let b = all[j]
                guard !toDelete.contains(b.id) else { continue }
                guard let vecB = vectors[b.id] else { continue }
                let sim = cosineSimilarity(vecA, vecB)
                if sim > pairThreshold {
                    toDelete.insert(b.id)
                }
            }
        }

        for m in all where toDelete.contains(m.id) {
            context.delete(m)
        }
        if !toDelete.isEmpty { context.saveOrReport("记忆") }

        return Report(merged: toDelete.count, remaining: all.count - toDelete.count)
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}
