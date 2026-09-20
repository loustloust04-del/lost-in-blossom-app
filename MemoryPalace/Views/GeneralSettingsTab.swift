import SwiftUI
import SwiftData

// MARK: - iOS General Page

struct IOSGeneralPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @State private var editingUserName = ""
    @State private var editingAssistantName = ""
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("memoryExtractModelId") private var summaryModelId = ""
    @AppStorage("contextSummaryPrompt") private var summaryPrompt = ""
    @State private var summaryRev = 0

    var body: some View {
        List {
            Section("楼层") {
                if let pm = profileManager {
                    ProfileSwitcher(profileManager: pm)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                VStack(spacing: 8) {
                    SettingsTextField(label: "我的名字", placeholder: "你", text: $editingUserName)
                    SettingsTextField(label: "AI 的名字", placeholder: "助手", text: $editingAssistantName)
                }

                HStack {
                    Text("显示在每条消息气泡上方的名称标签")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Button(action: {
                        let newUser = editingUserName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newAssistant = editingAssistantName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !newUser.isEmpty { userName = newUser }
                        if !newAssistant.isEmpty { assistantName = newAssistant }
                        dismiss()
                    }) {
                        Text("确认")
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("气泡标签")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            VoiceMessageSettingsIOSSections()

            Section("推送调试") {
                let token = UserDefaults.standard.string(forKey: "apns_device_token") ?? "未获取"
                let debug = UserDefaults.standard.string(forKey: "push_debug") ?? "未启动"
                Text("链路: \(debug)")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textPrimary)
                Text(token == "未获取" ? "❌ Token: 未获取" : "✅ Token: ...\(token.suffix(8))")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(token == "未获取" ? .red : .green)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("世界书") {
                IOSGeneralWorldBookBindingSection()
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("全部世界书（可删除）") {
                OrphanWorldBookCleanupSection()
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            compressionSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editingUserName = userName
            editingAssistantName = assistantName
        }
    }

    // MARK: - 对话压缩（摘要设置）
    private var compressionSection: some View {
        _ = summaryRev  // 依赖刷新令牌：清除摘要后触发重算
        let cid = UserDefaults.standard.string(forKey: "currentConversationId") ?? ""
        let summary = cid.isEmpty ? nil : ContextSummarizer.load(conversationId: cid)
        return Section("对话压缩") {
            // 1. 摘要模型（存 memoryExtractModelId，ContextSummarizer 走它）
            if let pm = providerManager {
                Picker("摘要模型", selection: $summaryModelId) {
                    Text("默认（跟随设置）").tag("")
                    ForEach(pm.availableModels) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                .font(.system(size: Theme.F.secondary))
            }

            // 2. 压缩提示词（空 = 用 ContextSummarizer 默认）
            VStack(alignment: .leading, spacing: 6) {
                Text("压缩提示词")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                TextEditor(text: $summaryPrompt)
                    .frame(minHeight: 120)
                    .font(.system(size: Theme.F.secondary))
                    .scrollContentBackground(.hidden)
                HStack {
                    Text(summaryPrompt.isEmpty ? "留空使用默认 prompt" : "已自定义")
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Button("载入默认") { summaryPrompt = ContextSummarizer.defaultSummaryPrompt }
                        .font(.system(size: Theme.F.badge))
                    Button("清空") { summaryPrompt = "" }
                        .font(.system(size: Theme.F.badge))
                }
            }

            // 3. 查看当前对话摘要 + 清除
            if let summary {
                DisclosureGroup("当前对话摘要（覆盖 \(summary.coveredCount) 条）") {
                    Text(summary.summary)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                    Button(role: .destructive) {
                        ContextSummarizer.clear(conversationId: cid)
                        summaryRev += 1
                    } label: {
                        Text("清除当前对话摘要")
                    }
                }
                .font(.system(size: Theme.F.secondary))
            } else {
                Text("当前对话暂无摘要")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
    }
}

private struct IOSGeneralWorldBookBindingSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var wbPendingDelete: WorldBook? = nil

    var body: some View {
        let profileId = profileManager?.currentProfile.id ?? ""
        let linkedIds = profileManager?.currentProfile.linkedWorldBookIDs ?? []
        let floorBooks = WorldBookStore.fetchBooks(profileId: profileId, context: modelContext)

        Group {
        if floorBooks.isEmpty {
            Text("当前楼层没有绑定的世界书")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
        } else {
            ForEach(floorBooks, id: \.id) { book in
                HStack(spacing: 8) {
                    Image(systemName: book.scopeConversationId != nil ? "bubble.left" : "book.closed.fill")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.branchIndicator)
                    Text(book.name)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)

                    Text(book.scopeConversationId != nil ? "对话" : "楼层")
                        .font(.system(size: Theme.F.badge, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))

                    Text("\(book.entries.count) 条")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)

                    Spacer()

                    Button {
                        wbPendingDelete = book
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.accent.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        } // Group
        .confirmationDialog("删除世界书",
            isPresented: Binding(
                get: { wbPendingDelete != nil },
                set: { if !$0 { wbPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let book = wbPendingDelete { deleteWorldBook(book) }
                wbPendingDelete = nil
            }
            Button("取消", role: .cancel) { wbPendingDelete = nil }
        } message: {
            if let book = wbPendingDelete {
                Text("确定要删除「\(book.name)」吗？包含 \(book.entries.count) 个条目，不可恢复。")
            }
        }

        Text("在右栏「世界书」tab 里可以新建、导入、编辑世界书")
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted.opacity(0.6))

    }

    private func deleteWorldBook(_ book: WorldBook) {
        WorldBookStore.delete(book, context: modelContext)
        if var profile = profileManager?.currentProfile {
            profile.linkedWorldBookIDs.removeAll { $0 == book.id.uuidString }
            profileManager?.updateProfile(profile)
        }
    }
}


// MARK: - 孤儿世界书清理

private struct OrphanWorldBookCleanupSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var orphans: [WorldBook] = []
    @State private var deletingOrphan: WorldBook? = nil

    var body: some View {
        Group {
            if orphans.isEmpty {
                Text("数据库里没有世界书")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(orphans, id: \.id) { book in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(.orange)
                        Text(book.name)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Text("\(book.entries.count) 条")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                        Text("profileId: \(book.profileId.prefix(8))...")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                        Spacer()
                        Button {
                            deletingOrphan = book
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .confirmationDialog("删除孤儿世界书",
            isPresented: Binding(
                get: { deletingOrphan != nil },
                set: { if !$0 { deletingOrphan = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let book = deletingOrphan {
                    WorldBookStore.delete(book, context: modelContext)
                    orphans.removeAll { $0.id == book.id }
                }
                deletingOrphan = nil
            }
            Button("取消", role: .cancel) { deletingOrphan = nil }
        } message: {
            if let book = deletingOrphan {
                Text("确定要删除「\(book.name)」吗？")
            }
        }
        .onAppear { loadOrphans() }
    }

    private func loadOrphans() {
        orphans = WorldBookStore.fetchAllBooks(context: modelContext)
    }
}
