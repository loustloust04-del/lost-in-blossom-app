import SwiftUI
import SwiftData
import UIKit

// MARK: - API Settings Tab

struct APISettingsTab: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    // Core editing state
    @State private var apiKeys: [String: String] = [:]
    @State private var savedProvider: String? = nil
    @State private var connectionTestResults: [String: Result<String, Error>] = [:]
    @State private var testingProvider: String? = nil

    // Selection + models
    @AppStorage("apiSelectedProvider") private var apiSelectedProviderId = "openrouter"
    @AppStorage("selectedChatModel") private var selectedChatModelId = ""
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""  // 🌛 副模型（记忆提取）
    @AppStorage("apiKeyCloudSync") private var apiKeyCloudSync = false

    @State private var apiFetchedModels: [ProviderModel] = []
    @State private var apiIsFetchingModels = false
    @State private var apiFetchError: String? = nil
    @State private var apiModelSearch = ""

    // Custom provider fields
    @State private var customName = ""
    @State private var customBaseURL = ""
    @State private var customSavedId: String? = nil
    @State private var customManualModelId = ""

    @State private var cloudSyncMessage: String? = nil

    // MARK: - Constants

    static let customOpenAIId = "__custom_openai__"
    static let customAnthropicId = "__custom_anthropic__"

    // MARK: - Computed

    /// True when the picker is on a "new custom" slot (not yet saved).
    private var isCustomSelection: Bool {
        apiSelectedProviderId == Self.customOpenAIId || apiSelectedProviderId == Self.customAnthropicId
    }

    private var selectedProvider: APIProvider? {
        providerManager?.providers.first(where: { $0.id == apiSelectedProviderId })
    }

    /// True when the picker is on a previously saved custom provider.
    private var isEditableSavedCustom: Bool {
        guard let p = selectedProvider else { return false }
        return !p.isBuiltIn
    }

    /// Show custom fields (name / baseURL / manual model id) for both new and saved custom.
    private var showsCustomFields: Bool {
        isCustomSelection || isEditableSavedCustom
    }

    /// The real provider id used for Keychain and network calls.
    /// - New custom: returns either the temporary `__custom_*__` tag or the saved id after save.
    /// - Saved custom / built-in: the provider id itself.
    private var effectiveProviderId: String {
        if isCustomSelection, let saved = customSavedId {
            return saved
        }
        return apiSelectedProviderId
    }

    private var inputCornerRadius: CGFloat {
        8
    }

    // MARK: - Body (platform dispatch)

    var body: some View {
        iOSBody
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: Theme.SettingsFont.label, weight: .medium))
            .foregroundColor(Theme.textSecondary)
    }

    // MARK: - iOS Body

    var iOSBody: some View {
        List {
            if providerManager != nil {
                Section("提供商") {
                    providerPickerContent
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("联网搜索") {
                    WebSearchQuickSettings()

                    // web-access-v2 phase3（搬运自粟粟家）：登录态共享 + 黑名单
                    NavigationLink {
                        WebLoginStatusPage()
                    } label: {
                        HStack {
                            Text("网页登录态")
                                .font(.system(size: Theme.SettingsFont.body))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text("AI 能用你登录的站")
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                    }

                    NavigationLink {
                        BlockedDomainsPage()
                    } label: {
                        HStack {
                            Text("黑名单（AI 不读）")
                                .font(.system(size: Theme.SettingsFont.body))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(WebSearchSettings.shared.blockedDomains.isEmpty
                                 ? "未设置"
                                 : "\(WebSearchSettings.shared.blockedDomains.count) 个域")
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                if let pm = providerManager, !pm.savedAPIProviders.isEmpty {
                    Section("当前使用的 API") {
                        activeAPIPickerContent
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)

                    Section("已保存的 API") {
                        savedAPIListContent
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }

                if showsCustomFields {
                    Section("自定义配置") {
                        customFieldsContent
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }

                Section(selectedProvider?.type == .ccBridge ? "连接状态" : "API Key") {
                    apiKeyContent
                    if selectedProvider?.type != .ccBridge {
                        connectionStatusRow
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("模型") {
                    modelListContent
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("预算（保险闸）") {
                    budgetContent
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("同步") {
                    cloudSyncContent
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("API")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadAPIKeys()
            prefillCustomFieldsIfNeeded()
        }
        .onChange(of: apiSelectedProviderId) { _, _ in
            handleProviderChanged()
        }
        .onChange(of: apiKeyCloudSync) { _, newValue in
            handleCloudSyncToggled(newValue)
        }
    }

    // MARK: - Section Content

    /// 从 selectedChatModelId 解析出当前在用的 provider id（"providerId/modelId"）。
    private var activeProviderId: String {
        selectedChatModelId.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// "当前使用的 API" picker —— 选中 = 正在用的 API；切换等价于"使用"这张 API
    @ViewBuilder
    private var activeAPIPickerContent: some View {
        if let pm = providerManager {
            let binding = Binding<String>(
                get: { activeProviderId },
                set: { newId in
                    if newId != activeProviderId {
                        if newId.isEmpty {
                            // 选了"（默认）" → 清除 selectedChatModel，聊天页回退到 CC + 收藏模型
                            selectedChatModelId = ""
                            apiSelectedProviderId = ""
                        } else {
                            handleUseProvider(newId)
                        }
                    }
                }
            )

            Picker("", selection: binding) {
                // 默认/空选项 — 始终可选；选了它聊天页显示 CC 本地模型 + 收藏模型
                Text("（默认）").tag("")

                ForEach(pm.savedAPIProviders, id: \.id) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            .tint(Theme.branchIndicator)
        }
    }

    @ViewBuilder
    private var savedAPIListContent: some View {
        if let pm = providerManager {
            VStack(spacing: Theme.optionRowSpacing) {
                ForEach(pm.savedAPIProviders, id: \.id) { p in
                    savedAPIRow(for: p, pm: pm)
                }
            }
        }
    }

    private func savedAPIRow(for p: APIProvider, pm: ProviderManager) -> SavedAPIRow {
        SavedAPIRow(
            provider: p,
            hasKey: pm.hasKey(for: p.id),
            isActive: p.id == activeProviderId,
            onUse: { handleUseProvider(p.id) },
            onRename: p.isBuiltIn ? nil : { newName in
                pm.renameCustomProvider(id: p.id, newName: newName)
            },
            onDelete: p.isBuiltIn ? nil : {
                pm.removeProvider(id: p.id)
                pm.resolveStaleSelectedModel()
                if apiSelectedProviderId == p.id {
                    apiSelectedProviderId = "openrouter"
                }
            }
        )
    }

    private func handleUseProvider(_ providerId: String) {
        guard let pm = providerManager else { return }
        if let combined = pm.useProvider(id: providerId) {
            selectedChatModelId = combined
            apiSelectedProviderId = providerId
        } else {
            cloudSyncMessage = "该 API 暂无可用模型，请先在此拉取"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                cloudSyncMessage = nil
            }
        }
    }

    @ViewBuilder
    private var providerPickerContent: some View {
        if let pm = providerManager {
            Picker("", selection: $apiSelectedProviderId) {
                ForEach(pm.providers.filter(\.isBuiltIn), id: \.id) { provider in
                    Text(provider.name).tag(provider.id)
                }
                Text("── 自定义 ──").tag("__separator__").disabled(true)
                Text("自定义 (OpenAI 兼容)").tag(Self.customOpenAIId)
                Text("自定义 (Anthropic)").tag(Self.customAnthropicId)

                let customProviders = pm.providers.filter { !$0.isBuiltIn }
                if !customProviders.isEmpty {
                    ForEach(customProviders, id: \.id) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
            }
            .labelsHidden()
            .tint(Theme.branchIndicator)
        }
    }

    @ViewBuilder
    private var customFieldsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("名称")
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                TextField("如：我的中转站", text: $customName)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.SettingsFont.body))
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.optionRowVerticalPadding)
                    .background(RoundedRectangle(cornerRadius: inputCornerRadius).fill(Theme.mainBg))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                TextField("https://api.example.com/v1", text: $customBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.optionRowVerticalPadding)
                    .background(RoundedRectangle(cornerRadius: inputCornerRadius).fill(Theme.mainBg))
                    .autocapitalization(.none)
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("手动添加模型 ID")
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                HStack(spacing: 8) {
                    TextField("如 gpt-4o, claude-sonnet-4", text: $customManualModelId)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.optionRowVerticalPadding)
                        .background(RoundedRectangle(cornerRadius: inputCornerRadius).fill(Theme.mainBg))
                        .autocapitalization(.none)
                    Button("添加") {
                        addManualModel()
                    }
                    .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
                    .buttonStyle(.plain)
                    .disabled(customManualModelId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var apiKeyContent: some View {
        if let provider = selectedProvider, provider.type == .ccBridge {
            ccBridgeStatusContent(provider: provider)
        } else {
            let pid = effectiveProviderId
            HStack(spacing: 8) {
                SecureField("API Key", text: Binding(
                    get: { apiKeys[pid] ?? "" },
                    set: { apiKeys[pid] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, Theme.optionRowVerticalPadding)
                .background(RoundedRectangle(cornerRadius: inputCornerRadius).fill(Theme.mainBg))

                Button(action: {
                    saveKeyAction()
                }) {
                    Text(savedProvider == pid ? "OK" : "保存")
                        .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(savedProvider == pid ? Theme.textMuted : Theme.branchIndicator))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - CC Bridge UI state

    @State private var ccBridgeURLDraft = ""
    @State private var ccBridgeURLSaved = false
    @State private var ccBridgeURLBackupDraft = ""
    @State private var ccBridgeURLBackupSaved = false

    /// CC Bridge 专用状态面板（替换 API Key 输入框）。
    @ViewBuilder
    private func ccBridgeStatusContent(provider: APIProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hub URL（主）
            VStack(alignment: .leading, spacing: 4) {
                Text("Hub URL")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("ws://192.168.1.5:7890/ws", text: $ccBridgeURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button(ccBridgeURLSaved ? "已保存" : "保存") {
                        providerManager?.setCCBridgeBaseURL(ccBridgeURLDraft)
                        reconnectCCBridge()
                        ccBridgeURLSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ccBridgeURLSaved = false }
                    }
                    .buttonStyle(.bordered)
                    .disabled(ccBridgeURLDraft.isEmpty)
                }
            }
            .padding(.bottom, 6)

            // Hub URL（备用）
            VStack(alignment: .leading, spacing: 4) {
                Text("Hub URL (备用)")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("ws://xxx.ts.net:7890/ws（选填）", text: $ccBridgeURLBackupDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button(ccBridgeURLBackupSaved ? "已保存" : "保存") {
                        providerManager?.setCCBridgeBaseURLBackup(ccBridgeURLBackupDraft)
                        reconnectCCBridge()
                        ccBridgeURLBackupSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ccBridgeURLBackupSaved = false }
                    }
                    .buttonStyle(.bordered)
                }
                Text("主 URL 连不上时自动 fallback 到备用 URL。典型用法：主填 LAN IP（家里快），备填 Tailscale 域名（出门用）。两个都用同一个 Hub Token。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)

            // Hub Token
            VStack(alignment: .leading, spacing: 4) {
                Text("Hub Token")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SecureField("LAN 模式必填，loopback 留空", text: Binding(
                        get: { apiKeys["cc-bridge"] ?? "" },
                        set: { apiKeys["cc-bridge"] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    Button("保存") {
                        providerManager?.setApiKey(apiKeys["cc-bridge"] ?? "", for: "cc-bridge")
                        reconnectCCBridge()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.bottom, 6)

            // 连接状态行
            HStack(spacing: 8) {
                Circle()
                    .fill(CCBridgeWebSocketClient.shared.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(CCBridgeWebSocketClient.shared.isConnected ? "已连接" : "未连接")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundStyle(.secondary)
                if let err = CCBridgeWebSocketClient.shared.lastError,
                   !CCBridgeWebSocketClient.shared.isConnected {
                    Text(err)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundStyle(.red.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
            }

            Text("CC Bridge 用本地 WebSocket 连接，不需要 API Key。需要先在终端跑 `bash cc-bridge/start_hub.sh` 和 `bash cc-bridge/start_cc.sh`。")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("重新连接") {
                reconnectCCBridge()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .onAppear {
            ccBridgeURLDraft = providerManager?.ccBridgeBaseURL ?? APIProvider.ccBridge.baseURL
            ccBridgeURLBackupDraft = providerManager?.ccBridgeBaseURLBackup ?? ""
            apiKeys["cc-bridge"] = providerManager?.apiKey(for: "cc-bridge") ?? ""
        }
    }

    private func reconnectCCBridge() {
        CCBridgeWebSocketClient.shared.disconnect()
        let primary = providerManager?.ccBridgeBaseURL ?? APIProvider.ccBridge.baseURL
        let backup  = providerManager?.ccBridgeBaseURLBackup ?? ""
        let urls: [URL] = [primary, backup].filter { !$0.isEmpty }.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        let t = providerManager?.apiKey(for: "cc-bridge")
        CCBridgeWebSocketClient.shared.connect(urls: urls, token: (t?.isEmpty == false) ? t : nil)
    }

    @ViewBuilder
    private var connectionStatusRow: some View {
        let pid = effectiveProviderId
        HStack(spacing: 10) {
            if let result = connectionTestResults[pid] {
                switch result {
                case .success(let msg):
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(.green)
                        Text(msg)
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(.green)
                    }
                case .failure(let err):
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(.red)
                        Text(err.localizedDescription)
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }
            }

            Spacer()

            Button(action: { testProvider(pid) }) {
                HStack(spacing: 4) {
                    if testingProvider == pid {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: Theme.SettingsFont.secondary))
                    }
                    Text("测试连接")
                        .font(.system(size: Theme.SettingsFont.secondary))
                }
                .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
            .disabled(testingProvider != nil)

            if isEditableSavedCustom, let prov = selectedProvider {
                Button(action: {
                    providerManager?.removeProvider(id: prov.id)
                    providerManager?.resolveStaleSelectedModel()
                    apiSelectedProviderId = "openrouter"
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: Theme.SettingsFont.secondary))
                        Text("删除")
                            .font(.system(size: Theme.SettingsFont.secondary))
                    }
                    .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var modelListContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模型")
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                if apiIsFetchingModels {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("拉取中...")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    Button(action: { apiAutoFetchModels() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: Theme.SettingsFont.secondary))
                            Text("刷新模型")
                                .font(.system(size: Theme.SettingsFont.secondary))
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(.plain)
                    .disabled(providerManager?.hasKey(for: effectiveProviderId) != true)
                }
            }

            if let error = apiFetchError {
                Text(error)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
            }

            Text("🌞 主对话模型 · 🌛 副模型（记忆提取等后台任务）· ☆ 收藏")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            modelSearchAndList
        }
    }

    @ViewBuilder
    private var budgetContent: some View {
        // 粟粟决策（2026-04-23）：全局保险闸，无关 provider。
        BudgetSection()
    }

    @ViewBuilder
    private var cloudSyncContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $apiKeyCloudSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Keychain 同步")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("开启后 API Key 在你登录同一 Apple ID 的设备间同步。对话数据不会同步。")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.branchIndicator)

            if let msg = cloudSyncMessage {
                Text(msg)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(msg.contains("失败") ? .red : Theme.textMuted)
            }
        }
    }

    // MARK: - Model Search + List (inside modelListContent)

    private var filteredModels: [ProviderModel] {
        let pid = effectiveProviderId
        let allModels = apiFetchedModels.isEmpty
            ? (providerManager?.providers.first(where: { $0.id == pid })?.models ?? [])
            : apiFetchedModels
        if apiModelSearch.isEmpty { return allModels }
        let query = apiModelSearch.lowercased()
        return allModels.filter {
            $0.modelId.lowercased().contains(query) || $0.name.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var modelSearchAndList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textMuted)
                TextField("搜索模型...", text: $apiModelSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.SettingsFont.body))
                if !apiModelSearch.isEmpty {
                    Button(action: { apiModelSearch = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: inputCornerRadius).fill(Theme.mainBg))

            let models = filteredModels
            if models.isEmpty && !apiIsFetchingModels {
                Text(providerManager?.hasKey(for: effectiveProviderId) == true
                     ? "暂无模型，点击「刷新模型」拉取"
                     : "请先输入 API Key")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 8)
            } else {
                let grouped = groupModelsByVendor(models)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if grouped.count == 1, let (vendor, vendorModels) = grouped.first {
                            if vendor == "_flat" || vendorModels.count == models.count {
                                ForEach(vendorModels, id: \.id) { model in
                                    apiModelRow(model)
                                }
                            } else {
                                apiModelGroup(vendor: vendor, models: vendorModels)
                            }
                        } else {
                            ForEach(Array(grouped.keys.sorted()), id: \.self) { vendor in
                                if let vendorModels = grouped[vendor] {
                                    apiModelGroup(vendor: vendor, models: vendorModels)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .background(RoundedRectangle(cornerRadius: inputCornerRadius).fill(Theme.mainBg.opacity(0.5)))
            }
        }
    }

    private func apiModelGroup(vendor: String, models: [ProviderModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vendor)
                .font(.system(size: Theme.SettingsFont.badge, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(models, id: \.id) { model in
                apiModelRow(model)
            }
        }
    }

    @ViewBuilder
    private func apiModelRow(_ model: ProviderModel) -> some View {
        let isFav = providerManager?.isFavoriteModel(id: model.id) ?? false
        let isSelected = selectedChatModelId == model.id           // 🌞 主对话
        let isMemoryPick = memoryExtractModelId == model.id        // 🌛 副记忆

        HStack(spacing: 6) {
            Button(action: {
                selectedChatModelId = model.id
            }) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textPrimary)
                    Spacer(minLength: 4)
                    if model.modelId != model.name {
                        Text(model.modelId)
                            .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 🌞 主对话（tap 行本身也能切；此按钮给"明确点主"的 affordance，并显示当前状态）
            Button(action: {
                selectedChatModelId = model.id
            }) {
                Text("🌞")
                    .font(.system(size: Theme.SettingsFont.body))
                    .opacity(isSelected ? 1.0 : 0.22)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("主对话模型")

            // 🌛 副模型（记忆提取）— toggle：已选再点清空走自动 fallback
            Button(action: {
                memoryExtractModelId = (isMemoryPick ? "" : model.id)
            }) {
                Text("🌛")
                    .font(.system(size: Theme.SettingsFont.body))
                    .opacity(isMemoryPick ? 1.0 : 0.22)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("副模型（记忆提取）")

            Button(action: {
                providerManager?.toggleFavoriteModel(id: model.id)
            }) {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(isFav ? Theme.favorite : Theme.textMuted.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Theme.branchIndicator.opacity(0.08) : Color.clear)
    }

    private func groupModelsByVendor(_ models: [ProviderModel]) -> [String: [ProviderModel]] {
        var groups: [String: [ProviderModel]] = [:]
        for model in models {
            let parts = model.modelId.split(separator: "/", maxSplits: 1)
            let vendor = parts.count > 1 ? String(parts[0]) : "_flat"
            groups[vendor, default: []].append(model)
        }
        return groups
    }

    // MARK: - Actions

    private func loadAPIKeys() {
        guard let pm = providerManager else { return }
        for provider in pm.providers {
            apiKeys[provider.id] = pm.apiKey(for: provider.id) ?? ""
        }
        // Migrate old openrouter key
        if let oldKey = UserDefaults.standard.string(forKey: "openrouter-api-key"), !oldKey.isEmpty, (apiKeys["openrouter"] ?? "").isEmpty {
            pm.setApiKey(oldKey, for: "openrouter")
            apiKeys["openrouter"] = oldKey
            UserDefaults.standard.removeObject(forKey: "openrouter-api-key")
        }
    }

    private func prefillCustomFieldsIfNeeded() {
        guard isEditableSavedCustom, let p = selectedProvider else { return }
        customName = p.name
        customBaseURL = p.baseURL
        customSavedId = p.id
    }

    private func handleProviderChanged() {
        apiFetchedModels = []
        apiFetchError = nil
        apiModelSearch = ""
        connectionTestResults.removeAll()
        customManualModelId = ""

        if isEditableSavedCustom, let p = selectedProvider {
            customName = p.name
            customBaseURL = p.baseURL
            customSavedId = p.id
        } else if isCustomSelection {
            // 新建 custom：预填时间戳作为默认别称
            customName = TimestampFormatter.minuteStamp()
            customBaseURL = ""
            customSavedId = nil
        } else {
            customName = ""
            customBaseURL = ""
            customSavedId = nil
        }

        // Auto-fetch if key exists
        let pid = effectiveProviderId
        if providerManager?.hasKey(for: pid) == true {
            apiAutoFetchModels()
        }
    }

    private func saveKeyAction() {
        if isCustomSelection || isEditableSavedCustom {
            saveCustomProvider()
        } else {
            saveProviderKey(apiSelectedProviderId)
        }
        apiAutoFetchModels()
    }

    private func saveProviderKey(_ providerId: String) {
        guard let pm = providerManager else { return }
        let key = (apiKeys[providerId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pm.setApiKey(key, for: providerId)
        savedProvider = providerId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if savedProvider == providerId { savedProvider = nil }
        }
    }

    private func saveCustomProvider() {
        guard let pm = providerManager else { return }
        let name = customName.trimmingCharacters(in: .whitespaces)
        let url = customBaseURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        let providerId: String
        let type: ProviderType
        let extraHeaders: [String: String]
        let existingModels: [ProviderModel]
        let createdAt: Date
        let lastUsedModelId: String?
        let lastUsedAt: Date?

        if isEditableSavedCustom, let existing = selectedProvider {
            providerId = existing.id
            type = existing.type
            extraHeaders = existing.extraHeaders
            existingModels = existing.models
            createdAt = existing.createdAt
            lastUsedModelId = existing.lastUsedModelId
            lastUsedAt = existing.lastUsedAt
        } else {
            providerId = customSavedId ?? "custom-\(UUID().uuidString.prefix(8).lowercased())"
            type = apiSelectedProviderId == Self.customAnthropicId ? .anthropic : .openaiCompatible
            extraHeaders = type == .anthropic ? ["anthropic-version": "2023-06-01"] : [:]
            existingModels = []
            createdAt = Date()
            lastUsedModelId = nil
            lastUsedAt = nil
        }

        let fallbackName = TimestampFormatter.minuteStamp()
        let provider = APIProvider(
            id: providerId,
            name: name.isEmpty ? fallbackName : name,
            type: type,
            baseURL: url,
            extraHeaders: extraHeaders,
            models: existingModels,
            isBuiltIn: false,
            createdAt: createdAt,
            lastUsedModelId: lastUsedModelId,
            lastUsedAt: lastUsedAt
        )

        pm.addProvider(provider)

        let key = (apiKeys[effectiveProviderId] ?? "").trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            pm.setApiKey(key, for: providerId)
            // Also rebind apiKeys dict for the new id so UI continues to show it
            apiKeys[providerId] = key
        }

        customSavedId = providerId
        savedProvider = providerId

        // If we just created a new custom, jump selection to the saved id
        if apiSelectedProviderId != providerId {
            apiSelectedProviderId = providerId
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if savedProvider == providerId { savedProvider = nil }
        }
    }

    private func addManualModel() {
        guard let pm = providerManager else { return }
        let mid = customManualModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return }
        let pid = effectiveProviderId
        // If we're on a "new custom" slot that hasn't been saved, refuse — user should save first
        guard !(isCustomSelection && customSavedId == nil) else { return }
        let model = ProviderModel(providerId: pid, modelId: mid, name: mid)
        pm.addModel(to: pid, model: model)
        customManualModelId = ""
        apiFetchedModels = pm.providers.first(where: { $0.id == pid })?.models ?? []
    }

    private func apiAutoFetchModels() {
        let providerId = effectiveProviderId
        guard let pm = providerManager, pm.hasKey(for: providerId) else { return }
        apiIsFetchingModels = true
        apiFetchError = nil
        Task {
            let result = await pm.fetchModels(providerId: providerId)
            await MainActor.run {
                apiIsFetchingModels = false
                switch result {
                case .success(let models):
                    apiFetchedModels = models
                    Task { _ = await pm.fetchAndMergeModels(providerId: providerId) }
                case .failure(let error):
                    apiFetchError = error.localizedDescription
                    apiFetchedModels = pm.providers.first(where: { $0.id == providerId })?.models ?? []
                }
            }
        }
    }

    private func testProvider(_ providerId: String) {
        guard let pm = providerManager else { return }
        testingProvider = providerId
        connectionTestResults.removeValue(forKey: providerId)
        Task {
            let result = await pm.testConnection(providerId: providerId)
            await MainActor.run {
                connectionTestResults[providerId] = result
                testingProvider = nil
            }
        }
    }

    private func handleCloudSyncToggled(_ enabled: Bool) {
        guard let pm = providerManager else { return }
        cloudSyncMessage = enabled ? "正在同步到 iCloud Keychain..." : "正在切回本机 Keychain..."
        let failures = pm.reencryptAllKeys(sync: enabled)
        if failures.isEmpty {
            cloudSyncMessage = enabled ? "已同步到 iCloud Keychain" : "已切回本机 Keychain"
        } else {
            cloudSyncMessage = "切换失败 \(failures.count) 个，请重试或重新输入 key"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            cloudSyncMessage = nil
        }
    }
}

// MARK: - SavedAPICard

private struct SavedAPIRow: View {
    let provider: APIProvider
    let hasKey: Bool
    let isActive: Bool
    let onUse: () -> Void
    /// nil = 不允许改名（内置 provider）
    let onRename: ((String) -> Void)?
    /// nil = 不允许删除（内置 provider）
    let onDelete: (() -> Void)?

    @State private var isEditing = false
    @State private var editingName = ""
    @FocusState private var nameFocused: Bool

    private var useDisabled: Bool {
        !hasKey || provider.models.isEmpty
    }

    private var cleanedURL: String {
        provider.baseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var subtitle: String {
        if let last = provider.lastUsedAt {
            return "\(cleanedURL) · \(TimestampFormatter.relativeDescription(last))"
        }
        return cleanedURL
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: Theme.SettingsFont.body))
                .foregroundColor(isActive ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))

            if isEditing, onRename != nil {
                TextField("别称", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .autocapitalization(.none)
            } else {
                Text(provider.name)
                    .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
            }

            Text(subtitle)
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if onRename != nil {
                Button(action: {
                    if isEditing { commitRename() } else { startRename() }
                }) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.optionRowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Theme.accent.opacity(0.4) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing && !isActive && !useDisabled {
                onUse()
            }
        }
        .contextMenu {
            Button("使用", action: onUse).disabled(useDisabled || isActive)
            if onRename != nil {
                Button("重命名", action: startRename)
            }
            if let onDelete {
                Button("删除", role: .destructive, action: onDelete)
            }
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused && isEditing {
                commitRename()
            }
        }
    }

    private func startRename() {
        guard onRename != nil else { return }
        editingName = provider.name
        isEditing = true
        nameFocused = true
    }

    private func commitRename() {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != provider.name, let onRename {
            onRename(trimmed)
        }
        isEditing = false
    }
}

// MARK: - BudgetSection (全局保险闸 — 粟粟决策 2026-04-23)
// 水库总闸门：所有 API 调用（无论 provider 无论主/副模型）汇总到 GlobalBudgetStore。
// 视觉位置保持原位（API 页下滑到"预算（保险闸）"那块），数据源改成全局。

private struct BudgetSection: View {
    private let store = GlobalBudgetStore.shared
    @State private var budgetText: String
    @State private var showResetConfirm = false
    @State private var justSaved = false

    init() {
        _budgetText = State(initialValue: String(format: "%.2f", GlobalBudgetStore.shared.budgetUSD))
    }

    private var hasUnsavedChanges: Bool {
        budgetText != String(format: "%.2f", store.budgetUSD)
    }

    private var percent: Double {
        guard store.budgetUSD > 0 else { return 0 }
        return min(store.spentUSD / store.budgetUSD, 1.0)
    }

    private var progressTint: Color {
        if percent >= 1.0 { return .red }
        if percent >= 0.8 { return Color(red: 0.9, green: 0.7, blue: 0.35) }
        return Theme.branchIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { store.enabled },
                set: { store.setEnabled($0) }
            )) {
                Text("启用预算限额")
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.branchIndicator)

            HStack {
                Text("预算（USD）")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                TextField("0.00", text: $budgetText)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.SettingsFont.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    .keyboardType(.decimalPad)
            }

            HStack {
                Text("已使用")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(String(format: "$ %.4f", store.spentUSD))
                    .font(.system(size: Theme.SettingsFont.body, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }

            ProgressView(value: percent)
                .tint(progressTint)

            HStack {
                Text(String(format: "%.0f%%", percent * 100))
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button(action: { showResetConfirm = true }) {
                    Text("重置已用")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }

            Text("所有 API 调用汇总在这里（主对话、记忆提取、上下文总结…）。保险闸，不是精细账本。")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: commitBudget) {
                    Text(justSaved ? "已保存" : "保存")
                        .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(
                            justSaved ? Theme.textMuted
                                : (hasUnsavedChanges ? Theme.branchIndicator : Theme.textMuted.opacity(0.4))
                        ))
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges || justSaved)
            }
        }
        .opacity(store.enabled ? 1.0 : 0.55)
        .confirmationDialog(
            "清空已用花费？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) {
                store.resetSpent()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(String(format: "当前已用 $%.4f，预算上限保留。", store.spentUSD))
        }
    }

    private func commitBudget() {
        if let v = Double(budgetText.trimmingCharacters(in: .whitespaces)) {
            store.setBudgetUSD(v)
            budgetText = String(format: "%.2f", max(0, v))
        }
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justSaved = false
        }
    }
}
