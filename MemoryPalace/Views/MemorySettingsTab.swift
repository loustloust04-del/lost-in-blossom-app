import SwiftUI
import SwiftData

// MARK: - iOS Memory Settings

struct IOSMemoryPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    @State private var memories: [Memory] = []
    @State private var newNoteText = ""
    @State private var editingNoteId: UUID? = nil
    @State private var editingNoteText = ""
    @AppStorage("localMemoryEnabled") private var localMemoryEnabled = true
    @AppStorage(LocalMemoryMode.storageKey) private var localMemoryModeRaw = ""
    @AppStorage("memoryExplanationExpanded") private var memoryExplanationExpanded = true
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @AppStorage("customMemoryExtractionPrompt") private var customMemoryPrompt = ""
    @State private var isEditingPrompt = false
    @State private var isSweeping = false
    @State private var sweepResult: String? = nil

    var body: some View {
        let profileId = profileManager?.currentProfile.id ?? ""
        let hotMems = memories.filter { DecayEngine.tier($0) == .hot }
        let warmMems = memories.filter { DecayEngine.tier($0) == .warm }
        let coldMems = memories.filter { DecayEngine.tier($0) == .cold }
        let totalTokens = hotMems.reduce(0) { $0 + $1.tokenCount }

        List {
            // 本地记忆三态开关（开启 / 仅记录 / 关闭）
            Section {
                Picker("记忆系统", selection: Binding(
                    get: { LocalMemoryMode.current },
                    set: { mode in
                        localMemoryModeRaw = mode.rawValue
                        // 同步旧布尔键（兼容可能残留的读取方）
                        localMemoryEnabled = mode != .off
                    }
                )) {
                    ForEach(LocalMemoryMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("开启 = 正常提取 + 注入提示词；仅记录 = 继续在后台生成记忆但不注入（静默攒着）；关闭 = 提取和注入都停。已有记忆任何模式下都不会删除。")
                    .font(.system(size: Theme.F.caption))
            }

            // 说明
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { memoryExplanationExpanded.toggle() }
                } label: {
                    HStack {
                        Text("记忆系统说明")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Image(systemName: memoryExplanationExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)

                if memoryExplanationExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        memoryExplanationLine("每轮对话后，后台自动用小模型分析对话，提取值得记住的事实")
                        memoryExplanationLine("🟢 活跃记忆会注入每次对话")
                        memoryExplanationLine("🟠 7 天没提起进入休眠")
                        memoryExplanationLine("📌 手动钉住永远不会忘")
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 提取模型（只读提示；切换入口在 API 设置 model list 的 🌛）
            Section("配置") {
                HStack {
                    Text("提取模型")
                        .font(.system(size: Theme.F.label))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text(iosMemoryModelDisplayName)
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                Text("在 API 设置里点击模型旁 🌛 可切换副模型。不选就自动用主 provider 的便宜款。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)

                HStack(spacing: 12) {
                    memoryStatBadge("总计", count: memories.count, color: Theme.textSecondary)
                    memoryStatBadge("活跃", count: hotMems.count, color: Theme.branchIndicator)
                    memoryStatBadge("休眠", count: warmMems.count, color: .orange)
                    memoryStatBadge("冷藏", count: coldMems.count, color: Theme.textMuted)
                }
                Text("注入 \(totalTokens) / \(MemoryInjector.tokenBudget) token")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)

                // 提取提示词
                Button {
                    isEditingPrompt.toggle()
                } label: {
                    HStack {
                        Text("提取提示词")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text(customMemoryPrompt.isEmpty ? "默认" : "自定义")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            if isEditingPrompt {
                Section("提取提示词") {
                    TextEditor(text: $customMemoryPrompt)
                        .font(.system(size: Theme.F.caption, design: .monospaced))
                        .frame(minHeight: 200)

                    if !customMemoryPrompt.isEmpty {
                        Button("恢复默认") {
                            customMemoryPrompt = ""
                        }
                        .foregroundColor(.red.opacity(0.7))
                        .font(.system(size: Theme.F.secondary))
                    }

                    Text("留空使用默认提示词。可用占位符：{{MEMORIES}}")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                }
                .listRowBackground(Theme.mainBg)
            }

            // 三温区
            if !memories.isEmpty {
                if !hotMems.isEmpty {
                    Section("活跃") {
                        ForEach(hotMems, id: \.id) { memory in
                            memoryRow(memory, tierColor: Theme.branchIndicator, profileId: profileId)
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }
                if !warmMems.isEmpty {
                    Section("休眠") {
                        ForEach(warmMems, id: \.id) { memory in
                            memoryRow(memory, tierColor: .orange, profileId: profileId)
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }
                if !coldMems.isEmpty {
                    Section("冷藏") {
                        ForEach(coldMems, id: \.id) { memory in
                            memoryRow(memory, tierColor: Theme.textMuted, profileId: profileId)
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    Text("还没有记忆")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }

            // 手动添加
            Section("手动添加") {
                TextEditor(text: $newNoteText)
                    .font(.system(size: Theme.F.body))
                    .frame(height: 60)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                    .scrollContentBackground(.hidden)

                Button {
                    let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    let store = SwiftDataMemoryStore()
                    // 原为 try?：存不进去她不知道（审查报告 Views P0 #4）
                    do { try store.add(
                        content: text, category: "fact", keywords: [],
                        profileId: profileId, isUserExplicit: true, extractedBy: "manual",
                        sourceConversationId: nil, context: modelContext
                    ) } catch { ToastCenter.shared.show("这条记忆没存上，再试一次？"); return }
                    newNoteText = ""
                    refreshMemories()
                } label: {
                    Text("添加")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            // 记忆卫生工具
            Section {
                Button {
                    Task { await runHygieneSweep() }
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundColor(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("整理记忆")
                                .font(.system(size: Theme.F.body, weight: .medium))
                            Text("配对去重：相似度 > 75% 的记忆保新去旧")
                                .font(.system(size: Theme.F.caption))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if isSweeping {
                            ProgressView()
                        }
                    }
                }
                .disabled(isSweeping)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshMemories() }
        // 切楼层 race defense，见 docs/plan-profile-switch-atomic.md
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            memories = []
        }
    }

    // MARK: - Helpers

    private func memoryExplanationLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textSecondary)
    }

    private var iosMemoryModelDisplayName: String {
        guard let pm = providerManager else { return "—" }
        if !memoryExtractModelId.isEmpty,
           let m = pm.enabledProviders.flatMap(\.models).first(where: { $0.id == memoryExtractModelId }) {
            return m.name
        }
        return "自动"
    }

    private func memoryStatBadge(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private func memoryRow(_ memory: Memory, tierColor: Color, profileId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Circle().fill(tierColor).frame(width: 5, height: 5)

                let categoryLabels: [String: String] = [
                    "preference": "偏好", "fact": "事实", "relationship": "关系",
                    "goal": "目标", "context": "情境",
                ]
                Text(categoryLabels[memory.category] ?? memory.category)
                    .font(.system(size: Theme.F.badge, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tierColor.opacity(0.7)))

                if memory.isUserExplicit {
                    Image(systemName: "pin.fill")
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.branchIndicator)
                }

                Spacer()

                Text(memory.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }

            // Content
            if editingNoteId == memory.id {
                TextEditor(text: $editingNoteText)
                    .font(.system(size: Theme.F.body))
                    .frame(height: 50)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    .scrollContentBackground(.hidden)

                HStack(spacing: 8) {
                    Button("取消") { editingNoteId = nil }
                        .font(.caption).foregroundColor(Theme.textMuted).buttonStyle(.plain)
                    Button("保存") {
                        let store = SwiftDataMemoryStore()
                        do { try store.update(id: memory.id, content: editingNoteText, keywords: memory.keywords, context: modelContext) }
                        catch { ToastCenter.shared.show("改动没保存上"); return }
                        editingNoteId = nil
                        refreshMemories()
                    }
                    .font(.caption).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.branchIndicator))
                    .buttonStyle(.plain)
                }
            } else {
                Text(memory.content)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
            }

            // Actions
            if editingNoteId != memory.id {
                HStack(spacing: 12) {
                    Button(memory.isUserExplicit ? "取消钉住" : "钉住") {
                        SwiftDataMemoryStore().togglePin(memory, touchUpdatedAt: false, context: modelContext)
                        refreshMemories()
                    }
                    .font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted).buttonStyle(.plain)

                    Button("编辑") {
                        editingNoteText = memory.content
                        editingNoteId = memory.id
                    }
                    .font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted).buttonStyle(.plain)

                    Button("删除") {
                        SwiftDataMemoryStore().delete(memory, context: modelContext)
                        refreshMemories()
                    }
                    .font(.system(size: Theme.F.secondary)).foregroundColor(Theme.danger).buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.assistantBubble))
    }

    private func runHygieneSweep() async {
        guard let profileId = profileManager?.currentProfile.id else { return }
        isSweeping = true
        defer { isSweeping = false }
        do {
            let report = try await MemoryHygiene.sweep(profileId: profileId, context: modelContext)
            sweepResult = "完成：去重 \(report.merged) 条，剩余 \(report.remaining) 条"
            refreshMemories()
        } catch {
            sweepResult = "失败：\(error.localizedDescription)"
        }
    }

    private func refreshMemories() {
        let profileId = profileManager?.currentProfile.id ?? ""
        let store = SwiftDataMemoryStore()
        memories = store.listAll(profileId: profileId, context: modelContext)
    }
}
