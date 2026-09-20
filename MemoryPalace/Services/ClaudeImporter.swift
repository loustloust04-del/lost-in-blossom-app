import Foundation
import SwiftData

/// Imports Claude.ai exported conversations.json
/// Claude format: flat array of conversations, each with linear chat_messages (no tree branching)
/// Content blocks: text, thinking, tool_use, tool_result, flag
@Observable
final class ClaudeImporter {
    var isImporting = false
    var progress: Double = 0
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
    let profileId: String

    init(modelContainer: ModelContainer, profileId: String) {
        self.modelContainer = modelContainer
        self.profileId = profileId
    }

    func importFile(url: URL) async {
        await beginImport()

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await MainActor.run { statusMessage = "正在解析 JSON..." }

            let decoder = JSONDecoder()
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFmtNoFrac = ISO8601DateFormatter()
            isoFmtNoFrac.formatOptions = [.withInternetDateTime]
            decoder.dateDecodingStrategy = .custom { decoder in
                let c = try decoder.singleValueContainer()
                let s = try c.decode(String.self)
                if let d = isoFmt.date(from: s) { return d }
                if let d = isoFmtNoFrac.date(from: s) { return d }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
            }
            let rawConversations = try decoder.decode([ClaudeRawConversation].self, from: data)
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

            let record = ImportRecord(fileName: url.lastPathComponent, provider: "claude", mode: .normal, profileId: self.profileId)
            context.insert(record)
            let recordId = record.id
            var affectedNodes = 0
            var addedConversations = 0
            var skippedConversations = 0
            var ignoredConversations = 0
            var processedConversations = 0
            var crossProfileConflicts = 0

            for batchStart in stride(from: 0, to: rawConversations.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, rawConversations.count)
                let batch = rawConversations[batchStart..<batchEnd]
                var batchPayloads: [ImportedConversationPayload] = []
                for raw in batch {
                    processedConversations += 1
                    if let p = makePayload(from: raw) { batchPayloads.append(p) }
                    else { ignoredConversations += 1 }
                }
                let conflictedIds = (try? crossProfileConflictedConversationIds(
                    payloads: batchPayloads.filter { !existingConversationIds.contains($0.id) },
                    currentProfileId: scopedProfileId, in: context
                )) ?? Set<String>()

                for incoming in batchPayloads {
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
                    conversation.source = "claude"
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
                    ? finishText(
                        prefix: "导入完成！",
                        added: addedConversations,
                        updated: 0,
                        skipped: skippedConversations,
                        ignored: ignoredConversations
                    ) + crossProfileConflictSuffix(crossProfileConflicts)
                    : finishText(
                        prefix: "导入完成！",
                        added: 0,
                        updated: 0,
                        skipped: skippedConversations,
                        ignored: ignoredConversations
                    ) + crossProfileConflictSuffix(crossProfileConflicts)
            )
        } catch {
            await failImport(error)
        }
    }

    // MARK: - Merge Import

    func mergeImportFile(url: URL) async {
        await beginImport()

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await MainActor.run { statusMessage = "正在解析 JSON..." }

            let decoder = JSONDecoder()
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFmtNoFrac = ISO8601DateFormatter()
            isoFmtNoFrac.formatOptions = [.withInternetDateTime]
            decoder.dateDecodingStrategy = .custom { decoder in
                let c = try decoder.singleValueContainer()
                let s = try c.decode(String.self)
                if let d = isoFmt.date(from: s) { return d }
                if let d = isoFmtNoFrac.date(from: s) { return d }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
            }
            let rawConversations = try decoder.decode([ClaudeRawConversation].self, from: data)
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
                provider: "claude",
                mode: .merge,
                profileId: self.profileId
            )
            context.insert(record)
            let recordId = record.id

            var addedConversations = 0
            var updatedConversations = 0
            var skippedConversations = 0
            var ignoredConversations = 0
            var processedConversations = 0
            var affectedNodes = 0
            var crossProfileConflicts = 0

            let batchSize = 200
            for batchStart in stride(from: 0, to: rawConversations.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, rawConversations.count)
                let batch = rawConversations[batchStart..<batchEnd]
                var batchPayloads: [ImportedConversationPayload] = []
                for raw in batch {
                    processedConversations += 1
                    if let p = makePayload(from: raw) { batchPayloads.append(p) }
                    else { ignoredConversations += 1 }
                }
                let conflictedIds = (try? crossProfileConflictedConversationIds(
                    payloads: batchPayloads.filter { !localConversationsById.keys.contains($0.id) },
                    currentProfileId: scopedProfileId, in: context
                )) ?? Set<String>()

                for incoming in batchPayloads {
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
                        conversation.source = "claude"
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
                completionText: finishText(
                    prefix: "叠加完成！",
                    added: addedConversations,
                    updated: updatedConversations,
                    skipped: skippedConversations,
                    ignored: ignoredConversations
                ) + crossProfileConflictSuffix(crossProfileConflicts)
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

    private func makePayload(from raw: ClaudeRawConversation) -> ImportedConversationPayload? {
        let messages = raw.chat_messages ?? []
        guard !messages.isEmpty else { return nil }

        // Parent 解析：优先 export 自带的 parent_message_uuid，fallback 到 index-1 的 linear 假设。
        func resolveParentId(at index: Int) -> String? {
            let msg = messages[index]
            if let p = msg.parent_message_uuid, !p.isEmpty {
                return p
            }
            return index == 0 ? nil : messages[index - 1].uuid
        }

        // 反向建 childrenIds：parent -> [child uuid]，按 messages 顺序排（保留 Claude 排序）。
        var childrenByParent: [String: [String]] = [:]
        for (idx, msg) in messages.enumerated() {
            if let pid = resolveParentId(at: idx) {
                childrenByParent[pid, default: []].append(msg.uuid)
            }
        }

        let encoder = JSONEncoder()
        let nodes = messages.enumerated().map { index, msg -> ImportedNodePayload in
            let segments = Self.extractSegments(from: msg)
            let flatContent = Self.flattenSegmentsForSearch(segments)
            let segmentsData = try? encoder.encode(segments)
            return ImportedNodePayload(
                id: msg.uuid,
                role: mapSender(msg.sender),
                content: flatContent,
                contentType: "segmented",
                createTime: msg.created_at,
                parentId: resolveParentId(at: index),
                childrenIds: childrenByParent[msg.uuid] ?? [],
                segmentsData: segmentsData
            )
        }

        let hasDisplayableNodes = nodes.contains {
            isDisplayableNode(role: $0.role, content: $0.content)
        }
        guard hasDisplayableNodes else { return nil }

        let trimmedTitle = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ImportedConversationPayload(
            id: raw.uuid,
            title: trimmedTitle.isEmpty ? "无标题" : trimmedTitle,
            createTime: raw.created_at ?? Date.distantPast,
            updateTime: raw.updated_at ?? Date.distantPast,
            currentNodeId: messages.last?.uuid ?? "",
            provider: "claude",
            nodes: nodes
        )
    }

    private func mapSender(_ sender: String?) -> String {
        switch sender {
        case "human": return "user"
        case "assistant": return "assistant"
        default: return sender ?? "unknown"
        }
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

    private func finishText(
        prefix: String,
        added: Int,
        updated: Int,
        skipped: Int,
        ignored: Int
    ) -> String {
        var parts = [prefix, "新增 \(added) 条", "更新 \(updated) 条", "保持本地 \(skipped) 条"]
        if ignored > 0 {
            parts.append("未导入 \(ignored) 条")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - V2: Structured segments

    /// 把 Claude 原始 chat_message 按 `content[]` 顺序解析为结构化分段数组。
    /// 规则：
    /// - `msg.content` 非空 → 只用 content[]（msg.text 是客户端拍平的冗余文本，100% 数据验证过）
    /// - `msg.content` 空且 `msg.text` 非空 → fallback 单个 `.text(msg.text)`（防御未来导出版本）
    /// - `attachments[]` / `files[]` 作为独立段追加到末尾（粟粟决策 3）
    /// - 未知 block type 跳过（不丢数据，也不污染 UI）
    static func extractSegments(from msg: ClaudeRawMessage) -> [MessageSegment] {
        var segs: [MessageSegment] = []
        let blocks = msg.content ?? []

        if blocks.isEmpty {
            if let t = msg.text, !t.isEmpty {
                segs.append(.text(t))
            }
        } else {
            for block in blocks {
                switch block.type {
                case "text":
                    if let t = block.text, !t.isEmpty {
                        segs.append(.text(t))
                    }
                case "thinking":
                    if let t = block.thinking, !t.isEmpty {
                        segs.append(.thinking(text: t, signature: block.signature))
                    }
                case "tool_use":
                    let inputJSON = Self.encodeAnyJSON(block.input)
                    segs.append(.toolUse(
                        id: block.id ?? "",
                        name: block.name ?? "",
                        inputJSON: inputJSON,
                        integrationName: block.integration_name,
                        iconName: block.icon_name
                    ))
                case "tool_result":
                    let flatText = Self.flattenToolResultContent(block.content)
                    segs.append(.toolResult(
                        toolUseId: block.tool_use_id ?? "",
                        text: flatText,
                        isError: block.is_error ?? false,
                        integrationName: block.integration_name
                    ))
                case "flag":
                    segs.append(.flag(
                        kind: block.flag ?? "",
                        helplineName: block.helpline?.name,
                        helplinePhone: block.helpline?.phone_number,
                        helplineUrl: block.helpline?.web_chat_url ?? block.helpline?.url
                    ))
                default:
                    // 未知 block type（redacted_thinking / server_tool_use 等）留给未来扩展
                    break
                }
            }
        }

        // attachments（文本附件，extracted_content 已提取好）→ trailing
        if let attachments = msg.attachments {
            for entry in attachments {
                guard let dict = entry.value as? [String: AnyCodable] else { continue }
                let name = (dict["file_name"]?.value as? String)
                    ?? (dict["name"]?.value as? String)
                    ?? ""
                let type = dict["file_type"]?.value as? String
                let extracted = dict["extracted_content"]?.value as? String
                if !name.isEmpty || (extracted?.isEmpty == false) {
                    segs.append(.attachment(name: name, type: type, extractedContent: extracted))
                }
            }
        }

        // files（图像/二进制，export 通常另存在 zip）→ trailing
        if let files = msg.files {
            for entry in files {
                guard let dict = entry.value as? [String: AnyCodable] else { continue }
                let name = (dict["file_name"]?.value as? String) ?? ""
                let uuid = (dict["file_uuid"]?.value as? String) ?? ""
                if !name.isEmpty {
                    segs.append(.file(name: name, uuid: uuid))
                }
            }
        }

        return segs
    }

    // MARK: - AnyCodable → JSON string

    /// tool_use.input 是 AnyCodable dict；编码回 JSON 字符串（排序 key，保证搜索 / diff 稳定）。
    static func encodeAnyJSON(_ value: AnyCodable?) -> String {
        guard let value else { return "{}" }
        let raw = unwrap(value.value)
        guard JSONSerialization.isValidJSONObject(raw) else {
            return String(describing: raw)
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: raw,
            options: [.sortedKeys, .prettyPrinted]
        ), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    /// 把嵌套 AnyCodable / [AnyCodable] / [String: AnyCodable] 解包成 JSONSerialization 能吃的原生类型。
    private static func unwrap(_ value: Any) -> Any {
        if let any = value as? AnyCodable { return unwrap(any.value) }
        if let dict = value as? [String: AnyCodable] {
            return dict.mapValues { unwrap($0.value) }
        }
        if let arr = value as? [AnyCodable] {
            return arr.map { unwrap($0.value) }
        }
        return value
    }

    /// tool_result.content 在实测里 100% 是 `[{"type": "text", "text": "..."}]` 列表。
    /// 扁平化成单个字符串（多条用 `\n\n` 连接）。遇到非 text block 用 `[type]` 占位。
    static func flattenToolResultContent(_ value: AnyCodable?) -> String {
        guard let value else { return "" }
        if let str = value.value as? String { return str }
        guard let arr = value.value as? [AnyCodable] else { return "" }
        var parts: [String] = []
        for item in arr {
            if let dict = item.value as? [String: AnyCodable] {
                let type = dict["type"]?.value as? String ?? "unknown"
                if type == "text" {
                    if let t = dict["text"]?.value as? String, !t.isEmpty {
                        parts.append(t)
                    }
                } else {
                    parts.append("[\(type)]")
                }
            } else if let s = item.value as? String {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Flattened search text

    /// 把 segments 压扁成"可搜索正文"，写入 MessageNode.content。搜索逻辑不改。
    /// thinking 段用 `<<<THINK>>>...<<</THINK>>>` 包起来，P6 的"搜索思考"toggle 用这对 marker 做筛选。
    static func flattenSegmentsForSearch(_ segs: [MessageSegment]) -> String {
        var parts: [String] = []
        for seg in segs {
            switch seg {
            case .text(let s):
                if !s.isEmpty { parts.append(s) }
            case .thinking(let text, _):
                if !text.isEmpty { parts.append("<<<THINK>>>\n\(text)\n<<</THINK>>>") }
            case .toolUse(_, let name, let inputJSON, _, _):
                parts.append("🔧 \(name) \(inputJSON)")
            case .toolResult(_, let text, let isError, _):
                if !text.isEmpty {
                    parts.append(isError ? "[tool error] \(text)" : text)
                }
            case .flag(let kind, let hName, _, _):
                parts.append("⚠️ flag:\(kind)\(hName.map { " (\($0))" } ?? "")")
            case .attachment(let name, _, let extracted):
                var s = "📎 \(name)"
                if let ex = extracted, !ex.isEmpty { s += "\n\(ex)" }
                parts.append(s)
            case .file(let name, _):
                parts.append("🖼 \(name)")
            case .audioRef(let name, _, _, _, let script):
                parts.append("🎤 \(name)\(script.map { "\n\($0)" } ?? "")")
            case .image(let name, _, _):
                parts.append("🖼 \(name)")
            case .fileData(let name, _, _):
                parts.append("📎 \(name)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

}

// MARK: - Claude Raw JSON Types

struct ClaudeRawConversation: Decodable {
    let uuid: String
    let name: String?
    let summary: String?
    let created_at: Date?
    let updated_at: Date?
    let account: ClaudeRawAccount?
    let chat_messages: [ClaudeRawMessage]?
}

struct ClaudeRawAccount: Decodable {
    let uuid: String?
}

struct ClaudeRawMessage: Decodable {
    let uuid: String
    let text: String?
    let content: [ClaudeContentBlock]?
    let sender: String?
    let created_at: Date?
    let updated_at: Date?
    let attachments: [AnyCodable]?
    let files: [AnyCodable]?
    /// Claude export 实测 100% 出现（16894/16894）。用来替换 index-1 的 linear 假设。
    let parent_message_uuid: String?
}

struct ClaudeContentBlock: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let name: String?          // tool_use / tool_result 的工具名
    let start_timestamp: String?
    let stop_timestamp: String?
    let flags: AnyCodable?
    let citations: [AnyCodable]?

    // tool_use
    let id: String?
    let input: AnyCodable?

    // tool_result
    let tool_use_id: String?
    let content: AnyCodable?
    let is_error: Bool?

    // thinking 扩展（Opus 4.x / Sonnet 4.x）
    let signature: String?

    // tool_use / tool_result 的 MCP 集成元信息
    let integration_name: String?
    let icon_name: String?

    // flag 块（Claude.ai 客户端扩展，API 里没有）
    let flag: String?
    let helpline: ClaudeHelpline?

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, name
        case start_timestamp, stop_timestamp, flags, citations
        case id, input, tool_use_id, content, is_error
        case signature, integration_name, icon_name
        case flag, helpline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        start_timestamp = try container.decodeIfPresent(String.self, forKey: .start_timestamp)
        stop_timestamp = try container.decodeIfPresent(String.self, forKey: .stop_timestamp)
        flags = try container.decodeIfPresent(AnyCodable.self, forKey: .flags)
        citations = try container.decodeIfPresent([AnyCodable].self, forKey: .citations)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        input = try container.decodeIfPresent(AnyCodable.self, forKey: .input)
        tool_use_id = try container.decodeIfPresent(String.self, forKey: .tool_use_id)
        content = try container.decodeIfPresent(AnyCodable.self, forKey: .content)
        is_error = try container.decodeIfPresent(Bool.self, forKey: .is_error)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        integration_name = try container.decodeIfPresent(String.self, forKey: .integration_name)
        icon_name = try container.decodeIfPresent(String.self, forKey: .icon_name)
        flag = try container.decodeIfPresent(String.self, forKey: .flag)
        helpline = try container.decodeIfPresent(ClaudeHelpline.self, forKey: .helpline)
    }
}

struct ClaudeHelpline: Decodable {
    let id: String?
    let name: String?
    let phone_number: String?
    let sms_number: String?
    let web_chat_url: String?
    let url: String?
}
