import SwiftUI
import SwiftData

// MARK: - Profile

struct Profile: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var emoji: String
    var description: String
    var userName: String
    var assistantName: String
    var systemPrompt: String
    var preferredModel: String
    var createdAt: Date

    // Phase 3: 人格系统
    /// 语音条（ElevenLabs 等 TTS）：楼层选定的声音
    var elevenVoiceId: String?
    var elevenVoiceName: String?
    var presetId: String
    var userPersona: String
    var characterDescription: String
    var characterPersonality: String
    var scenario: String
    var chatExamples: String
    var postInstructions: String

    // Phase 4: 角色卡 + 世界书
    var characterCardID: String?             // 来源角色卡标识（角色名）
    var linkedWorldBookIDs: [String]         // 绑定的世界书 UUID 列表
    var coverImageData: Data?                // 封面图（PNG 卡的原图）
    var regexScriptsData: Data?              // JSON encoded [RegexScript]

    /// 正则脚本列表
    var regexScripts: [RegexScript] {
        get {
            guard let data = regexScriptsData else { return [] }
            return (try? JSONDecoder().decode([RegexScript].self, from: data)) ?? []
        }
        set {
            regexScriptsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(id: String = UUID().uuidString, name: String, emoji: String, description: String, userName: String, assistantName: String, systemPrompt: String = "", preferredModel: String = "anthropic/claude-sonnet-4", createdAt: Date = Date(), presetId: String = "built-in-balanced", userPersona: String = "", characterDescription: String = "", characterPersonality: String = "", scenario: String = "", chatExamples: String = "", postInstructions: String = "", characterCardID: String? = nil, linkedWorldBookIDs: [String] = [], coverImageData: Data? = nil, regexScriptsData: Data? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.description = description
        self.userName = userName
        self.assistantName = assistantName
        self.systemPrompt = systemPrompt
        self.preferredModel = preferredModel
        self.createdAt = createdAt
        self.presetId = presetId
        self.userPersona = userPersona
        self.characterDescription = characterDescription
        self.characterPersonality = characterPersonality
        self.scenario = scenario
        self.chatExamples = chatExamples
        self.postInstructions = postInstructions
        self.characterCardID = characterCardID
        self.linkedWorldBookIDs = linkedWorldBookIDs
        self.coverImageData = coverImageData
        self.regexScriptsData = regexScriptsData
    }

    /// **Legacy** 路线 A 时期 per-profile store URL。路线 B 合并到 unified container 后
    /// 只给 `UnifiedContainerMigration` 用（读老数据迁到 unified store）。
    /// 迁移完会 rename 成 `.backup-YYYY-MM-DD`。
    var legacyStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).store")
    }

    /// Legacy ghost-lily 用 SwiftData default store —— 没有 explicit URL，由 SwiftData
    /// 自动放在 `Application Support/<BundleID>/default.store`。迁移时需要读它。
    var usesDefaultStore: Bool { id == "lost-blossom" }

    /// Legacy default store URL（for ghost-lily）—— SwiftData 没有公开 API 返回它，
    /// 只能按它的约定路径构造。
    static var legacyDefaultStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("default.store")
    }

    // Seed profiles for first-launch migration
    static let seedProfiles: [Profile] = [
        Profile(
            id: "default-workspace",
            name: "对话空间",
            emoji: "🏛️",
            description: "对话空间",
            userName: "你",
            assistantName: "助手",
            systemPrompt: "",
            preferredModel: "openai/gpt-4o",
            createdAt: Date(timeIntervalSince1970: 0)
        ),
    ]
}

// MARK: - Profile Manager

@Observable
final class ProfileManager {
    private static let profilesKey = "savedProfiles"

    var profiles: [Profile]
    var currentProfile: Profile
    /// 路线 B：app lifetime 内固定的单一 container。所有 profile 共享这一个 container，
    /// 只靠 profileId 字段过滤数据。不再 swap，彻底消除 SwiftUI + SwiftData env update
    /// 带来的 race。
    let container: ModelContainer

    init(container: ModelContainer, profiles: [Profile], currentProfile: Profile) {
        self.container = container
        self.profiles = profiles
        self.currentProfile = currentProfile
    }

    /// Shared schema definition —— 迁移脚本也用
    static let fullSchema = Schema([
        Conversation.self,
        MessageNode.self,
            WeightEntry.self,
            Medication.self,
            MedicationLog.self,
            CycleDay.self,
            IntimacyEntry.self,
        InspirationNote.self,
        Draft.self,
        DraftSnapshot.self,
        WorkCard.self,
        Song.self,
        UserCard.self,
        ConversationTag.self,
        FavoriteItem.self,
        ImportRecord.self,
        ImportConversationChange.self,
        MemoryNote.self,
        Memory.self,
        WorldBook.self,
        StickerAsset.self,
        PlacedSticker.self,
        DailyContext.self,
        Project.self,
        BookEntry.self,
        WeightEntry.self,
        Medication.self,
        MedicationLog.self,
        CycleDay.self,
        IntimacyEntry.self,
        GroupTurn.self,
        SpeakClaim.self,
    ])

    /// Unified store 的固定路径 —— 所有 profile 数据合并存这一个 SQLite 文件。
    static var unifiedStoreURL: URL {
        let base = URL.applicationSupportDirectory
            .appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("unified.store")
    }

    /// 构造 unified container。App.init 调用一次，app lifetime 内不再重建。
    static func makeUnifiedContainer() -> ModelContainer {
        let config = ModelConfiguration(
            "unified",
            schema: fullSchema,
            url: unifiedStoreURL,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: fullSchema, configurations: [config])
        } catch {
            fatalError("Could not create unified ModelContainer: \(error)")
        }
    }

    // MARK: - Switch

    func switchTo(_ profile: Profile) {
        guard profile.id != currentProfile.id else { return }
        // post .profileWillSwitch（ultrareview B19 / bug_005）：让 6 处 observer
        // （StickerVM / ConversationVM / Sidebar / MemoryPanel / MemorySettingsTab×2）
        // 在 currentProfile 切换前同步清掉持有的 SwiftData stale ref。
        // ContentView.id(currentProfile.id) 重建 subtree 是主防御，这是 defense-in-depth。
        // queue: nil 同步派发，确保 cleanup 跑完再继续。
        NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
        UserDefaults.standard.set(profile.id, forKey: "lastProfileId")
        UserDefaults.standard.set(profile.userName, forKey: "userName")
        UserDefaults.standard.set(profile.assistantName, forKey: "assistantName")
        // 09-09：切楼层后重报一次，让推送通知的标题跟着换人
        // （不然还显示上一层那个「他」的名字）
        CCBridgeWebSocketClient.shared.refreshAssistantName()
        // 路线 B：container 不动，只翻 currentProfile。@Observable 触发 SwiftUI
        // view rebuild（ContentView 的 .id(currentProfile.id) 识别变化后重建整棵
        // subtree，@Query 用新 profileId predicate refetch）。无 race。
        currentProfile = profile
    }

    // MARK: - CRUD

    func addProfile(_ profile: Profile) {
        profiles.append(profile)
        saveProfiles()
        switchTo(profile)
    }

    func updateProfile(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        saveProfiles()
        if currentProfile.id == profile.id {
            currentProfile = profile
            UserDefaults.standard.set(profile.userName, forKey: "userName")
            UserDefaults.standard.set(profile.assistantName, forKey: "assistantName")
            // 09-09：在当前楼层里改了名字也要重报
            CCBridgeWebSocketClient.shared.refreshAssistantName()
        }
    }

    /// 删楼层：从 profiles list 移除 + 可选地清 unified container 里该 profile 的所有数据
    /// （靠 #Predicate { $0.profileId == deletedId } batch delete）。legacy store 文件不动
    /// （留 .backup 兜底，这是粟粟批注：永久保留）。
    func deleteProfile(_ profile: Profile, deleteData: Bool) {
        guard profiles.count > 1 else { return } // 至少保留一个
        let deletedId = profile.id
        profiles.removeAll(where: { $0.id == deletedId })
        saveProfiles()

        if deleteData {
            let ctx = ModelContext(container)
            // 按 profileId 批量删 unified store 里的所有数据
            try? ctx.delete(model: Conversation.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: MessageNode.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: UserCard.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: ConversationTag.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: FavoriteItem.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: Memory.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: MemoryNote.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: WorldBook.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: StickerAsset.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: PlacedSticker.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: ImportRecord.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: ImportConversationChange.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: WeightEntry.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: Medication.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: MedicationLog.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: CycleDay.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.delete(model: IntimacyEntry.self, where: #Predicate { $0.profileId == deletedId })
            try? ctx.save()
        }

        if currentProfile.id == deletedId {
            switchTo(profiles[0])
        }
    }

    // MARK: - Persistence

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
    }

    static func loadProfiles() -> [Profile] {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data),
           !profiles.isEmpty {
            return profiles
        }
        // First launch: seed and save
        let seed = Profile.seedProfiles
        if let data = try? JSONEncoder().encode(seed) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        return seed
    }
}

// MARK: - Preset Manager

@Observable
final class PresetManager {
    private static let presetsKey = "savedPresets"

    var presets: [Preset]

    init() {
        self.presets = Self.loadPresets()
    }

    /// 当前可用预设（内置 + 用户自定义）
    var allPresets: [Preset] { presets }

    func preset(byId id: String) -> Preset? {
        presets.first(where: { $0.id == id })
    }

    func save(_ preset: Preset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll(where: { $0.id == preset.id })
        persist()
    }

    func duplicate(_ preset: Preset) -> Preset {
        var copy = preset
        copy.id = UUID().uuidString
        copy.name = "\(preset.name) 副本"
        copy.isBuiltIn = false
        presets.append(copy)
        persist()
        return copy
    }

    /// 导入酒馆 JSON 预设
    func importFromSillyTavern(_ data: Data) throws -> Preset {
        var preset = try Preset.fromSillyTavernJSON(data)
        preset.id = UUID().uuidString // 新 ID，避免和已有预设冲突
        presets.append(preset)
        persist()
        return preset
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    private static func loadPresets() -> [Preset] {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let saved = try? JSONDecoder().decode([Preset].self, from: data),
           !saved.isEmpty {
            // 确保内置预设始终存在
            var result = saved
            for builtIn in Preset.allBuiltIn {
                if !result.contains(where: { $0.id == builtIn.id }) {
                    result.insert(builtIn, at: 0)
                }
            }
            return result
        }
        return Preset.allBuiltIn
    }
}

// MARK: - App

@main
struct MemoryPalaceApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var themeManager = ThemeManager.shared
    @State private var profileManager: ProfileManager
    @State private var providerManager = ProviderManager()
    @State private var presetManager = PresetManager()
    @State private var cardManager = CharacterCardManager()
    @State private var toolManager = RightPanelToolManager()
    @State private var globalWorldBookManager = GlobalWorldBookManager()
    @State private var rightPanelNavigator = RightPanelNavigator()

    init() {
        UserDefaults.standard.register(defaults: ["localMemoryEnabled": true])
        let t0 = CFAbsoluteTimeGetCurrent()
        FrameHitchProbe.shared.start()   // 掉帧探针：卡要有数字（面包屑 📉）
        // Phase 3.1: 尽早初始化通知 delegate（须在 willFinishLaunchingWithOptions 前完成）
        _ = LocalNotificationService.shared
        // Phase 3.2: BGTask 注册必须早于 didFinishLaunching
        PushAgentService.registerBackgroundTask()
        FontManager.registerBundledFonts()
        FontManager.registerImportedFonts()
        let tFont = CFAbsoluteTimeGetCurrent()

        // 路线 B: 1 个 unified container. app lifetime 内不换.
        let container = ProfileManager.makeUnifiedContainer()
        let profiles = ProfileManager.loadProfiles()
        let lastId = UserDefaults.standard.string(forKey: "lastProfileId") ?? "lost-blossom"
        let current = profiles.first(where: { $0.id == lastId }) ?? profiles.first ?? Profile.seedProfiles[0]

        let tUnified = CFAbsoluteTimeGetCurrent()

        // 检测 legacy per-profile store 存在且没迁过 → 同步跑迁移
        if UnifiedContainerMigration.needsMigration(profiles: profiles) {
            print("[migration] legacy stores detected, running unified migration...")
            let ctx = ModelContext(container)
            do {
                try UnifiedContainerMigration.runMigration(profiles: profiles, unifiedCtx: ctx)
            } catch {
                print("[migration] FAILED: \(error)")
                // fail-safe: 不 crash. 让 app 启动（可能空）, 粟粟可查 .backup 手动恢复
            }
        }

        let pm = ProfileManager(container: container, profiles: profiles, currentProfile: current)
        let tProfile = CFAbsoluteTimeGetCurrent()
        self._profileManager = State(initialValue: pm)
        Self.migrateMemoryNotesIfNeeded(container: pm.container)

        #if DEBUG && os(iOS)
        ProbeStickerSeed.resetLogFile()
        ProbeStickerSeed.injectIfNeeded(container: pm.container, profileId: pm.currentProfile.id)
        #endif
        let tMigrate = CFAbsoluteTimeGetCurrent()
        print(String(format: "[PERF] App.init total=%.0fms font=%.0fms unified=%.0fms profile=%.0fms migrate=%.0fms",
                     (tMigrate - t0) * 1000,
                     (tFont - t0) * 1000,
                     (tUnified - tFont) * 1000,
                     (tProfile - tUnified) * 1000,
                     (tMigrate - tProfile) * 1000))
    }

    /// MemoryNote → Memory 一次性迁移
    private static func migrateMemoryNotesIfNeeded(container: ModelContainer) {
        let key = "memoryMigrationV2Done"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = ModelContext(container)

        // 查询所有旧 MemoryNote
        let descriptor = FetchDescriptor<MemoryNote>()
        guard let oldNotes = try? context.fetch(descriptor), !oldNotes.isEmpty else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        for note in oldNotes {
            // 只迁移手动创建的，auto 的丢弃（重新提取更好）
            if note.source == "manual" {
                let memory = Memory(
                    content: note.content,
                    category: "fact",
                    keywords: [],
                    profileId: note.profileId,
                    isUserExplicit: true,
                    extractedBy: "migration"
                )
                memory.decayWeight = 1.0
                memory.createdAt = note.createdAt
                memory.updatedAt = note.updatedAt
                context.insert(memory)
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    var body: some Scene {
        WindowGroup {
            // 路线 B：container 全局唯一不动。切楼层只翻 currentProfile → ContentView
            // .id(currentProfile.id) 识别变化后 SwiftUI re-init 整棵 ContentView，所有
            // @Query 用新 profileId predicate 自动 refetch。因为 container 不变，不会有
            // @Model instance 被 destroy，view tree 不论怎么 dismount 都不 crash。
            // Plan: docs/plan-unified-container.md
            ContentView()
                .preferredColorScheme(themeManager.preferredColorScheme)
                .environment(themeManager)
                .environment(profileManager)
                .environment(providerManager)
                .task { PushAgentService.shared.start(profileManager: profileManager, providerManager: providerManager) }
                .environment(presetManager)
                .environment(cardManager)
                .environment(toolManager)
                .environment(globalWorldBookManager)
                .environment(rightPanelNavigator)
                .modelContainer(profileManager.container)
                .id(profileManager.currentProfile.id)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        CCBridgeWebSocketClient.shared.sendAppState("background")
                    case .active:
                        CCBridgeWebSocketClient.shared.sendAppState("foreground")
                        // PR-6: App 回前台时检查未读念头并用本地通知展示
                        Task { await DesireInboxService.shared.checkUnread() }
                        // 语音条续跑：被后台冻结掐断的合成，回前台补完
                        VoiceMessageWriter.resumePending(context: ModelContext(profileManager.container))
                        // 共读：记下当前楼层，供 BookStore.chapterForCompanion 找书
                        UserDefaults.standard.set(profileManager.currentProfile.id, forKey: "coread.profileId")
                        // 灵感盒：补推没同步成功的碎念（Caelum 侧笔记本保持最新）
                        Task { @MainActor in
                            await InspirationSync.pushPending(
                                context: ModelContext(profileManager.container),
                                profileId: profileManager.currentProfile.id)
                        }
                        // PR-4: 启动/回前台对齐本地与网关记忆（仅在后端记忆开关开启时，每进程一次）
                        Task { await MemorySync.shared.alignOnLaunch(container: profileManager.container, profileId: profileManager.currentProfile.id) }
                    default:
                        break
                    }
                }
                .handlesCallBackIntent()
                .onOpenURL { url in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        let name = url.lastPathComponent
                        NotificationCenter.default.post(
                            name: Notification.Name("incomingFileReceived"),
                            object: nil,
                            userInfo: ["data": data, "name": name]
                        )
                    } catch {
                        print("Failed to open file: \(error)")
                    }
                }
        }
    }
}

// MARK: - Profile Switcher (sidebar)

struct ProfileSwitcher: View {
    @Bindable var profileManager: ProfileManager
    @State private var isHovered = false
    @State private var showCreateSheet = false
    @State private var editingProfile: Profile? = nil
    @State private var profileToDelete: Profile? = nil
    @State private var profileToImport: Profile? = nil

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(profileManager.profiles) { profile in
                    Button {
                        profileManager.switchTo(profile)
                    } label: {
                        HStack {
                            Text("\(profile.emoji) \(profile.name)")
                            if profile.id == profileManager.currentProfile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showCreateSheet = true
                } label: {
                    Label("新建楼层", systemImage: "plus.circle")
                }

                Button {
                    editingProfile = profileManager.currentProfile
                } label: {
                    Label("编辑当前楼层", systemImage: "pencil")
                }

                if profileManager.profiles.count > 1 {
                    Button(role: .destructive) {
                        profileToDelete = profileManager.currentProfile
                    } label: {
                        Label("删除当前楼层", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(profileManager.currentProfile.emoji)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profileManager.currentProfile.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Text(profileManager.currentProfile.description)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Theme.accent.opacity(0.3) : Theme.accent.opacity(0.1))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
        .sheet(isPresented: $showCreateSheet, onDismiss: handlePendingImport) {
            ProfileEditorSheet(
                profileManager: profileManager,
                mode: .create,
                onRequestImport: { profile in profileToImport = profile }
            )
        }
        .sheet(item: $editingProfile, onDismiss: handlePendingImport) { profile in
            ProfileEditorSheet(
                profileManager: profileManager,
                mode: .edit(profile),
                onRequestImport: { profile in profileToImport = profile }
            )
        }
        .confirmationDialog(
            "删除楼层",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("仅移除（保留数据）", role: .destructive) {
                if let p = profileToDelete { profileManager.deleteProfile(p, deleteData: false) }
                profileToDelete = nil
            }
            Button("删除楼层和所有数据", role: .destructive) {
                if let p = profileToDelete { profileManager.deleteProfile(p, deleteData: true) }
                profileToDelete = nil
            }
            Button("取消", role: .cancel) { profileToDelete = nil }
        } message: {
            if let p = profileToDelete {
                Text("确定要删除「\(p.emoji) \(p.name)」吗？")
            }
        }
    }

    /// ProfileEditorSheet dismiss 后，如果用户点了「导入聊天记录」，切到目标楼层再发请求导入的 notification
    /// （ContentView observe 并弹 ImportView；这样 sheet 不受 ProfileSwitcher 所在 view tree 重建影响）。
    private func handlePendingImport() {
        guard let profile = profileToImport else { return }
        profileToImport = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if profile.id != profileManager.currentProfile.id {
                profileManager.switchTo(profile)
            }
            NotificationCenter.default.post(name: .memoryPalaceRequestImport, object: nil)
        }
    }
}

extension Notification.Name {
    /// ProfileSwitcher 请求弹 ImportView（用户从「导入聊天记录」进入）。由 ContentView observe。
    static let memoryPalaceRequestImport = Notification.Name("MemoryPalaceRequestImport")

    /// ProfileManager.switchTo 即将切换 currentProfile + container 之前发出。
    /// 订阅者（ConversationViewModel / PagingViewController / MemoryPanelView 等）
    /// 应立即清空对旧 SwiftData 实例的所有 retain，避免路线 C 下旧 SwiftUI sub-tree
    /// 在 container 替换后再跑一次 body 读已 reset 实例触发 fatal。
    /// 见 docs/plan-profile-switch-atomic.md
    static let profileWillSwitch = Notification.Name("MemoryPalaceProfileWillSwitch")

    /// 搜索结果点击后请求把 iOS page 自动切到 chat（page=1）。
    /// 由 SidebarView.navigateToNodeById 发，ContentView 订阅。
    /// 用通知是因为同一对话内点击不会触发 selectedConversation?.id 变化。
    static let conversationNavigationRequested = Notification.Name("MemoryPalaceConversationNavigationRequested")

    /// 用户点击本地通知后，请求打开指定对话。
    /// 由 LocalNotificationService 发，ContentView 订阅。
    /// userInfo["conversationId"] = String
    static let notificationNavigationRequested = Notification.Name("LIBNotificationNavigationRequested")

    /// Add to Chat 面板请求打开设置页。
    /// 由 AddToChatSheet 发，ContentView 订阅。
    static let requestShowSettings = Notification.Name("LIBRequestShowSettings")

    /// 文件库内容变化（CC 工具写文件后）→ FileLibraryPanelView 实时刷新。
    static let fileLibraryDidChange = Notification.Name("LIBFileLibraryDidChange")
}

// MARK: - Profile Editor Sheet

struct ProfileEditorSheet: View {
    let profileManager: ProfileManager
    let mode: Mode
    /// 用户点「导入聊天记录」时触发（保存后），上层负责 switchTo + 弹 ImportView。
    var onRequestImport: ((Profile) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?

    @State private var importAfterSave = false
    @FocusState private var nameFieldFocused: Bool

    enum Mode: Identifiable {
        case create
        case edit(Profile)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let p): return p.id
            }
        }
    }

    @State private var name = ""
    @State private var emoji = ""
    @State private var description = ""
    @State private var userName = "你"
    @State private var assistantName = ""
    @State private var systemPrompt = ""
    @State private var preferredModel = "anthropic/claude-sonnet-4"

    // 角色卡导入
    @State private var characterDescription = ""
    @State private var characterPersonality = ""
    @State private var scenario = ""
    @State private var chatExamples = ""
    @State private var postInstructions = ""
    @State private var importedCard: TavernCard?
    @State private var showFileImporter = false
    @State private var importError: String?

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedEmoji: String {
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmoji.isEmpty {
            return trimmedEmoji
        }
        return importedCard != nil ? "🎭" : "🌸"
    }

    private var title: String {
        switch mode {
        case .create: return "新建楼层"
        case .edit: return "编辑楼层"
        }
    }

    var body: some View {
        let _ = themeManager?.themeChangeID
        Group {
            iOSBody
        }
        .sheet(isPresented: $showFileImporter) {
            DocumentPickerView(contentTypes: [.json, .png]) { urls in
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let card = try TavernCard.parseFile(url: url)
                    importedCard = card
                    // 自动填充表单
                    name = card.name
                    assistantName = card.name
                    emoji = "🎭"
                    description = card.name + "的楼层"
                    characterDescription = card.description
                    characterPersonality = card.personality
                    scenario = card.scenario
                    chatExamples = card.mesExample
                    systemPrompt = card.systemPrompt
                    postInstructions = card.postHistoryInstructions
                } catch {
                    importError = error.localizedDescription
                }
            } onCancel: {}
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            switch mode {
            case .create:
                if emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emoji = "🌸"
                }
            case .edit(let profile):
                name = profile.name
                emoji = profile.emoji
                description = profile.description
                userName = profile.userName
                assistantName = profile.assistantName
                systemPrompt = profile.systemPrompt
                preferredModel = profile.preferredModel
            }
        }
    }

    private var iOSBody: some View {
        editorNavigation
    }

    private var editorNavigation: some View {
        NavigationStack {
            List {
                if case .create = mode {
                    Section("助手模板") {
                        characterCardImportRow
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }

                Section("聊天记录") {
                    conversationImportRow
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("基本信息") {
                    HStack(spacing: 12) {
                        Text("图标")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)

                        Spacer()

                        TextField("🌸", text: $emoji)
                            .textFieldStyle(.plain)
                            .font(.system(size: 24))
                            .frame(width: 56)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 12) {
                        Text("楼层名")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)

                        TextField("例：二层阁楼", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            .focused($nameFieldFocused)
                    }
                    labeledFieldRow(label: "描述", placeholder: "例：对话空间", text: $description)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("气泡标签") {
                    labeledFieldRow(label: "我", placeholder: "你", text: $userName)
                    labeledFieldRow(label: "AI", placeholder: "名字", text: $assistantName)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("默认模型") {
                    Picker("默认模型", selection: $preferredModel) {
                        ForEach(APIProvider.builtIn, id: \.id) { provider in
                            Section(provider.name) {
                                ForEach(provider.models, id: \.id) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                        }
                    }
                    .tint(Theme.branchIndicator)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("系统提示词") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这里会作为当前楼层默认的系统提示词。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)

                        TextEditor(text: $systemPrompt)
                            .font(.system(size: Theme.F.body))
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Theme.sidebarBg)
                            )
                            .scrollContentBackground(.hidden)
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定", action: save)
                        .foregroundColor(isValid ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!isValid)
                }
            }
        }
        .background(Theme.sidebarBg)
    }

    private var conversationImportRow: some View {
        Button {
            guard isValid else {
                nameFieldFocused = true
                return
            }
            importAfterSave = true
            save()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.branchIndicator.opacity(0.14))
                        .frame(width: 34, height: 34)

                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("导入聊天记录")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)

                    Text("保存楼层后，打开 ChatGPT / Claude 导出包导入对话。")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var characterCardImportRow: some View {
        Button {
            showFileImporter = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(importedCard == nil ? Theme.branchIndicator.opacity(0.14) : Theme.branchIndicator)
                        .frame(width: 34, height: 34)

                    Image(systemName: importedCard == nil ? "square.and.arrow.down" : "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(importedCard == nil ? Theme.branchIndicator : .white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(importedCard?.name ?? "导入自定义助手模板")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)

                    Text(importedCard == nil
                         ? "支持 JSON / PNG 助手模板格式，导入后会自动带入楼层信息。"
                         : "已带入助手设定，再点一次可以重新选择文件。")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if importedCard != nil {
                    Text("已导入")
                        .font(.system(size: Theme.F.badge, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Theme.branchIndicator.opacity(0.12))
                        )
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.F.secondary, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func labeledFieldRow(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.F.body))
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalEmoji = normalizedEmoji
        guard !trimmedName.isEmpty else { return }

        switch mode {
        case .create:
            var profile = Profile(
                name: trimmedName,
                emoji: finalEmoji,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                userName: userName.isEmpty ? "你" : userName,
                assistantName: assistantName.trimmingCharacters(in: .whitespaces),
                systemPrompt: systemPrompt,
                preferredModel: preferredModel,
                characterDescription: characterDescription,
                characterPersonality: characterPersonality,
                scenario: scenario,
                chatExamples: chatExamples,
                postInstructions: postInstructions,
                characterCardID: importedCard?.name,
                coverImageData: importedCard?.imageData
            )
            profileManager.addProfile(profile)

            // 角色卡导入：创建对话 + 世界书
            if let card = importedCard {
                importCardContent(card: card, profile: &profile)
            }

            if importAfterSave { onRequestImport?(profile) }

        case .edit(let existing):
            var updated = existing
            updated.name = trimmedName
            updated.emoji = finalEmoji
            updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.userName = userName.isEmpty ? "你" : userName
            updated.assistantName = assistantName.trimmingCharacters(in: .whitespaces)
            updated.systemPrompt = systemPrompt
            updated.preferredModel = preferredModel
            profileManager.updateProfile(updated)

            if importAfterSave { onRequestImport?(updated) }
        }

        dismiss()
    }

    // MARK: - 角色卡导入（创建对话 + 世界书）

    private func importCardContent(card: TavernCard, profile: inout Profile) {
        let context = ModelContext(profileManager.container)

        // C4: 创建对话 — first_mes + alternate_greetings
        var greetings: [(title: String, content: String)] = []

        if !card.firstMes.isEmpty {
            greetings.append((title: card.name, content: card.firstMes))
        }
        for (i, greeting) in card.alternateGreetings.enumerated() {
            guard !greeting.isEmpty else { continue }
            greetings.append((title: "\(card.name) #\(i + 2)", content: greeting))
        }

        for greeting in greetings {
            let convId = UUID().uuidString
            let nodeId = UUID().uuidString
            let now = Date()

            let conversation = Conversation(
                id: convId,
                title: greeting.title,
                createTime: now,
                updateTime: now,
                currentNodeId: nodeId,
                provider: "sillytavern"
            )
            conversation.nodeCount = 1

            let node = MessageNode(
                id: nodeId,
                role: "assistant",
                content: Self.normalizeNewlines(greeting.content),
                contentType: "text",
                createTime: now,
                parentId: nil,
                childrenIds: [],
                conversationId: convId
            )

            context.insert(conversation)
            context.insert(node)
        }

        // C5: 世界书随卡导入
        if card.hasWorldBook {
            let entries = card.characterBookEntries.enumerated().map { (i, dict) in
                WorldBookEntry(from: dict, index: i)
            }
            let bookName = card.characterBookName ?? "\(card.name)的世界书"
            let worldBook = WorldBook(name: bookName, profileId: profile.id, entries: entries)
            context.insert(worldBook)

            profile.linkedWorldBookIDs = [worldBook.id.uuidString]
            profileManager.updateProfile(profile)
        }

        // 正则脚本
        if card.hasRegexScripts {
            let scripts = card.regexScripts.map { RegexScript(from: $0) }
            profile.regexScripts = scripts
            profileManager.updateProfile(profile)
        }

        try? context.save()
    }

    /// 角色卡文本换行规范化：\r\n → \n，单个 \n → \n\n（Markdown 段落）
    private static func normalizeNewlines(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // 单个 \n 转为 \n\n（已经是 \n\n 的不动）
        // 思路：先把连续 2+ 个 \n 临时替换，再把剩余单个 \n 变 \n\n，再还原
        s = s.replacingOccurrences(of: "\n\n", with: "\u{0000}PARA\u{0000}")
        s = s.replacingOccurrences(of: "\n", with: "\n\n")
        s = s.replacingOccurrences(of: "\u{0000}PARA\u{0000}", with: "\n\n")
        return s
    }
}

// Build trigger: Day 10 mega update 20260605T011539
