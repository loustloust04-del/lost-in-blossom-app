import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

// MARK: - Settings Container

struct SettingsView: View {
    /// 写作风格开关需要落到当前对话上（StyleManagerView），从 ContentView 传入。
    var viewModel: ConversationViewModel? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "通用"
        case data = "数据与备份"
        case api = "API"
        case mcp = "MCP 工具"
        case persona = "Prompt"
        case regex = "正则"
        case style = "写作风格"
        case browser = "浏览器"
        case gatewayConsole = "网关控制台"
        case rightPanel = "右栏"
        case memory = "记忆"
        case tokenStats = "Token 统计"
        case providerManage = "Provider 管理"
        case sticker = "贴纸"
        case notifications = "通知"
        case appearance = "外观"
        case theme = "主题"
        case health = "健康"
        case voice = "语音"
        case debug = "开发调试"
        case hapticTest = "震动测试"
        case ccSettings = "Claude Code"
        case terminal = "终端"
        case fileLibrary = "文件库"
        case groupChat = "群聊"
    }

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    var body: some View {
        let _ = manager.themeChangeID
        iOSSettingsBody
    }

    @State private var selectedSettingsTab: SettingsTab? = nil

    private var iOSSettingsBody: some View {
        NavigationStack {
            List {
                Section {
                    settingsButton(icon: "gearshape", title: "通用", color: Theme.textSecondary, tab: .general)
                }
                Section {
                    settingsButton(icon: "network", title: "API", color: Theme.textSecondary, tab: .api)
                    settingsButton(icon: "server.rack", title: "Provider 管理", color: Theme.textSecondary, tab: .providerManage)
                    settingsButton(icon: "wrench.and.screwdriver", title: "MCP 工具", color: Theme.textSecondary, tab: .mcp)
                    settingsButton(icon: "text.bubble", title: "Prompt", color: Theme.branchIndicator, tab: .persona)
                    settingsButton(icon: "textformat.abc", title: "正则", color: Theme.textSecondary, tab: .regex)
                    settingsButton(icon: "sparkles", title: "写作风格", color: Theme.branchIndicator, tab: .style)
                    settingsButton(icon: "safari", title: "浏览器", color: Theme.accent, tab: .browser)
                    settingsButton(icon: "cloud", title: "网关控制台", color: Theme.branchIndicator, tab: .gatewayConsole)
                    settingsButton(icon: "brain.head.profile", title: "记忆", color: Theme.textSecondary, tab: .memory)
                    settingsButton(icon: "chart.bar", title: "Token 统计", color: Theme.textSecondary, tab: .tokenStats)
                    // 0910 兔兔报「设置里找不到群聊」：页面和路由都加了，**忘了把入口
                    // 摆进这张手工排版的列表**——房间盖好了没装门。
                    settingsButton(icon: "person.2", title: "群聊", color: Theme.textSecondary, tab: .groupChat)
                } header: {
                    settingsSectionHeader("对话与模型")
                }
                Section {
                    settingsButton(icon: "paintbrush", title: "外观", color: Theme.textSecondary, tab: .appearance)
                    settingsButton(icon: "circle.lefthalf.filled", title: "主题", color: Theme.branchIndicator, tab: .theme)
                    settingsButton(icon: "star.circle", title: "贴纸", color: Theme.textSecondary, tab: .sticker)
                    settingsButton(icon: "sidebar.right", title: "右栏", color: Theme.textSecondary, tab: .rightPanel)
                } header: {
                    settingsSectionHeader("外观")
                }
                Section {
                    settingsButton(icon: "terminal", title: "Claude Code", color: Theme.branchIndicator, tab: .ccSettings)
                    settingsButton(icon: "keyboard", title: "终端", color: Theme.textSecondary, tab: .terminal)
                    settingsButton(icon: "folder", title: "文件库", color: Theme.textSecondary, tab: .fileLibrary)
                } header: {
                    settingsSectionHeader("Claude Code")
                }
                Section {
                    settingsButton(icon: "archivebox", title: "数据与备份", color: Theme.textSecondary, tab: .data)
                    settingsButton(icon: "bell.fill", title: "通知", color: Theme.branchIndicator, tab: .notifications)
                    settingsButton(icon: "heart.text.square", title: "健康", color: Theme.branchIndicator, tab: .health)
                    settingsButton(icon: "waveform", title: "语音", color: Theme.branchIndicator, tab: .voice)
                } header: {
                    settingsSectionHeader("数据")
                }
                Section {
                    settingsButton(icon: "ladybug", title: "开发调试", color: Theme.textSecondary, tab: .debug)
                    settingsButton(icon: "waveform", title: "震动测试", color: Theme.textSecondary, tab: .hapticTest)
                } header: {
                    settingsSectionHeader("开发")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedSettingsTab) { tab in
                switch tab {
                case .general: IOSGeneralPage()
                case .appearance: IOSAppearancePage()
                case .theme: IOSThemePage()
                case .persona: PersonaSettingsTab()
                case .api: APISettingsTab()
                case .providerManage: ProviderManageView()
                case .mcp: MCPSettingsTab()
                case .memory: IOSMemoryPage()
                case .tokenStats: TokenStatsView()
                case .regex: IOSRegexPage()
                case .style: StyleManagerView(viewModel: viewModel, manager: StyleManager.shared)
                case .browser: BrowserView()
                case .gatewayConsole: GatewayConsoleView()
                case .sticker:
                    IOSStickerPage()
                case .rightPanel:
                    IOSRightPanelPage()
                case .data: DataSettingsTab()
                case .voice: VoiceSettingsTab()
                case .health: HealthSettingsTab()
                case .notifications: IOSNotificationPage()
                case .debug: IOSDebugPage()
                case .hapticTest: HapticTestView()
                case .ccSettings: CCSettingsView()
                case .terminal: TerminalSettingsTab()
                case .fileLibrary: FileLibrarySettingsTab()
                case .groupChat: GroupChatSettingsTab()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebarBg.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Settings Row Helper (iOS)

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.textMuted)
            .textCase(nil)
    }

    private func settingsButton(icon: String, title: String, color: Color, tab: SettingsTab) -> some View {
        Button {
            selectedSettingsTab = tab
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }
}

// MARK: - Settings Text Field

struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: Theme.SettingsFont.label))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.SettingsFont.body))
                .padding(.horizontal, 10)
                .padding(.vertical, Theme.optionRowVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.mainBg.opacity(0.8))
                )
        }
    }
}
