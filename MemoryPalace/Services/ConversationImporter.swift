import Foundation
import SwiftData

/// Streams and parses the large conversations.json file in batches
@Observable
final class ConversationImporter {
    var isImporting = false
    var progress: Double = 0        // 0.0 - 1.0
    var importedCount: Int = 0
    var processedCount: Int = 0
    var totalCount: Int = 0
    var addedConversationCount: Int = 0
    var updatedConversationCount: Int = 0
    var skippedConversationCount: Int = 0
    var ignoredConversationCount: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
    var didCompleteImport = false

    private var modelContainer: ModelContainer
    /// 路线 B 单 container 下，importer 只写当前楼层。Caller 必须传 profileId。
    let profileId: String

    init(modelContainer: ModelContainer, profileId: String) {
        self.modelContainer = modelContainer
        self.profileId = profileId
    }

    func importFile(url: URL) async {
        await beginImport()

        // 清理已删楼层的残留数据（防止跨楼层冲突检查误拦）
        do {
            let cleanCtx = ModelContext(modelContainer)
            cleanCtx.autosaveEnabled = false
            let aliveIds = Set(ProfileManager.loadProfiles().map(\.id))
            let allConvs = (try? cleanCtx.fetch(FetchDescriptor<Conversation>())) ?? []
            var cleaned = 0
            for conv in allConvs {
                if !aliveIds.contains(conv.profileId) {
                    // 这个对话属于已删楼层，清掉
                    let deadPid = conv.profileId
                    let deadConvId = conv.id
                    let nodeDesc = FetchDescriptor<MessageNode>(
                        predicate: #Predicate<MessageNode> { $0.conversationId == deadConvId && $0.profileId == deadPid }
                    )
                    for node in (try? cleanCtx.fetch(nodeDesc)) ?? [] {
                        cleanCtx.delete(node)
                    }
                    cleanCtx.delete(conv)
                    cleaned += 1
                }
            }
            if cleaned > 0 {
                try? cleanCtx.save()
                print("[Import] 清理了 \(cleaned) 条已删楼层的残留对话")
            }
        }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await MainActor.run { statusMessage = "正在解析 JSON..." }

            let decoder = JSONDecoder()
            let rawConversations = try decoder.decode([RawConversation].self, from: data)
            let total = rawConversations.count
            await MainActor.run {
                totalCount = total
                statusMessage = "共 \(total) 条对话，正在导入..."
            }

            let batchSize = 200
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false

            let scopedProfileId = self.profileId
            let existingConversations = try context.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == scopedProfileId }
            ))
            var existingConversationIds = Set(existingConversations.map(\.id))

            let record = ImportRecord(fileName: url.lastPathComponent, provider: "chatgpt", mode: .normal, profileId: self.profileId)
            context.insert(record)
            let recordId = record.id
            var affectedNodes = 0
            var addedConversations = 0
            var skippedConversations = 0
            let ignoredConversations = 0
            var processedConversations = 0
            var crossProfileConflicts = 0

            for batchStart in stride(from: 0, to: rawConversations.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, rawConversations.count)
                let batch = rawConversations[batchStart..<batchEnd]
                let batchPayloads = batch.map { makePayload(from: $0) }
                let conflictedIds = (try? crossProfileConflictedConversationIds(
                    payloads: batchPayloads.filter { !existingConversationIds.contains($0.id) },
                    currentProfileId: scopedProfileId, in: context
                )) ?? Set<String>()

                for incoming in batchPayloads {
                    processedConversations += 1

                    if existingConversationIds.contains(incoming.id) {
                        skippedConversations += 1
                        continue
                    }

                    if conflictedIds.contains(incoming.id) {
                        crossProfileConflicts += 1
                        continue
                    }

                    let conversation = Conversation(
                        id: incoming.id,
                        title: incoming.title,
                        createTime: incoming.createTime,
                        updateTime: incoming.updateTime,
                        currentNodeId: incoming.currentNodeId,
                        provider: incoming.provider,
                        profileId: self.profileId
                    )
                    conversation.importBatchId = recordId
                    conversation.nodeCount = countDisplayableNodes(incoming.nodes)
                    conversation.source = "chatgpt"
                    context.insert(conversation)

                    for nodePayload in incoming.nodes {
                        context.insert(makeImportedNode(nodePayload, conversationId: incoming.id, profileId: self.profileId))
                    }

                    let change = ImportConversationChange(
                        recordId: recordId,
                        conversationId: incoming.id,
                        changeKind: .created,
                        profileId: self.profileId
                    )
                    context.insert(change)

                    existingConversationIds.insert(incoming.id)
                    addedConversations += 1
                    affectedNodes += incoming.nodes.count
                }

                try context.save()

                await updateProgress(
                    processed: processedConversations,
                    total: total,
                    added: addedConversations,
                    updated: 0,
                    skipped: skippedConversations,
                    ignored: ignoredConversations,
                    actionText: "导入"
                )
            }

            record.conversationCount = addedConversations
            record.nodeCount = affectedNodes
            record.addedConversationCount = addedConversations
            record.updatedConversationCount = 0
            record.skippedConversationCount = skippedConversations
            record.ignoredConversationCount = ignoredConversations
            record.supportsUndo = addedConversations > 0
            try context.save()

            await finishImport(
                added: addedConversations,
                updated: 0,
                skipped: skippedConversations,
                ignored: ignoredConversations,
                completionText: addedConversations > 0
                    ? "导入完成！新增 \(addedConversations) 条，保持本地 \(skippedConversations) 条" + crossProfileConflictSuffix(crossProfileConflicts)
                    : "导入完成！这次没有新增，对话已全部保持本地" + crossProfileConflictSuffix(crossProfileConflicts)
            )
        } catch {
            await failImport(error)
        }
    }

    // MARK: - Merge Import

    func mergeImportFile(url: URL) async {
        await beginImport()

        // 清理已删楼层的残留数据
        do {
            let cleanCtx = ModelContext(modelContainer)
            cleanCtx.autosaveEnabled = false
            let aliveIds = Set(ProfileManager.loadProfiles().map(\.id))
            let allConvs = (try? cleanCtx.fetch(FetchDescriptor<Conversation>())) ?? []
            var cleaned = 0
            for conv in allConvs where !aliveIds.contains(conv.profileId) {
                let deadPid = conv.profileId
                let deadConvId = conv.id
                let nodeDesc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.conversationId == deadConvId && $0.profileId == deadPid }
                )
                for node in (try? cleanCtx.fetch(nodeDesc)) ?? [] { cleanCtx.delete(node) }
                cleanCtx.delete(conv)
                cleaned += 1
            }
            if cleaned > 0 { try? cleanCtx.save(); print("[Import] 清理了 \(cleaned) 条残留对话") }
        }

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await MainActor.run { statusMessage = "正在解析 JSON..." }

            let decoder = JSONDecoder()
            let rawConversations = try decoder.decode([RawConversation].self, from: data)
            let total = rawConversations.count
            await MainActor.run {
                totalCount = total
                statusMessage = "共 \(total) 条对话，正在叠加合并..."
            }

            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false

            let scopedProfileId = self.profileId
            let localConversations = try context.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == scopedProfileId }
            ))
            var localConversationsById = Dictionary(uniqueKeysWithValues: localConversations.map { ($0.id, $0) })

            let record = ImportRecord(
                fileName: url.lastPathComponent + " (叠加)",
                provider: "chatgpt",
                mode: .merge,
                profileId: self.profileId
            )
            context.insert(record)
            let recordId = record.id

            var addedConversations = 0
            var updatedConversations = 0
            var skippedConversations = 0
            let ignoredConversations = 0
            var processedConversations = 0
            var affectedNodes = 0
            var crossProfileConflicts = 0

            let batchSize = 200
            for batchStart in stride(from: 0, to: rawConversations.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, rawConversations.count)
                let batch = rawConversations[batchStart..<batchEnd]
                let batchPayloads = batch.map { makePayload(from: $0) }
                let conflictedIds = (try? crossProfileConflictedConversationIds(
                    payloads: batchPayloads.filter { !localConversationsById.keys.contains($0.id) },
                    currentProfileId: scopedProfileId, in: context
                )) ?? Set<String>()

                for incoming in batchPayloads {
                    processedConversations += 1

                    if let existingConversation = localConversationsById[incoming.id] {
                        let existingNodes = try fetchConversationNodes(conversationId: incoming.id, profileId: self.profileId, in: context)
                        if shouldMergeConversation(
                            existing: existingConversation,
                            existingNodes: existingNodes,
                            incoming: incoming
                        ) {
                            let snapshots = try encodeSnapshots(conversation: existingConversation, nodes: existingNodes)
                            let change = ImportConversationChange(
                                recordId: recordId,
                                conversationId: incoming.id,
                                changeKind: .updated,
                                beforeConversationData: snapshots.conversationData,
                                beforeNodesData: snapshots.nodesData,
                                profileId: self.profileId
                            )
                            context.insert(change)

                            var mergedNodes = existingNodes
                            var existingNodeMap = Dictionary(uniqueKeysWithValues: existingNodes.map { ($0.id, $0) })
                            var changedNodeCount = 0

                            for nodePayload in incoming.nodes {
                                if let existingNode = existingNodeMap[nodePayload.id] {
                                    if applyImportedNode(nodePayload, to: existingNode) {
                                        changedNodeCount += 1
                                    }
                                } else {
                                    let newNode = makeImportedNode(nodePayload, conversationId: incoming.id, profileId: self.profileId)
                                    context.insert(newNode)
                                    mergedNodes.append(newNode)
                                    existingNodeMap[nodePayload.id] = newNode
                                    changedNodeCount += 1
                                }
                            }

                            let mergedNodeCount = countDisplayableNodes(mergedNodes)
                            if importedConversationMetadataDiffers(from: existingConversation, incoming: incoming) {
                                applyImportedConversationMetadata(incoming, to: existingConversation, nodeCount: mergedNodeCount)
                            } else {
                                existingConversation.nodeCount = mergedNodeCount
                            }

                            updatedConversations += 1
                            affectedNodes += changedNodeCount
                        } else {
                            skippedConversations += 1
                        }
                    } else {
                        if conflictedIds.contains(incoming.id) {
                            crossProfileConflicts += 1
                            continue
                        }
                        let conversation = Conversation(
                            id: incoming.id,
                            title: incoming.title,
                            createTime: incoming.createTime,
                            updateTime: incoming.updateTime,
                            currentNodeId: incoming.currentNodeId,
                            provider: incoming.provider,
                            profileId: self.profileId
                        )
                        conversation.importBatchId = recordId
                        conversation.nodeCount = countDisplayableNodes(incoming.nodes)
                        conversation.source = "chatgpt"
                        context.insert(conversation)

                        for nodePayload in incoming.nodes {
                            context.insert(makeImportedNode(nodePayload, conversationId: incoming.id, profileId: self.profileId))
                        }

                        let change = ImportConversationChange(
                            recordId: recordId,
                            conversationId: incoming.id,
                            changeKind: .created,
                            profileId: self.profileId
                        )
                        context.insert(change)

                        localConversationsById[incoming.id] = conversation
                        addedConversations += 1
                        affectedNodes += incoming.nodes.count
                    }
                }

                try context.save()

                await updateProgress(
                    processed: processedConversations,
                    total: total,
                    added: addedConversations,
                    updated: updatedConversations,
                    skipped: skippedConversations,
                    ignored: ignoredConversations,
                    actionText: "叠加导入"
                )
            }

            record.conversationCount = addedConversations + updatedConversations
            record.nodeCount = affectedNodes
            record.addedConversationCount = addedConversations
            record.updatedConversationCount = updatedConversations
            record.skippedConversationCount = skippedConversations
            record.ignoredConversationCount = ignoredConversations
            record.supportsUndo = (addedConversations + updatedConversations) > 0
            try context.save()

            await finishImport(
                added: addedConversations,
                updated: updatedConversations,
                skipped: skippedConversations,
                ignored: ignoredConversations,
                completionText: "叠加完成！新增 \(addedConversations) 条，更新 \(updatedConversations) 条，保持本地 \(skippedConversations) 条" + crossProfileConflictSuffix(crossProfileConflicts)
            )
        } catch {
            await failImport(error)
        }
    }

    private func beginImport() async {
        await MainActor.run {
            isImporting = true
            progress = 0
            importedCount = 0
            processedCount = 0
            totalCount = 0
            addedConversationCount = 0
            updatedConversationCount = 0
            skippedConversationCount = 0
            ignoredConversationCount = 0
            errorMessage = nil
            statusMessage = "正在读取文件..."
            didCompleteImport = false
        }
    }

    private func updateProgress(
        processed: Int,
        total: Int,
        added: Int,
        updated: Int,
        skipped: Int,
        ignored: Int,
        actionText: String
    ) async {
        await MainActor.run {
            processedCount = processed
            importedCount = added
            addedConversationCount = added
            updatedConversationCount = updated
            skippedConversationCount = skipped
            ignoredConversationCount = ignored
            progress = total == 0 ? 1 : Double(processed) / Double(total)
            statusMessage = progressStatusText(
                processed: processed,
                total: total,
                added: added,
                updated: updated,
                skipped: skipped,
                ignored: ignored
            )
            if processed == total {
                statusMessage = completionStatusText(
                    actionText: actionText,
                    added: added,
                    updated: updated,
                    skipped: skipped,
                    ignored: ignored
                )
            }
        }
    }

    private func finishImport(
        added: Int,
        updated: Int,
        skipped: Int,
        ignored: Int,
        completionText: String
    ) async {
        await MainActor.run {
            importedCount = added
            addedConversationCount = added
            updatedConversationCount = updated
            skippedConversationCount = skipped
            ignoredConversationCount = ignored
            progress = 1
            statusMessage = completionText
            isImporting = false
            didCompleteImport = true
        }
    }

    private func failImport(_ error: Error) async {
        let msg = error.localizedDescription
        await MainActor.run {
            errorMessage = "导入失败: \(msg)"
            statusMessage = "导入失败"
            isImporting = false
            didCompleteImport = false
        }
    }

    private func makePayload(from raw: RawConversation) -> ImportedConversationPayload {
        let conversationId = raw.id ?? UUID().uuidString
        let nodes = raw.mapping?.map { nodeId, rawNode in
            ImportedNodePayload(
                id: nodeId,
                role: rawNode.message?.author?.role ?? "unknown",
                content: extractContent(from: rawNode.message?.content),
                contentType: rawNode.message?.content?.content_type ?? "text",
                createTime: rawNode.message?.create_time.map { Date(timeIntervalSince1970: $0) },
                parentId: rawNode.parent,
                childrenIds: rawNode.children ?? []
            )
        } ?? []

        return ImportedConversationPayload(
            id: conversationId,
            title: raw.title ?? "无标题",
            createTime: Date(timeIntervalSince1970: raw.create_time ?? 0),
            updateTime: Date(timeIntervalSince1970: raw.update_time ?? 0),
            currentNodeId: raw.current_node ?? "",
            provider: "chatgpt",
            nodes: nodes
        )
    }

    private func progressStatusText(
        processed: Int,
        total: Int,
        added: Int,
        updated: Int,
        skipped: Int,
        ignored: Int
    ) -> String {
        var parts = [
            "已处理 \(processed) / \(total)",
            "新增 \(added)",
            "更新 \(updated)",
            "保持本地 \(skipped)"
        ]
        if ignored > 0 {
            parts.append("未导入 \(ignored)")
        }
        return parts.joined(separator: " · ")
    }

    private func completionStatusText(
        actionText: String,
        added: Int,
        updated: Int,
        skipped: Int,
        ignored: Int
    ) -> String {
        var parts = [
            "\(actionText)处理中",
            "新增 \(added)",
            "更新 \(updated)",
            "保持本地 \(skipped)"
        ]
        if ignored > 0 {
            parts.append("未导入 \(ignored)")
        }
        return parts.joined(separator: " · ")
    }

    private func extractContent(from content: RawContent?) -> String {
        guard let content = content else { return "" }
        guard let parts = content.parts else { return "" }

        var texts: [String] = []
        for part in parts {
            switch part {
            case .string(let s):
                texts.append(s)
            case .object(_):
                // Could be image or other attachment, skip for MVP
                break
            }
        }
        return texts.joined(separator: "\n")
    }
}

// MARK: - Raw JSON Types

struct RawConversation: Decodable {
    let id: String?
    let title: String?
    let create_time: Double?
    let update_time: Double?
    let current_node: String?
    let mapping: [String: RawNode]?
}

struct RawNode: Decodable {
    let id: String?
    let message: RawMessage?
    let parent: String?
    let children: [String]?
}

struct RawMessage: Decodable {
    let id: String?
    let author: RawAuthor?
    let create_time: Double?
    let update_time: Double?
    let content: RawContent?
    let status: String?
    let end_turn: Bool?
    let weight: Double?
    let metadata: AnyCodable?
    let recipient: String?
    let channel: String?
}

struct RawAuthor: Decodable {
    let role: String?
    let name: String?
}

struct RawContent: Decodable {
    let content_type: String?
    let parts: [RawPart]?
}

enum RawPart: Decodable {
    case string(String)
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let obj = try? container.decode([String: AnyCodable].self) {
            self = .object(obj)
        } else {
            self = .string("")
        }
    }
}

/// Generic type to handle arbitrary JSON values
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if container.decodeNil() { value = NSNull() }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else { value = NSNull() }
    }
}
