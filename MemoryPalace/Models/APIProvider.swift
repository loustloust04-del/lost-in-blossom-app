import Foundation

// MARK: - MCP Server Config

/// Anthropic mcp_servers beta 使用的 MCP 服务器配置.
/// 虽然挂在 APIProvider 上，但通过独立的 UserDefaults 键存储（built-in / custom 共用同一路径）.
struct MCPServerConfig: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String        // 服务器标识符，用作 tool 名称的命名空间前缀（如 "imprint-memory"）
    var url: String         // MCP SSE endpoint URL
    var authorizationToken: String = ""   // Bearer token（可选，vps-mcp 等需要认证的服务器）
    var isEnabled: Bool = true
}

// MARK: - Provider Type

enum ProviderType: String, Codable {
    case openaiCompatible  // OpenAI / OpenRouter / DeepSeek / Groq / xAI / 任意中转站
    case anthropic         // Claude native Messages API
    case ccBridge          // 本地 Claude Code 通过 hub 桥接（WebSocket）
}

// MARK: - Provider Model

struct ProviderModel: Identifiable, Hashable, Codable {
    var id: String { "\(providerId)/\(modelId)" }
    let providerId: String
    let modelId: String
    let name: String       // Friendly display name

    enum CodingKeys: String, CodingKey {
        case providerId, modelId, name
    }
}

// MARK: - API Provider

struct APIProvider: Identifiable, Codable {
    let id: String
    var name: String
    var type: ProviderType
    var baseURL: String
    var extraHeaders: [String: String]
    var models: [ProviderModel]
    var isBuiltIn: Bool
    var createdAt: Date
    var lastUsedModelId: String?
    var lastUsedAt: Date?

    /// 与该 provider 关联的 MCP 服务器列表.
    /// 不包含在 CodingKeys 中 — 由 ProviderManager.reload() 从独立存储中合并.
    var mcpServers: [MCPServerConfig] = []

    // MARK: - Budget (保险闸)
    var budgetEnabled: Bool
    var budgetUSD: Double
    var spentUSD: Double
    var modelRatio: Double
    var completionRatio: Double
    var groupRatio: Double
    var currencyRate: Double

    init(
        id: String,
        name: String,
        type: ProviderType,
        baseURL: String,
        extraHeaders: [String: String] = [:],
        models: [ProviderModel] = [],
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        lastUsedModelId: String? = nil,
        lastUsedAt: Date? = nil,
        budgetEnabled: Bool = true,
        budgetUSD: Double = 0,
        spentUSD: Double = 0,
        modelRatio: Double = 1.0,
        completionRatio: Double = 1.0,
        groupRatio: Double = 1.0,
        currencyRate: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
        self.models = models
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.lastUsedModelId = lastUsedModelId
        self.lastUsedAt = lastUsedAt
        self.budgetEnabled = budgetEnabled
        self.budgetUSD = budgetUSD
        self.spentUSD = spentUSD
        self.modelRatio = modelRatio
        self.completionRatio = completionRatio
        self.groupRatio = groupRatio
        self.currencyRate = currencyRate
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, baseURL, extraHeaders, models, isBuiltIn
        case createdAt, lastUsedModelId, lastUsedAt
        case budgetEnabled, budgetUSD, spentUSD
        case modelRatio, completionRatio, groupRatio, currencyRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(ProviderType.self, forKey: .type)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.extraHeaders = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        self.models = try c.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        self.isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastUsedModelId = try c.decodeIfPresent(String.self, forKey: .lastUsedModelId)
        self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.budgetEnabled = try c.decodeIfPresent(Bool.self, forKey: .budgetEnabled) ?? true
        self.budgetUSD = try c.decodeIfPresent(Double.self, forKey: .budgetUSD) ?? 0
        self.spentUSD = try c.decodeIfPresent(Double.self, forKey: .spentUSD) ?? 0
        self.modelRatio = try c.decodeIfPresent(Double.self, forKey: .modelRatio) ?? 1.0
        self.completionRatio = try c.decodeIfPresent(Double.self, forKey: .completionRatio) ?? 1.0
        self.groupRatio = try c.decodeIfPresent(Double.self, forKey: .groupRatio) ?? 1.0
        self.currencyRate = try c.decodeIfPresent(Double.self, forKey: .currencyRate) ?? 1.0
    }
}

// MARK: - Built-in Providers

extension APIProvider {
    static let builtIn: [APIProvider] = [
        .anthropic,
        .openai,
        .openrouter,
        .deepseek,
        .groq,
        .xai,
        .siliconflow,
        .dashscope,
        .zhipu,
        .doubao,
        .gemini,
        .moonshot,
        .ollama,
        .ccBridge,
    ]

    static let anthropic = APIProvider(
        id: "anthropic",
        name: "Anthropic",
        type: .anthropic,
        baseURL: "https://api.anthropic.com/v1",
        extraHeaders: ["anthropic-version": "2023-06-01"],
        models: [
            ProviderModel(providerId: "anthropic", modelId: "claude-opus-4-6", name: "Claude Opus 4.6"),
            ProviderModel(providerId: "anthropic", modelId: "claude-sonnet-4-5", name: "Claude Sonnet 4.5"),
            ProviderModel(providerId: "anthropic", modelId: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5 (0929)"),
            ProviderModel(providerId: "anthropic", modelId: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
            ProviderModel(providerId: "anthropic", modelId: "claude-sonnet-4-0", name: "Claude Sonnet 4"),
            ProviderModel(providerId: "anthropic", modelId: "claude-opus-4-0", name: "Claude Opus 4"),
            ProviderModel(providerId: "anthropic", modelId: "claude-3-7-sonnet-latest", name: "Claude 3.7 Sonnet"),
            ProviderModel(providerId: "anthropic", modelId: "claude-3-5-haiku-latest", name: "Claude 3.5 Haiku"),
        ],
        isBuiltIn: true
    )

    static let openai = APIProvider(
        id: "openai",
        name: "OpenAI",
        type: .openaiCompatible,
        baseURL: "https://api.openai.com/v1",
        extraHeaders: [:],
        models: [
            ProviderModel(providerId: "openai", modelId: "gpt-4o", name: "GPT-4o"),
            ProviderModel(providerId: "openai", modelId: "gpt-4o-mini", name: "GPT-4o Mini"),
            ProviderModel(providerId: "openai", modelId: "gpt-4.1", name: "GPT-4.1"),
            ProviderModel(providerId: "openai", modelId: "gpt-4.1-mini", name: "GPT-4.1 Mini"),
            ProviderModel(providerId: "openai", modelId: "gpt-4.1-nano", name: "GPT-4.1 Nano"),
            ProviderModel(providerId: "openai", modelId: "o3", name: "o3"),
            ProviderModel(providerId: "openai", modelId: "o3-mini", name: "o3 Mini"),
            ProviderModel(providerId: "openai", modelId: "o4-mini", name: "o4 Mini"),
        ],
        isBuiltIn: true
    )

    static let openrouter = APIProvider(
        id: "openrouter",
        name: "OpenRouter",
        type: .openaiCompatible,
        baseURL: "https://openrouter.ai/api/v1",
        extraHeaders: [
            "HTTP-Referer": "MemoryPalace/1.0",
            "X-Title": "MemoryPalace",
        ],
        models: [
            ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-haiku-4", name: "Claude Haiku 4"),
            ProviderModel(providerId: "openrouter", modelId: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5"),
            ProviderModel(providerId: "openrouter", modelId: "openai/gpt-4o", name: "GPT-4o"),
            ProviderModel(providerId: "openrouter", modelId: "openai/gpt-4o-mini", name: "GPT-4o Mini"),
            ProviderModel(providerId: "openrouter", modelId: "openai/gpt-4.1", name: "GPT-4.1"),
            ProviderModel(providerId: "openrouter", modelId: "google/gemini-2.5-pro-preview", name: "Gemini 2.5 Pro"),
            ProviderModel(providerId: "openrouter", modelId: "google/gemini-2.5-flash-preview", name: "Gemini 2.5 Flash"),
            ProviderModel(providerId: "openrouter", modelId: "deepseek/deepseek-chat", name: "DeepSeek V3"),
            ProviderModel(providerId: "openrouter", modelId: "deepseek/deepseek-reasoner", name: "DeepSeek R1"),
            ProviderModel(providerId: "openrouter", modelId: "x-ai/grok-3-mini", name: "Grok 3 Mini"),
        ],
        isBuiltIn: true
    )

    static let deepseek = APIProvider(
        id: "deepseek",
        name: "DeepSeek",
        type: .openaiCompatible,
        baseURL: "https://api.deepseek.com/v1",
        extraHeaders: [:],
        models: [
            ProviderModel(providerId: "deepseek", modelId: "deepseek-chat", name: "DeepSeek V3"),
            ProviderModel(providerId: "deepseek", modelId: "deepseek-reasoner", name: "DeepSeek R1"),
        ],
        isBuiltIn: true
    )

    static let groq = APIProvider(
        id: "groq",
        name: "Groq",
        type: .openaiCompatible,
        baseURL: "https://api.groq.com/openai/v1",
        extraHeaders: [:],
        models: [
            ProviderModel(providerId: "groq", modelId: "llama-3.3-70b-versatile", name: "Llama 3.3 70B"),
            ProviderModel(providerId: "groq", modelId: "llama-3.1-8b-instant", name: "Llama 3.1 8B"),
            ProviderModel(providerId: "groq", modelId: "gemma2-9b-it", name: "Gemma 2 9B"),
            ProviderModel(providerId: "groq", modelId: "mixtral-8x7b-32768", name: "Mixtral 8x7B"),
        ],
        isBuiltIn: true
    )

    static let xai = APIProvider(
        id: "xai",
        name: "xAI",
        type: .openaiCompatible,
        baseURL: "https://api.x.ai/v1",
        extraHeaders: [:],
        models: [
            ProviderModel(providerId: "xai", modelId: "grok-3", name: "Grok 3"),
            ProviderModel(providerId: "xai", modelId: "grok-3-mini", name: "Grok 3 Mini"),
        ],
        isBuiltIn: true
    )

    static let siliconflow = APIProvider(
        id: "siliconflow",
        name: "SiliconFlow",
        type: .openaiCompatible,
        baseURL: "https://api.siliconflow.cn/v1",
        extraHeaders: [:],
        models: [],  // 自动拉取
        isBuiltIn: true
    )

    static let dashscope = APIProvider(
        id: "dashscope",
        name: "通义千问 (DashScope)",
        type: .openaiCompatible,
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        extraHeaders: [:],
        models: [],
        isBuiltIn: true
    )

    static let zhipu = APIProvider(
        id: "zhipu",
        name: "智谱 (GLM)",
        type: .openaiCompatible,
        baseURL: "https://open.bigmodel.cn/api/paas/v4",
        extraHeaders: [:],
        models: [],
        isBuiltIn: true
    )

    static let doubao = APIProvider(
        id: "doubao",
        name: "豆包 (Volcengine)",
        type: .openaiCompatible,
        baseURL: "https://ark.cn-beijing.volces.com/api/v3",
        extraHeaders: [:],
        models: [],
        isBuiltIn: true
    )

    static let gemini = APIProvider(
        id: "gemini",
        name: "Google Gemini",
        type: .openaiCompatible,
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        extraHeaders: [:],
        models: [],
        isBuiltIn: true
    )

    static let moonshot = APIProvider(
        id: "moonshot",
        name: "Moonshot / Kimi",
        type: .openaiCompatible,
        baseURL: "https://api.moonshot.cn/v1",
        extraHeaders: [:],
        models: [],
        isBuiltIn: true
    )

    static let ollama = APIProvider(
        id: "ollama",
        name: "Ollama (本地)",
        type: .openaiCompatible,
        baseURL: "http://localhost:11434/v1",
        extraHeaders: [:],
        models: [],
        isBuiltIn: true
    )

    static let ccBridge = APIProvider(
        id: "cc-bridge",
        name: "Claude Code (本地)",
        type: .ccBridge,
        baseURL: "ws://127.0.0.1:7890/ws",
        extraHeaders: [:],
        models: [
            ProviderModel(providerId: "cc-bridge", modelId: "cc-local", name: "Claude Code"),
        ],
        isBuiltIn: true
    )
}

// MARK: - Provider Manager

private let customProvidersKey = "customProviders"
private let customModelsKey = "customModels" // per-provider extra models for built-in providers
private let mcpServersPerProviderKey = "mcpServersPerProvider" // per-provider MCP server list
private let cloudSyncKey = "apiKeyCloudSync"
private let favoriteModelsKey = "favoriteModels"
private let legacyApiKeyPrefix = "apikey-"

@Observable
final class ProviderManager {
    private(set) var providers: [APIProvider] = []
    private(set) var favoriteModelIds: [String] = []

    /// providerId → apiKey 内存缓存。启动时批量读一次 Keychain，之后所有查询走缓存，
    /// 避免每次 view 渲染都调 SecItemCopyMatching 触发反复弹窗（尤其 Debug build 每次
    /// rebuild 签名 hash 变 → macOS 认定是陌生 app → Always Allow 记录失效狂弹）。
    @ObservationIgnored
    private var apiKeyCache: [String: String] = [:]

    @ObservationIgnored
    private var apiKeyCacheLoaded = false

    init() {
        migrateLegacyKeysIfNeeded()
        reload()
        favoriteModelIds = loadFavoriteModelIds()
        warmUpApiKeyCache()
    }

    /// 一次性批量读 Keychain，填充 apiKeyCache。只触发一次 Keychain 授权弹窗。
    private func warmUpApiKeyCache() {
        apiKeyCache = KeychainStore.getAll()
        apiKeyCacheLoaded = true
    }

    /// Reload providers: built-in + custom, merge extra models and MCP servers
    func reload() {
        var result = APIProvider.builtIn

        // Merge user-added models into built-in providers
        let extraModels = loadExtraModels()
        for i in result.indices {
            if let extra = extraModels[result[i].id], !extra.isEmpty {
                result[i].models.append(contentsOf: extra)
            }
        }

        // Append custom providers
        result.append(contentsOf: loadCustomProviders())

        // Merge MCP servers (separate storage, applies to both built-in and custom)
        let mcpPerProvider = loadMCPServersPerProvider()
        for i in result.indices {
            if let list = mcpPerProvider[result[i].id] {
                result[i].mcpServers = list
            }
        }

        providers = result
    }

    // MARK: - API Key (Keychain-backed)

    var cloudSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: cloudSyncKey)
    }

    func apiKey(for providerId: String) -> String? {
        if !apiKeyCacheLoaded { warmUpApiKeyCache() }
        guard let key = apiKeyCache[providerId], !key.isEmpty else { return nil }
        return key
    }

    func setApiKey(_ key: String, for providerId: String) {
        if !apiKeyCacheLoaded { warmUpApiKeyCache() }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apiKeyCache.removeValue(forKey: providerId)
            KeychainStore.remove(account: providerId)
        } else {
            apiKeyCache[providerId] = trimmed
            _ = KeychainStore.set(trimmed, account: providerId, sync: cloudSyncEnabled)
        }
    }

    func hasKey(for providerId: String) -> Bool {
        if !apiKeyCacheLoaded { warmUpApiKeyCache() }
        guard let key = apiKeyCache[providerId] else { return false }
        return !key.isEmpty
    }

    /// 切换 iCloud 同步开关后把所有已有 key 按新状态重写一遍
    /// 返回失败的 account 列表（为空表示全部成功）
    @discardableResult
    func reencryptAllKeys(sync: Bool) -> [String] {
        UserDefaults.standard.set(sync, forKey: cloudSyncKey)
        var failures: [String] = []
        // 用批量读避免每个 account 单独调 get 触发多次弹窗
        let all = KeychainStore.getAll()
        for (account, value) in all {
            if !KeychainStore.set(value, account: account, sync: sync) {
                failures.append(account)
            } else {
                apiKeyCache[account] = value
            }
        }
        return failures
    }

    /// 一次性把 UserDefaults 里的 `apikey-*` 搬到 Keychain，搬完清掉明文
    private func migrateLegacyKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let dict = defaults.dictionaryRepresentation()
        let sync = defaults.bool(forKey: cloudSyncKey)
        for (key, value) in dict where key.hasPrefix(legacyApiKeyPrefix) {
            guard let stringValue = value as? String, !stringValue.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            let providerId = String(key.dropFirst(legacyApiKeyPrefix.count))
            guard !providerId.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            if KeychainStore.set(stringValue, account: providerId, sync: sync) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Queries

    var enabledProviders: [APIProvider] {
        providers.filter { provider in
            // ccBridge 走本地 WS 不需要 key
            if provider.type == .ccBridge { return true }
            return hasKey(for: provider.id)
        }
    }

    var availableModels: [ProviderModel] {
        enabledProviders.flatMap(\.models)
    }

    /// 所有 provider 的所有模型（不管有没有填 key），给群聊选择器用
    var allModels: [ProviderModel] {
        providers.flatMap(\.models)
    }

    func provider(for model: ProviderModel) -> APIProvider? {
        providers.first(where: { $0.id == model.providerId })
    }

    func model(byId combinedId: String) -> ProviderModel? {
        for provider in providers {
            if let model = provider.models.first(where: { $0.id == combinedId }) {
                return model
            }
        }
        return nil
    }

    /// If `selectedChatModel` points to a model that no longer exists, clear it.
    /// Call on launch and after provider mutations so the bottom picker shows unselected
    /// instead of silently falling back to an unrelated model.
    func resolveStaleSelectedModel() {
        let key = "selectedChatModel"
        guard let current = UserDefaults.standard.string(forKey: key), !current.isEmpty else { return }
        if model(byId: current) == nil {
            print("[ProviderManager] selectedChatModel '\(current)' no longer resolvable, clearing")
            UserDefaults.standard.set("", forKey: key)
        }
    }

    // MARK: - Saved Custom List

    /// 所有输过 key 的 provider（内置+custom），按最近使用时间降序。
    /// 给"已保存的 API"列表用。
    var savedAPIProviders: [APIProvider] {
        providers.filter { hasKey(for: $0.id) }.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (la?, lb?): return la > lb
            case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
    }

    /// Custom providers only（供内部判断用）。
    var customProviders: [APIProvider] {
        providers.filter { !$0.isBuiltIn }
    }

    /// 改 custom provider 的 name（别称）。
    func renameCustomProvider(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var custom = loadCustomProviders()
        guard let ci = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[ci].name = trimmed
        saveCustomProviders(custom)
        reload()
    }

    /// 记录在某 provider 下选了某 model（用于卡片相对时间 + 下次"使用"恢复）。
    /// Custom provider 落盘；built-in 仅内存（built-in 不进列表）。
    func touchLastUsed(providerId: String, modelId: String) {
        guard let idx = providers.firstIndex(where: { $0.id == providerId }) else { return }
        providers[idx].lastUsedModelId = modelId
        providers[idx].lastUsedAt = Date()
        if !providers[idx].isBuiltIn {
            var custom = loadCustomProviders()
            if let ci = custom.firstIndex(where: { $0.id == providerId }) {
                custom[ci].lastUsedModelId = modelId
                custom[ci].lastUsedAt = Date()
                saveCustomProviders(custom)
            }
        }
    }

    // MARK: - ccBridge LAN URL override

    var ccBridgeBaseURL: String {
        let override = UserDefaults.standard.string(forKey: "ccBridgeBaseURLOverride") ?? ""
        if !override.isEmpty { return override }
        return APIProvider.ccBridge.baseURL
    }

    func setCCBridgeBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == APIProvider.ccBridge.baseURL {
            UserDefaults.standard.removeObject(forKey: "ccBridgeBaseURLOverride")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "ccBridgeBaseURLOverride")
        }
        reload()
    }

    var ccBridgeBaseURLBackup: String {
        UserDefaults.standard.string(forKey: "ccBridgeBaseURLBackup") ?? ""
    }

    func setCCBridgeBaseURLBackup(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "ccBridgeBaseURLBackup")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "ccBridgeBaseURLBackup")
        }
    }

    // MARK: - Budget (保险闸)

    /// 更新 provider 的某个字段（per-provider 持久化 for custom；内存更新 for built-in）。
    /// closure 收到一份 inout 的 provider，改完会自动持久化。
    private func mutateProvider(id: String, _ apply: (inout APIProvider) -> Void) {
        guard let idx = providers.firstIndex(where: { $0.id == id }) else { return }
        apply(&providers[idx])
        if !providers[idx].isBuiltIn {
            var custom = loadCustomProviders()
            if let ci = custom.firstIndex(where: { $0.id == id }) {
                custom[ci] = providers[idx]
                saveCustomProviders(custom)
            }
        }
    }

    // MARK: - Budget (全局保险闸 — 粟粟决策 2026-04-23)
    // per-id 签名保留避免上游改动；内部忽略 id，全部走 GlobalBudgetStore。

    func setBudgetEnabled(_ enabled: Bool, for id: String) {
        GlobalBudgetStore.shared.setEnabled(enabled)
    }

    func setBudgetUSD(_ amount: Double, for id: String) {
        GlobalBudgetStore.shared.setBudgetUSD(amount)
    }

    func setModelRatio(_ value: Double, for id: String) {
        mutateProvider(id: id) { $0.modelRatio = max(0, value) }
    }

    func setCompletionRatio(_ value: Double, for id: String) {
        mutateProvider(id: id) { $0.completionRatio = max(0, value) }
    }

    func setGroupRatio(_ value: Double, for id: String) {
        mutateProvider(id: id) { $0.groupRatio = max(0, value) }
    }

    func setCurrencyRate(_ value: Double, for id: String) {
        mutateProvider(id: id) { $0.currencyRate = max(0, value) }
    }

    /// 发送后把实际 cost（USD）累加到全局 spent。
    func commitSpend(providerId: String, amount: Double) {
        GlobalBudgetStore.shared.commitSpend(amount)
    }

    /// 重置全局"已用"；预算上限保留。
    func resetSpent(providerId: String) {
        GlobalBudgetStore.shared.resetSpent()
    }

    /// 发送前门控：估算 cost → 看全局保险闸。providerId 只留作签名兼容。
    func budgetGate(providerId: String, estimatedCost: Double) -> BudgetGate {
        BudgetCalculator.gate(estimatedCost: estimatedCost)
    }

    // MARK: - Favorite Models（常用模型 / E7）

    /// model id 格式为 "providerId/modelId"，和 selectedChatModel 对齐。
    func isFavoriteModel(id: String) -> Bool {
        favoriteModelIds.contains(id)
    }

    func toggleFavoriteModel(id: String) {
        if let idx = favoriteModelIds.firstIndex(of: id) {
            favoriteModelIds.remove(at: idx)
        } else {
            favoriteModelIds.append(id)
        }
        saveFavoriteModelIds(favoriteModelIds)
    }

    /// 启动时过滤掉已经不存在的收藏 id（provider 删除 / model 没了）。
    func resolveStaleFavorites() {
        let filtered = favoriteModelIds.filter { model(byId: $0) != nil }
        if filtered.count != favoriteModelIds.count {
            favoriteModelIds = filtered
            saveFavoriteModelIds(filtered)
        }
    }

    /// 给 ModelPickerPopover 用：按 provider 分组的收藏 model。
    /// 只包含有 API Key 且 model 仍存在的条目，按 provider 在 providers 数组中的原序。
    var favoritesByProvider: [(APIProvider, [ProviderModel])] {
        var map: [String: [ProviderModel]] = [:]
        for id in favoriteModelIds {
            guard let m = model(byId: id) else { continue }
            map[m.providerId, default: []].append(m)
        }
        return providers.compactMap { provider -> (APIProvider, [ProviderModel])? in
            guard hasKey(for: provider.id), let ms = map[provider.id], !ms.isEmpty else { return nil }
            return (provider, ms)
        }
    }

    /// "使用这个 API"：切 `selectedChatModel` 到该 provider 的 lastUsedModelId
    /// （若空或已失效，fallback 到 models.first）。
    /// 返回切到的 combined model id，或 nil 表示该 provider 没有可用 models。
    @discardableResult
    func useProvider(id: String) -> String? {
        guard let p = providers.first(where: { $0.id == id }) else { return nil }
        let targetModelId: String? = {
            if let last = p.lastUsedModelId, p.models.contains(where: { $0.modelId == last }) {
                return last
            }
            return p.models.first?.modelId
        }()
        guard let mid = targetModelId else { return nil }
        let combined = "\(id)/\(mid)"
        UserDefaults.standard.set(combined, forKey: "selectedChatModel")
        touchLastUsed(providerId: id, modelId: mid)
        return combined
    }

    // MARK: - Custom Provider CRUD

    func addProvider(_ provider: APIProvider) {
        var custom = loadCustomProviders()
        custom.removeAll { $0.id == provider.id }
        custom.append(provider)
        saveCustomProviders(custom)
        reload()
    }

    func updateProvider(_ provider: APIProvider) {
        if provider.isBuiltIn {
            // Built-in providers: only extra models can be updated (handled separately)
            return
        }
        addProvider(provider) // same logic: replace by id
    }

    func removeProvider(id: String) {
        var custom = loadCustomProviders()
        custom.removeAll { $0.id == id }
        saveCustomProviders(custom)
        // Also clean up API key
        apiKeyCache.removeValue(forKey: id)
        KeychainStore.remove(account: id)
        reload()
    }

    // MARK: - Model Management

    /// Add a custom model to any provider (built-in or custom)
    func addModel(to providerId: String, model: ProviderModel) {
        if let idx = providers.firstIndex(where: { $0.id == providerId }) {
            if providers[idx].isBuiltIn {
                // Store as extra model
                var extraModels = loadExtraModels()
                var list = extraModels[providerId] ?? []
                list.removeAll { $0.modelId == model.modelId }
                list.append(model)
                extraModels[providerId] = list
                saveExtraModels(extraModels)
            } else {
                // Update custom provider directly
                var custom = loadCustomProviders()
                if let ci = custom.firstIndex(where: { $0.id == providerId }) {
                    custom[ci].models.removeAll { $0.modelId == model.modelId }
                    custom[ci].models.append(model)
                    saveCustomProviders(custom)
                }
            }
            reload()
        }
    }

    /// Remove a model from a provider
    func removeModel(from providerId: String, modelId: String) {
        if let idx = providers.firstIndex(where: { $0.id == providerId }) {
            if providers[idx].isBuiltIn {
                var extraModels = loadExtraModels()
                extraModels[providerId]?.removeAll { $0.modelId == modelId }
                if extraModels[providerId]?.isEmpty == true {
                    extraModels.removeValue(forKey: providerId)
                }
                saveExtraModels(extraModels)
            } else {
                var custom = loadCustomProviders()
                if let ci = custom.firstIndex(where: { $0.id == providerId }) {
                    custom[ci].models.removeAll { $0.modelId == modelId }
                    saveCustomProviders(custom)
                }
            }
            reload()
        }
    }

    // MARK: - Fetch Models from API

    /// Fetch available models from the provider's /models endpoint
    func fetchModels(providerId: String) async -> Result<[ProviderModel], Error> {
        guard let prov = providers.first(where: { $0.id == providerId }) else {
            return .failure(NSError(domain: "ProviderManager", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到提供商"]))
        }
        guard let key = apiKey(for: providerId) else {
            return .failure(NSError(domain: "ProviderManager", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "未设置 API Key"]))
        }

        var baseURL = prov.baseURL.hasSuffix("/") ? String(prov.baseURL.dropLast()) : prov.baseURL
        // Auto-append /v1 if missing (common user mistake)
        if !baseURL.hasSuffix("/v1") && !baseURL.contains("/v1/") && !baseURL.hasSuffix("/v1beta") && !baseURL.hasSuffix("/v1beta/openai") && !baseURL.contains("/api/") {
            baseURL += "/v1"
        }
        let urlString = "\(baseURL)/models"

        guard let url = URL(string: urlString) else {
            return .failure(NSError(domain: "ProviderManager", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "无效的 URL"]))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        switch prov.type {
        case .openaiCompatible:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .ccBridge:
            // CC Bridge 不支持 HTTP /models 拉取
            return .failure(NSError(domain: "ProviderManager", code: -5,
                                    userInfo: [NSLocalizedDescriptionKey: "CC Bridge 不支持拉取模型列表"]))
        }

        for (k, v) in prov.extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .failure(NSError(domain: "ProviderManager", code: code,
                                        userInfo: [NSLocalizedDescriptionKey: "请求失败 (\(code))"]))
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(NSError(domain: "ProviderManager", code: -4,
                                        userInfo: [NSLocalizedDescriptionKey: "解析响应失败"]))
            }

            var models: [ProviderModel] = []

            if let dataArray = json["data"] as? [[String: Any]] {
                // OpenAI / Anthropic format: { "data": [{ "id": "...", "display_name": "..." }] }
                for item in dataArray {
                    guard let modelId = item["id"] as? String else { continue }
                    // Filter: skip embeddings, tts, whisper, dall-e, moderation
                    let lower = modelId.lowercased()
                    if lower.contains("embed") || lower.contains("tts") ||
                       lower.contains("whisper") || lower.contains("dall-e") ||
                       lower.contains("moderation") || lower.contains("davinci") ||
                       lower.contains("babbage") {
                        continue
                    }
                    let displayName = (item["display_name"] as? String) ?? modelId
                    models.append(ProviderModel(providerId: providerId, modelId: modelId, name: displayName))
                }
            }

            // Sort: put chat models first, alphabetically
            models.sort { $0.modelId.localizedCaseInsensitiveCompare($1.modelId) == .orderedAscending }

            return .success(models)
        } catch {
            return .failure(error)
        }
    }

    /// Fetch and merge models into the provider (adds new, keeps existing)
    func fetchAndMergeModels(providerId: String) async -> Result<Int, Error> {
        let result = await fetchModels(providerId: providerId)
        switch result {
        case .success(let fetched):
            guard !fetched.isEmpty else {
                return .success(0)
            }
            // Get existing model IDs
            let existingIds = Set(providers.first(where: { $0.id == providerId })?.models.map(\.modelId) ?? [])
            var addedCount = 0
            for model in fetched where !existingIds.contains(model.modelId) {
                addModel(to: providerId, model: model)
                addedCount += 1
            }
            return .success(addedCount)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: - Connection Test

    func testConnection(providerId: String) async -> Result<String, Error> {
        guard let prov = providers.first(where: { $0.id == providerId }) else {
            return .failure(NSError(domain: "ProviderManager", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到提供商"]))
        }
        guard let key = apiKey(for: providerId) else {
            return .failure(NSError(domain: "ProviderManager", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "未设置 API Key"]))
        }

        // Build a minimal request to test the endpoint
        var urlString: String
        var request: URLRequest
        var base = prov.baseURL.hasSuffix("/") ? String(prov.baseURL.dropLast()) : prov.baseURL
        if !base.hasSuffix("/v1") && !base.contains("/v1/") && !base.hasSuffix("/v1beta") && !base.hasSuffix("/v1beta/openai") && !base.contains("/api/") {
            base += "/v1"
        }

        switch prov.type {
        case .openaiCompatible:
            urlString = "\(base)/models"
            guard let url = URL(string: urlString) else {
                return .failure(NSError(domain: "ProviderManager", code: -3,
                                        userInfo: [NSLocalizedDescriptionKey: "无效的 URL: \(urlString)"]))
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        case .anthropic:
            urlString = "\(base)/messages"
            guard let url = URL(string: urlString) else {
                return .failure(NSError(domain: "ProviderManager", code: -3,
                                        userInfo: [NSLocalizedDescriptionKey: "无效的 URL: \(urlString)"]))
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Minimal request that will return quickly (even if it errors, a 4xx means the endpoint is reachable)
            let body: [String: Any] = [
                "model": "claude-haiku-4-5",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        case .ccBridge:
            // CC Bridge 通过 WebSocket 通信，不支持 HTTP 连接测试
            return .success("CC Bridge (WebSocket，无需测试)")
        }

        // Add extra headers
        for (k, v) in prov.extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // Anthropic version header
        if prov.type == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 || http.statusCode == 201 {
                    return .success("连接成功 (\(http.statusCode))")
                } else if http.statusCode == 401 {
                    return .failure(NSError(domain: "ProviderManager", code: http.statusCode,
                                            userInfo: [NSLocalizedDescriptionKey: "API Key 无效 (401)"]))
                } else if http.statusCode == 403 {
                    return .failure(NSError(domain: "ProviderManager", code: http.statusCode,
                                            userInfo: [NSLocalizedDescriptionKey: "权限不足 (403)"]))
                } else {
                    // 4xx/5xx but endpoint is reachable
                    return .success("端点可达 (\(http.statusCode))")
                }
            }
            return .success("连接成功")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Persistence (private)

    private func loadCustomProviders() -> [APIProvider] {
        guard let data = UserDefaults.standard.data(forKey: customProvidersKey) else { return [] }
        return (try? JSONDecoder().decode([APIProvider].self, from: data)) ?? []
    }

    private func saveCustomProviders(_ providers: [APIProvider]) {
        let data = try? JSONEncoder().encode(providers)
        UserDefaults.standard.set(data, forKey: customProvidersKey)
    }

    private func loadExtraModels() -> [String: [ProviderModel]] {
        guard let data = UserDefaults.standard.data(forKey: customModelsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [ProviderModel]].self, from: data)) ?? [:]
    }

    // MARK: - MCP Server Management

    /// 向指定 provider 添加或更新 MCP 服务器（按 id 做 upsert）.
    func addOrUpdateMCPServer(_ server: MCPServerConfig, for providerId: String) {
        var dict = loadMCPServersPerProvider()
        var list = dict[providerId] ?? []
        if let idx = list.firstIndex(where: { $0.id == server.id }) {
            list[idx] = server
        } else {
            list.append(server)
        }
        dict[providerId] = list
        saveMCPServersPerProvider(dict)
        reload()
    }

    /// 从指定 provider 中删除 MCP 服务器.
    func removeMCPServer(id: String, from providerId: String) {
        var dict = loadMCPServersPerProvider()
        dict[providerId]?.removeAll { $0.id == id }
        if dict[providerId]?.isEmpty == true { dict.removeValue(forKey: providerId) }
        saveMCPServersPerProvider(dict)
        reload()
    }

    private func loadMCPServersPerProvider() -> [String: [MCPServerConfig]] {
        guard let data = UserDefaults.standard.data(forKey: mcpServersPerProviderKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [MCPServerConfig]].self, from: data)) ?? [:]
    }

    private func saveMCPServersPerProvider(_ dict: [String: [MCPServerConfig]]) {
        let data = try? JSONEncoder().encode(dict)
        UserDefaults.standard.set(data, forKey: mcpServersPerProviderKey)
    }

    private func loadFavoriteModelIds() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: favoriteModelsKey) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func saveFavoriteModelIds(_ ids: [String]) {
        let data = try? JSONEncoder().encode(ids)
        UserDefaults.standard.set(data, forKey: favoriteModelsKey)
    }

    private func saveExtraModels(_ models: [String: [ProviderModel]]) {
        let data = try? JSONEncoder().encode(models)
        UserDefaults.standard.set(data, forKey: customModelsKey)
    }
}
