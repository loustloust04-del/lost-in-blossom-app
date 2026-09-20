import SwiftUI
import UniformTypeIdentifiers

// MARK: - iOS Appearance Page

struct IOSAppearancePage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @AppStorage("slimInputBar") private var slimInputBar = true
    @AppStorage("chatBubbleMode") private var chatBubbleMode = false
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    @AppStorage("expandAllMessages") private var expandAllMessages = false
    @AppStorage("blurRadius") private var blurRadius = 1.3
    // 气泡外观（高级）
    @AppStorage("bubbleCornerRadius") private var bubbleCornerRadius: Double = 16
    @AppStorage("bubblePaddingH") private var bubblePaddingH: Double = 18
    @AppStorage("bubblePaddingV") private var bubblePaddingV: Double = 15
    @AppStorage("bubbleSpacing") private var bubbleSpacing: Double = 31
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65
    @AppStorage("hideTimestamp") private var hideTimestamp: Bool = false
    @AppStorage("hideRoleName") private var hideRoleName: Bool = false
    @AppStorage("hideActionBar") private var hideActionBar: Bool = false
    @AppStorage("hideAssistantBubble") private var hideAssistantBubble: Bool = false
    @AppStorage("thinkingPreviewMode") private var thinkingPreviewMode: String = "summary"
    @AppStorage("thinkingSheetMode") private var thinkingSheetMode = false  // 开=弹全屏 sheet，关=原地折叠
    @AppStorage("showFlagBlocks") private var showFlagBlocks: Bool = true
    @AppStorage("disableAutoTransparentBubblesOnWallpaper") private var disableAutoTransparent: Bool = false
    @AppStorage("bubbleAdvExpanded") private var bubbleAdvExpanded: Bool = false
    @AppStorage("hapticMode") private var hapticModeRaw: String = "typewriter"

    @State private var importedFonts: [(fileName: String, fontName: String)] = []
    @State private var showFontImporter = false

    var body: some View {
        List {
            Section("字体") {
                VStack(spacing: Theme.optionRowSpacing) {
                    ForEach(FontManager.presetFonts, id: \.name) { preset in
                        FontOptionRow(
                            displayName: preset.displayName,
                            fontName: preset.name,
                            isSelected: selectedFont == preset.name,
                            previewFont: preset.name.isEmpty ? .system(size: Theme.F.body) : .custom(preset.name, size: Theme.F.body)
                        ) {
                            selectedFont = preset.name
                        }
                    }

                    if !importedFonts.isEmpty {
                        Divider().opacity(0.1).padding(.vertical, 2)
                        ForEach(importedFonts, id: \.fontName) { font in
                            FontOptionRow(
                                displayName: font.fileName,
                                fontName: font.fontName,
                                isSelected: selectedFont == font.fontName,
                                previewFont: .custom(font.fontName, size: Theme.F.body),
                                onDelete: {
                                    FontManager.deleteFont(named: font.fontName)
                                    if selectedFont == font.fontName { selectedFont = "" }
                                    importedFonts = FontManager.importedFonts()
                                }
                            ) {
                                selectedFont = font.fontName
                            }
                        }
                    }

                    Button(action: { showFontImporter = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: Theme.F.secondary))
                            Text("导入字体文件...")
                                .font(.system(size: Theme.F.secondary))
                            Spacer()
                        }
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.optionRowVerticalPadding)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("聊天字号") {
                HStack {
                    Text("\(Int(fontScale * 100))%")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Button(action: { fontScale = max(0.5, fontScale - 0.1) }) {
                        Image(systemName: "textformat.size.smaller")
                            .font(.system(size: Theme.F.label))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $fontScale, in: 0.5...2.0, step: 0.05)
                        .tint(Theme.branchIndicator)

                    Button(action: { fontScale = min(2.0, fontScale + 0.1) }) {
                        Image(systemName: "textformat.size.larger")
                            .font(.system(size: Theme.F.label))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                if fontScale != 1.2 {
                    Button(action: { fontScale = 1.2 }) {
                        Text("重置默认")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                DisclosureGroup(isExpanded: $bubbleAdvExpanded) {
                    iosBubbleSliderRow("圆角", value: $bubbleCornerRadius, range: 0...28, step: 1) { "\(Int($0))pt" }
                    iosBubbleSliderRow("水平内边距", value: $bubblePaddingH, range: 8...24, step: 1) { "\(Int($0))pt" }
                    iosBubbleSliderRow("垂直内边距", value: $bubblePaddingV, range: 4...20, step: 1) { "\(Int($0))pt" }
                    iosBubbleSliderRow("气泡间距", value: $bubbleSpacing, range: 8...40, step: 1) { "\(Int($0))pt" }
                    iosBubbleSliderRow("行间距", value: $lineSpacingScale, range: 0.5...2.0, step: 0.05) { "\(Int($0 * 100))%" }
                    iosBubbleSliderRow("段落间距", value: $paragraphSpacingScale, range: 0.5...2.0, step: 0.05) { "\(Int($0 * 100))%" }

                    Toggle("隐藏时间戳", isOn: $hideTimestamp)
                    Toggle("隐藏用户/助手名", isOn: $hideRoleName)
                    Toggle("隐藏消息下方按钮行", isOn: $hideActionBar)
                    Toggle("助手消息气泡", isOn: Binding(
                        get: { !hideAssistantBubble },
                        set: { hideAssistantBubble = !$0 }
                    ))
                    Toggle("壁纸下气泡自动半透明", isOn: Binding(
                        get: { !disableAutoTransparent },
                        set: { disableAutoTransparent = !$0; themeManager?.notifyThemeChange() }
                    ))

                    Button(action: resetAllBubbleAppearance) {
                        HStack {
                            Spacer()
                            Text("全部重置")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                } label: {
                    Text("气泡外观（高级）")
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("消息显示") {
                Toggle(isOn: $chatBubbleMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("气泡模式")
                            .font(.system(size: Theme.F.body))
                        Text("iMessage 式带尾巴气泡，长回复按空行拆成连续小气泡")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }

                Toggle(isOn: $slimInputBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("细输入框")
                            .font(.system(size: Theme.F.body))
                        Text("单行排法，模型与风格移到框外下方；关掉是改版前的两层排法")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                Toggle(isOn: $expandAllMessages) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全部展开全文")
                            .font(.system(size: Theme.F.body))
                        Text("关闭时超过 300 字的消息会折叠")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }

                Toggle(isOn: $showFlagBlocks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示安全提示卡")
                            .font(.system(size: Theme.F.body))
                        Text("Claude 在对话里插入的 ⚠️ flag（如 self_harm_risk + 热线）")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }

                HStack {
                    Text("边缘模糊")
                        .font(.system(size: Theme.F.label))
                    Spacer()
                    Text("\(Int(blurRadius))")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                }
                Slider(value: $blurRadius, in: 0...6, step: 1)
                    .tint(Theme.branchIndicator)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("思考链预览方式") {
                Picker("", selection: $thinkingPreviewMode) {
                    Text("小模型总结").tag("summary")
                    Text("截取前文").tag("prefix")
                    Text("关闭").tag("hidden")
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("思考链展开方式") {
                Toggle("弹全屏窗口", isOn: $thinkingSheetMode)
                    .tint(Theme.branchIndicator)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("震动反馈") {
                Picker("模式", selection: Binding(
                    get: { HapticMode(rawValue: hapticModeRaw) ?? .typewriter },
                    set: { hapticModeRaw = $0.rawValue }
                )) {
                    Text("关闭").tag(HapticMode.off)
                    Text("打字机（ChatGPT 风格）").tag(HapticMode.typewriter)
                    Text("精简（Claude 风格）").tag(HapticMode.minimal)
                }
                .pickerStyle(.inline)

                switch HapticMode(rawValue: hapticModeRaw) ?? .typewriter {
                case .off:
                    Text("不触发任何震动反馈")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                case .typewriter:
                    Text("AI 回复时随文字输出轻微震动，回复完成时震动提示")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                case .minimal:
                    Text("仅在发送消息、复制、删除等操作时提供触觉反馈")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            importedFonts = FontManager.importedFonts()
        }
        .sheet(isPresented: $showFontImporter) {
            DocumentPickerView(
                contentTypes: [
                    UTType(filenameExtension: "ttf") ?? .data,
                    UTType(filenameExtension: "otf") ?? .data,
                    UTType(filenameExtension: "ttc") ?? .data,
                ],
                allowsMultipleSelection: true
            ) { urls in
                showFontImporter = false
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let name = FontManager.importFont(from: url) {
                        selectedFont = name
                    }
                }
                importedFonts = FontManager.importedFonts()
            } onCancel: {
                showFontImporter = false
            }
        }
    }

    // MARK: - Bubble Appearance helpers (iOS)

    @ViewBuilder
    private func iosBubbleSliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: Theme.F.label))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.branchIndicator)
        }
    }

    private func resetAllBubbleAppearance() {
        bubbleCornerRadius = 16
        bubblePaddingH = 18
        bubblePaddingV = 15
        bubbleSpacing = 31
        lineSpacingScale = 1.45
        paragraphSpacingScale = 1.65
        hideTimestamp = false
        hideRoleName = false
        hideActionBar = false
    }
}

// MARK: - Font Option Row

struct FontOptionRow: View {
    let displayName: String
    let fontName: String
    let isSelected: Bool
    let previewFont: Font
    var onDelete: (() -> Void)? = nil
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                Text("记忆宫殿")
                    .font(previewFont)
                    .foregroundColor(Theme.textPrimary)
                Text(displayName)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
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
                    .fill(isSelected ? Theme.accent.opacity(0.4) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
