import SwiftUI
import SwiftData

// MARK: - Data Settings Tab

struct DataSettingsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @AppStorage("exportMode") private var exportMode = "lightweight"
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    @State private var isExportingAll = false
    @State private var exportProgress: Double = 0
    @State private var exportTotal: Int = 0

    @State private var isExportingAllProfiles = false
    @State private var exportAllProfilesProgress: Double = 0
    @State private var exportAllProfilesTotal: Int = 0

    @State private var showImporter = false

    // Claude 数据清除（P5：切换到 segments 格式前一次性清干净）
    @State private var wipeConfirm = false
    @State private var wipePreview: ClaudeDataWiper.Preview? = nil
    @State private var wipeResultMessage: String? = nil
    @State private var isWiping = false

    private var currentProfileId: String {
        profileManager?.currentProfile.id ?? ""
    }

    private func refreshWipePreview() {
        wipePreview = try? ClaudeDataWiper.preview(
            profileId: currentProfileId,
            context: modelContext
        )
    }

    private func runClaudeWipe() {
        isWiping = true
        let pid = currentProfileId
        let ctx = modelContext
        DispatchQueue.global(qos: .userInitiated).async {
            let bgCtx = ModelContext(ctx.container)
            do {
                let result = try ClaudeDataWiper.wipe(profileId: pid, context: bgCtx)
                DispatchQueue.main.async {
                    wipeResultMessage = "已清除 \(result.conversationCount) 条对话 · \(result.nodeCount) 条消息 · \(result.importRecordCount) 条导入记录。现在可以重新导入。"
                    wipePreview = nil
                    isWiping = false
                }
            } catch {
                DispatchQueue.main.async {
                    wipeResultMessage = "清除失败：\(error.localizedDescription)"
                    isWiping = false
                }
            }
        }
    }

    @ViewBuilder
    private var claudeWipeSectionContent: some View {
        if let msg = wipeResultMessage {
            Text(msg)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        } else if isWiping {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("清除中...").font(.caption).foregroundColor(Theme.textMuted)
            }
        } else {
            Button {
                refreshWipePreview()
                wipeConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("清空本楼层 Claude 导入数据")
                }
                .font(.system(size: Theme.SettingsFont.secondary))
                .foregroundColor(Theme.danger)
            }
            .buttonStyle(.plain)
        }

        Text("用于切换到新 segments 格式前清理旧导入。只清 Claude，不动 ChatGPT / API / 预设 / 记忆等。")
            .font(.caption)
            .foregroundColor(Theme.textMuted)
    }

    private var wipeAlertMessage: String {
        guard let p = wipePreview else { return "将清除本楼层所有 Claude 导入数据。" }
        return "本楼层将删除 \(p.conversationCount) 条 Claude 对话 · \(p.nodeCount) 条消息 · \(p.importRecordCount) 条导入记录。\n\n不可撤销。"
    }

    var body: some View {
        Group {
            iOSBody
        }
        .alert("清空 Claude 数据", isPresented: $wipeConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { runClaudeWipe() }
        } message: {
            Text(wipeAlertMessage)
        }
    }

    /// iOS version wrapped in List with sections
    var iOSBody: some View {
        List {
            Section("导入") {
                Button(action: { showImporter = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入对话")
                        Spacer()
                    }
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("支持 ChatGPT / Claude 导出包")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("导出对话数据") {
                VStack(spacing: 4) {
                    ExportModeRow(title: "轻量模式", description: "自动选择最长分支导出", isSelected: exportMode == "lightweight") {
                        exportMode = "lightweight"
                    }
                    ExportModeRow(title: "全面模式", description: "导出时可选路径，分支用折叠显示", isSelected: exportMode == "full") {
                        exportMode = "full"
                    }
                }

                if isExportingAll {
                    VStack(spacing: 6) {
                        ProgressView(value: exportProgress, total: Double(exportTotal))
                            .tint(Theme.branchIndicator)
                        Text("导出中 \(Int(exportProgress))/\(exportTotal)")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    Button(action: { exportAllConversations() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up.on.square")
                            Text("导出本楼层对话")
                            Spacer()
                        }
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.branchIndicator)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isExportingAllProfiles {
                    VStack(spacing: 6) {
                        ProgressView(value: exportAllProfilesProgress, total: Double(exportAllProfilesTotal))
                            .tint(Theme.branchIndicator)
                        Text("全部楼层导出中 \(Int(exportAllProfilesProgress))/\(exportAllProfilesTotal)")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    Button(action: { exportAllProfilesData() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "archivebox")
                            Text("导出全部对话")
                            Spacer()
                        }
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.branchIndicator)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                HStack {
                    Text("整包备份（迁移换机）")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Text("即将支持")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent.opacity(0.4)))
                }
            } header: {
                Text("导出全局数据")
            } footer: {
                Text("包含楼层列表、API、预设、助手模板、世界书、记忆、贴纸等全部配置。")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("导入历史") {
                ImportHistoryView(profileId: profileManager?.currentProfile.id ?? "")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("开发（危险操作）") {
                claudeWipeSectionContent
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("数据与备份")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImporter) {
            ImportView()
                .presentationDetents([.large])
        }
    }

    private func exportAllConversations() {
        return // iOS: 暂不支持批量导出
    }

    /// 遍历所有楼层，按「根目录/{楼层名}/*.md」输出。
    private func exportAllProfilesData() {
        return // iOS: 暂不支持批量导出
    }
}

// MARK: - Export Mode Row

struct ExportModeRow: View {
    let title: String
    let description: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textPrimary)
                    Text(description)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.accent.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
