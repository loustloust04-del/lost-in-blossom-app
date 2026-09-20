import SwiftUI

/// 上下文压缩检查器：查看当前对话的压缩摘要，手动编辑 / 删除 / 重 Roll。
/// 入口：聊天页顶栏 ··· 菜单。
/// 机制回顾：窗口涨到 60 条触发压缩、一刀裁回 30 条（滞回，保 prompt cache）；
/// 摘要以独立层注入 system，覆盖的旧消息不再进 API body。
struct ContextSummarySheet: View {
    let viewModel: ConversationViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("selectedChatModel") private var selectedModelId = ""

    @State private var summary: ContextSummary? = nil
    @State private var editedText = ""
    @State private var working = false
    @State private var message: String? = nil
    @State private var confirmDelete = false

    private var conversationId: String? { viewModel.selectedConversation?.id }

    /// 当前可见消息条数（和 buildAPIMessages 的口径一致：user/assistant 且非空）
    private var displayableCount: Int {
        viewModel.currentPath.filter {
            ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty
        }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if summary != nil {
                    editorSection
                }
                actionSection
            }
            .navigationTitle("上下文压缩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { reload() }
            .alert("上下文压缩", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .alert("删除压缩摘要？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    guard let cid = conversationId else { return }
                    ContextSummarizer.clear(conversationId: cid)
                    reload()
                    message = "已删除。下一轮起窗口从头计，消息数再涨到阈值会自动重新压缩。"
                }
            } message: {
                Text("删除后被压缩的旧消息会重新以原文形式计入窗口（注意：窗口会立刻变长，token 消耗回升，直到再次触发压缩）。")
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section("状态") {
            if let s = summary {
                LabeledContent("已压缩", value: "前 \(s.coveredCount) 条消息")
                LabeledContent("当前窗口", value: "第 \(s.coveredCount + 1) 条起 · 共 \(max(0, displayableCount - s.coveredCount)) 条原文")
                LabeledContent("上次更新", value: s.updatedAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                LabeledContent("已压缩", value: "无")
                LabeledContent("当前消息数", value: "\(displayableCount) 条")
                Text("窗口涨到 \(ContextSummarizer.highWater) 条会自动压缩（裁回 \(ContextSummarizer.lowWater) 条原文 + 一段摘要）。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    // MARK: - 编辑

    private var editorSection: some View {
        Section {
            TextEditor(text: $editedText)
                .frame(minHeight: 180, maxHeight: 320)
                .font(.system(size: 13))
            Button {
                guard let cid = conversationId, let s = summary else { return }
                let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { message = "摘要不能为空（要清空请用删除）"; return }
                ContextSummarizer.save(
                    ContextSummary(summary: text, coveredCount: s.coveredCount, updatedAt: Date()),
                    conversationId: cid
                )
                reload()
                message = "已保存，下一轮对话生效。"
            } label: {
                Text("保存编辑")
                    .font(.system(size: 14, weight: .medium))
            }
            .disabled(editedText == (summary?.summary ?? ""))
        } header: {
            Text("摘要内容（可编辑）")
        } footer: {
            Text("这段文字会以独立层注入 system prompt，代表被折叠的旧对话。改它 = 改他对过去的记忆。")
                .font(.system(size: 12))
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                reroll()
            } label: {
                HStack {
                    if working {
                        ProgressView().controlSize(.small)
                        Text("重新生成中…")
                    } else {
                        Image(systemName: "dice")
                        Text("重 Roll（清掉重新压缩）")
                    }
                }
                .font(.system(size: 14, weight: .medium))
            }
            .disabled(working)

            if summary != nil {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("删除压缩摘要")
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .disabled(working)
            }
        } footer: {
            Text("重 Roll 用便宜模型按当前全量历史重新压缩；消息数不足阈值时会保持未压缩状态。")
                .font(.system(size: 12))
        }
    }

    // MARK: - 数据

    private func reload() {
        guard let cid = conversationId else { return }
        summary = ContextSummarizer.load(conversationId: cid)
        editedText = summary?.summary ?? ""
    }

    private func reroll() {
        guard let pm = providerManager else { message = "ProviderManager 不可用"; return }
        let prof = profileManager?.currentProfile
        let preset = presetManager?.preset(byId: prof?.presetId ?? "") ?? Preset.balanced
        let model = pm.model(byId: selectedModelId)
            ?? pm.availableModels.first
            ?? ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4")
        working = true
        Task {
            let err = await viewModel.rerollContextSummary(model: model, preset: preset, providerManager: pm)
            await MainActor.run {
                working = false
                reload()
                if let err {
                    message = "重 Roll 失败：\(err)"
                } else if summary == nil {
                    message = "当前消息数（\(displayableCount)）未到压缩阈值（\(ContextSummarizer.highWater)），保持未压缩。"
                } else {
                    message = "已重新生成。"
                }
            }
        }
    }
}
