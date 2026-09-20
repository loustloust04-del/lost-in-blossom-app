import SwiftUI
import SwiftData

struct ImportHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    let profileId: String
    @Query private var records: [ImportRecord]
    @State private var recordToDelete: ImportRecord?
    @State private var isDeleting = false
    @State private var deleteProgress: Double = 0
    @State private var deleteTotal: Int = 0

    init(profileId: String) {
        self.profileId = profileId
        _records = Query(
            filter: #Predicate<ImportRecord> { $0.profileId == profileId },
            sort: \ImportRecord.importDate,
            order: .reverse
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导入历史")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            if records.isEmpty {
                Text("还没有导入记录")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(records) { record in
                        ImportRecordRow(
                            record: record,
                            isDeleting: isDeleting,
                            onUndo: record.supportsUndo ? { recordToDelete = record } : nil
                        )
                    }
                }
            }

            if isDeleting {
                VStack(spacing: 6) {
                    ProgressView(value: deleteProgress, total: Double(deleteTotal))
                        .tint(Theme.branchIndicator)
                    Text("正在撤回 \(Int(deleteProgress))/\(deleteTotal)")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        .confirmationDialog(
            "确认撤回",
            isPresented: Binding(
                get: { recordToDelete != nil },
                set: { if !$0 { recordToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("撤回此次导入", role: .destructive) {
                if let record = recordToDelete {
                    undoImport(record)
                }
                recordToDelete = nil
            }
            Button("取消", role: .cancel) {
                recordToDelete = nil
            }
        } message: {
            if let record = recordToDelete {
                Text(undoMessage(for: record))
            }
        }
    }

    private func undoMessage(for record: ImportRecord) -> String {
        if record.mode == .merge {
            return "将撤回这次叠加导入：新增 \(record.addedConversationCount) 条，更新 \(record.updatedConversationCount) 条。撤回后会恢复到导入前状态。"
        }

        return "将撤回这次普通导入新增的 \(record.addedConversationCount) 条对话。"
    }

    private func undoImport(_ record: ImportRecord) {
        let recordId = record.id
        let container = modelContext.container

        isDeleting = true
        deleteProgress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let bgContext = ModelContext(container)

            let scopedProfileId = self.profileId
            let changeDescriptor = FetchDescriptor<ImportConversationChange>(
                predicate: #Predicate<ImportConversationChange> { $0.recordId == recordId && $0.profileId == scopedProfileId }
            )
            guard let changes = try? bgContext.fetch(changeDescriptor) else {
                DispatchQueue.main.async {
                    isDeleting = false
                }
                return
            }

            DispatchQueue.main.async {
                deleteTotal = max(changes.count, 1)
            }

            for (index, change) in changes.enumerated() {
                do {
                    try restoreConversationChange(change, in: bgContext)
                    if (index + 1) % 25 == 0 {
                        try bgContext.save()
                    }
                } catch {
                    DispatchQueue.main.async {
                        isDeleting = false
                    }
                    return
                }

                DispatchQueue.main.async {
                    deleteProgress = Double(index + 1)
                }
            }

            for change in changes {
                bgContext.delete(change)
            }

            let recordDescriptor = FetchDescriptor<ImportRecord>(
                predicate: #Predicate<ImportRecord> { $0.id == recordId && $0.profileId == scopedProfileId }
            )
            if let existingRecord = try? bgContext.fetch(recordDescriptor).first {
                bgContext.delete(existingRecord)
            }

            try? bgContext.save()

            DispatchQueue.main.async {
                isDeleting = false
            }
        }
    }
}

// MARK: - Import Record Row

struct ImportRecordRow: View {
    let record: ImportRecord
    let isDeleting: Bool
    let onUndo: (() -> Void)?

    private var providerLabel: String {
        switch record.provider {
        case "chatgpt": return "ChatGPT"
        case "claude": return "Claude"
        default: return record.provider
        }
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: record.importDate)
    }

    private var modeLabel: String {
        if record.isLegacyRecord {
            return "旧记录"
        }

        switch record.mode {
        case .normal:
            return "普通导入"
        case .merge:
            return "叠加导入"
        }
    }

    private var summaryText: String {
        if record.isLegacyRecord {
            return "\(record.conversationCount) 条对话 · 暂不支持安全撤回"
        }

        var parts = [
            modeLabel,
            "新增 \(record.addedConversationCount)",
            "更新 \(record.updatedConversationCount)",
            "保持本地 \(record.skippedConversationCount)"
        ]
        if record.ignoredConversationCount > 0 {
            parts.append("未导入 \(record.ignoredConversationCount)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.fileName)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    Text(providerLabel)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Theme.branchIndicator.opacity(0.12))
                        )
                }

                HStack(spacing: 8) {
                    Text(summaryText)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                    Text(dateString)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
            }

            Spacer()

            if let onUndo {
                Button(action: onUndo) {
                    Text("撤回")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
                .opacity(isDeleting ? 0.4 : 1)
            } else {
                Text(record.isLegacyRecord ? "旧记录" : "不可撤回")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.mainBg.opacity(0.5))
        )
    }
}
