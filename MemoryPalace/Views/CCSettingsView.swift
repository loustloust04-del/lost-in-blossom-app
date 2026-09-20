import SwiftUI

/// Claude Code 设置：cc-bridge 特有的设置（推送、主动找我/nudge）。
struct CCSettingsView: View {
    @AppStorage(CCBridgeWebSocketClient.pushPreviewKey) private var pushPreview = "full"
    @AppStorage("assistantName") private var assistantName = "助手"

    // 主动找我（nudge）
    @AppStorage("ccNudgeEnabled") private var nudgeEnabled = true
    @AppStorage("ccNudgeIdleMin") private var idleMin = 15
    @AppStorage("ccNudgeIdleMax") private var idleMax = 30
    @AppStorage("ccNudgeQuietStartMin") private var quietStartMin = 0
    @AppStorage("ccNudgeQuietEndMin") private var quietEndMin = 360
    @AppStorage("ccNudgeCooldown") private var cooldown = 60
    @AppStorage("ccNudgeTemplate") private var template = ""
    @AppStorage("pocketBrowserEnabled") private var pocketEnabled = false

    static let defaultTemplate = "[系统] {name} 已经 {idle} 分钟没说话了。如果你想，可以主动找 {name} 说点什么——用 reply 工具回复（chat_id 见本 channel）。也可以选择不打扰。"

    private func sync() { CCBridgeWebSocketClient.shared.sendCCConfig() }

    private func dateFromMin(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private func minFromDate(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        List {
            // MARK: 推送
            Section {
                Picker("推送内容", selection: $pushPreview) {
                    Text("完整预览").tag("full")
                    Text("不剧透").tag("hidden")
                }
                .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .onChange(of: pushPreview) { _, mode in CCBridgeWebSocketClient.shared.updatePushPreview(mode) }

                HStack {
                    Text("推送显示名")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(assistantName)
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textMuted)
                }
            } header: {
                Text("推送通知")
            } footer: {
                Text("不在 app 里看时，AI 主动找你会推送到手机。推送标题用「AI 的名字」（在「通用」里改），「不剧透」时只显示「<名字>找你了」。")
            }
            .listRowBackground(Theme.mainBg)

            // MARK: Pocket Browser（让 Caelum 借手机浏览网页）
            Section {
                Toggle("让 Caelum 借我的手机浏览网页", isOn: $pocketEnabled)
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: pocketEnabled) { _, on in
                        if on { PocketClient.shared.start() } else { PocketClient.shared.stop() }
                    }
            } header: {
                Text("Pocket Browser")
            } footer: {
                Text("开启后，Caelum 能用这台手机里的浏览器打开网页、读正文、跑脚本——用你真机的登录状态（比如已登录的网站）。她会看到你登录的内容，也能在页面上执行操作，所以只在你信任、需要她帮你查东西时开。关掉即断开。")
            }
            .listRowBackground(Theme.mainBg)

            // MARK: 主动找我（nudge）
            Section {
                Toggle("让 AI 主动找我", isOn: $nudgeEnabled)
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: nudgeEnabled) { _, _ in sync() }

                if nudgeEnabled {
                    ParameterRow(label: "沉默下限（分钟）",
                                 value: Binding(get: { Double(idleMin) },
                                                set: { idleMin = Int($0); if idleMax < idleMin { idleMax = idleMin }; sync() }),
                                 range: 1...180, step: 1, intMode: true)
                    ParameterRow(label: "沉默上限（分钟）",
                                 value: Binding(get: { Double(idleMax) },
                                                set: { idleMax = Int($0); if idleMax < idleMin { idleMin = idleMax }; sync() }),
                                 range: 1...240, step: 1, intMode: true)
                    ParameterRow(label: "冷却（分钟）",
                                 value: Binding(get: { Double(cooldown) },
                                                set: { cooldown = Int($0); sync() }),
                                 range: 0...720, step: 5, intMode: true)

                    DatePicker("休眠从", selection: Binding(get: { dateFromMin(quietStartMin) },
                                                          set: { quietStartMin = minFromDate($0); sync() }),
                               displayedComponents: .hourAndMinute)
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textPrimary)
                    DatePicker("休眠到", selection: Binding(get: { dateFromMin(quietEndMin) },
                                                          set: { quietEndMin = minFromDate($0); sync() }),
                               displayedComponents: .hourAndMinute)
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textPrimary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统提示文案")
                            .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        TextField(Self.defaultTemplate, text: $template, axis: .vertical)
                            .font(.system(size: 13))
                            .lineLimit(3...6)
                            .onChange(of: template) { _, _ in sync() }
                    }
                }
            } header: {
                Text("主动找我")
            } footer: {
                Text("你沉默够久（且非休眠时段、非冷却中）时，AI 会收到一条系统提示，自行决定要不要主动找你。文案留空用上面灰字默认；可用 {idle}=分钟数、{name}=你的名字。休眠时段按这台电脑的时区算。")
            }
            .listRowBackground(Theme.mainBg)
        }
        .navigationTitle("Claude Code")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
