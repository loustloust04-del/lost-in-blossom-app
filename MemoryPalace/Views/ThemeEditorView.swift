import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @State private var editingScheme: ColorScheme = .light
    @State private var showImageImporter = false
    @State private var imageImportError: String?
    @State private var selectedPhotoItem: PhotosPickerItem?

    let themeId: String

    init(themeId: String = AppThemeDefinition.customTheme.id) {
        self.themeId = themeId
    }

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    private var theme: AppThemeDefinition {
        manager.themeDefinition(id: themeId) ?? .customTheme
    }

    private var currentTokens: ThemeTokenSet {
        theme.tokens(for: editingScheme)
    }

    private var previewTokens: ThemeTokenSet {
        manager.previewTokenSet(for: themeId, scheme: editingScheme)
    }

    private var backgroundImageURL: URL? {
        manager.backgroundImageURL(for: themeId)
    }

    private var backgroundStyle: ThemeBackgroundStyle {
        manager.backgroundStyle(for: themeId)
    }

    var body: some View {
        let _ = manager.themeChangeID

        NavigationStack {
            List {
                Section("名称") {
                    TextField(
                        theme.isCustomDraft ? "自定义主题" : "主题名称",
                        text: Binding(
                            get: { theme.name },
                            set: { manager.updateThemeName($0, for: themeId) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("编辑模式") {
                    Picker("编辑模式", selection: $editingScheme) {
                        Text("浅色").tag(ColorScheme.light)
                        Text("深色").tag(ColorScheme.dark)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("背景图片") {
                    ThemeEditorBackgroundRow(
                        imageURL: backgroundImageURL,
                        scheme: editingScheme,
                        backgroundStyle: backgroundStyle
                    )

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Text("从照片选背景图")
                            .foregroundColor(Theme.branchIndicator)
                    }

                    Button("从文件选背景图") {
                        showImageImporter = true
                    }
                    .foregroundColor(Theme.branchIndicator)

                    if theme.hasBackgroundImage {
                        ThemeAdjustmentSliderRow(
                            title: "背景透明度",
                            range: ThemeBackgroundStyle.opacityRange,
                            value: backgroundOpacityBinding,
                            leadingLabel: "更淡",
                            trailingLabel: "更明显",
                            valueText: opacityValueText
                        )

                        ThemeAdjustmentSliderRow(
                            title: "左右位置",
                            range: ThemeBackgroundStyle.horizontalOffsetRange,
                            value: backgroundOffsetXBinding,
                            leadingLabel: "向左",
                            trailingLabel: "向右",
                            valueText: offsetValueText(backgroundOffsetXBinding.wrappedValue)
                        )

                        ThemeAdjustmentSliderRow(
                            title: "上下位置",
                            range: ThemeBackgroundStyle.verticalOffsetRange,
                            value: backgroundOffsetYBinding,
                            leadingLabel: "向上",
                            trailingLabel: "向下",
                            valueText: offsetValueText(backgroundOffsetYBinding.wrappedValue)
                        )

                        Button("移除背景图片") {
                            manager.clearBackgroundImage(for: themeId)
                        }
                        .foregroundColor(Theme.danger)

                        Button("重置背景位置和透明度") {
                            manager.resetBackgroundAdjustments(for: themeId)
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }

                    Text("背景图会跟着主题一起切换，主背景和气泡会自动变得更通透一点；位置和透明度也会一起记住。")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("预览") {
                    ThemePreviewCard(
                        title: theme.name,
                        subtitle: editingScheme == .dark ? "深色 token" : "浅色 token",
                        tokenSet: previewTokens,
                        scheme: editingScheme,
                        backgroundImageURL: backgroundImageURL,
                        backgroundStyle: backgroundStyle
                    )
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("表面") {
                    ThemeColorPickerRow(title: "主背景", hexValue: hexValue(for: \.mainBg), color: colorBinding(for: \.mainBg))
                    ThemeColorPickerRow(title: "侧栏背景", hexValue: hexValue(for: \.sidebarBg), color: colorBinding(for: \.sidebarBg))
                    ThemeColorPickerRow(title: "用户气泡", hexValue: hexValue(for: \.userBubble), color: colorBinding(for: \.userBubble))
                    ThemeColorPickerRow(title: "AI 气泡", hexValue: hexValue(for: \.assistantBubble), color: colorBinding(for: \.assistantBubble))
                    ThemeColorPickerRow(title: "辅助底色", hexValue: hexValue(for: \.accent), color: colorBinding(for: \.accent))
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("文字") {
                    ThemeColorPickerRow(title: "主文字", hexValue: hexValue(for: \.textPrimary), color: colorBinding(for: \.textPrimary))
                    ThemeColorPickerRow(title: "次文字", hexValue: hexValue(for: \.textSecondary), color: colorBinding(for: \.textSecondary))
                    ThemeColorPickerRow(title: "弱文字", hexValue: hexValue(for: \.textMuted), color: colorBinding(for: \.textMuted))
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("功能色") {
                    ThemeColorPickerRow(title: "分支强调", hexValue: hexValue(for: \.branchIndicator), color: colorBinding(for: \.branchIndicator))
                    ThemeColorPickerRow(title: "收藏", hexValue: hexValue(for: \.favorite), color: colorBinding(for: \.favorite))
                    ThemeColorPickerRow(title: "危险色", hexValue: hexValue(for: \.danger), color: colorBinding(for: \.danger))
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("快捷操作") {
                    Button(editingScheme == .dark ? "恢复默认深色" : "恢复默认浅色") {
                        manager.restoreDefaultTokenSet(for: editingScheme, themeId: themeId)
                    }
                    .foregroundColor(Theme.branchIndicator)

                    if editingScheme == .dark {
                        Button("用浅色生成深色草稿") {
                            manager.copyLightIntoDarkDraft(themeId: themeId)
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }

                    if theme.isCustomDraft {
                        Button("重置整个自定义主题") {
                            manager.resetCustomTheme()
                        }
                        .foregroundColor(Theme.danger)
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle(theme.isCustomDraft ? "编辑主题" : theme.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: backgroundImageURL,
                scheme: editingScheme,
                backgroundStyle: backgroundStyle
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showImageImporter) {
            DocumentPickerView(contentTypes: [.image]) { urls in
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try manager.setBackgroundImage(from: url, for: themeId)
                } catch {
                    imageImportError = error.localizedDescription
                }
            } onCancel: {}
        }
        .alert("背景图导入失败", isPresented: Binding(
            get: { imageImportError != nil },
            set: { if !$0 { imageImportError = nil } }
        )) {
            Button("好的") {
                imageImportError = nil
            }
        } message: {
            Text(imageImportError ?? "")
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importPhotoItem(newItem)
            }
        }
    }

    private func colorBinding(for keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue>) -> Binding<Color> {
        Binding(
            get: {
                currentTokens[keyPath: keyPath].color
            },
            set: { newValue in
                var tokens = currentTokens
                tokens[keyPath: keyPath] = ThemeColorValue(color: newValue)
                manager.replaceTokenSet(tokens, for: editingScheme, themeId: themeId)
            }
        )
    }

    private func hexValue(for keyPath: WritableKeyPath<ThemeTokenSet, ThemeColorValue>) -> String {
        currentTokens[keyPath: keyPath].hexString
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: {
                backgroundStyle.resolvedOpacity(for: editingScheme)
            },
            set: { newValue in
                manager.updateBackgroundOpacity(newValue, for: themeId)
            }
        )
    }

    private var backgroundOffsetXBinding: Binding<Double> {
        Binding(
            get: {
                Double(backgroundStyle.resolvedOffsetX)
            },
            set: { newValue in
                manager.updateBackgroundOffset(x: newValue, for: themeId)
            }
        )
    }

    private var backgroundOffsetYBinding: Binding<Double> {
        Binding(
            get: {
                Double(backgroundStyle.resolvedOffsetY)
            },
            set: { newValue in
                manager.updateBackgroundOffset(y: newValue, for: themeId)
            }
        )
    }

    private var opacityValueText: String {
        "\(Int((backgroundOpacityBinding.wrappedValue * 100).rounded()))%"
    }

    private func offsetValueText(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded == 0 {
            return "居中"
        }
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    private func importPhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let preferredExtension = item.supportedContentTypes.first?.preferredFilenameExtension
            try manager.setBackgroundImage(
                data: data,
                preferredExtension: preferredExtension,
                for: themeId
            )
        } catch {
            imageImportError = error.localizedDescription
        }
    }
}

private struct ThemeEditorBackgroundRow: View {
    let imageURL: URL?
    let scheme: ColorScheme
    let backgroundStyle: ThemeBackgroundStyle

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThemeBackgroundView(
                fill: Theme.mainBg,
                imageURL: imageURL,
                scheme: scheme,
                backgroundStyle: backgroundStyle
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Theme.mainBg.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(imageURL == nil ? "当前没有背景图" : "背景图已启用")
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(imageURL == nil ? "导入一张图片后，这个主题切换时会连背景一起切。" : "预览只显示氛围，实际界面里会更完整。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(14)
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct ThemeAdjustmentSliderRow: View {
    let title: String
    let range: ClosedRange<Double>
    @Binding var value: Double
    let leadingLabel: String
    let trailingLabel: String
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Text(valueText)
                    .font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            HStack(spacing: 10) {
                Text(leadingLabel)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)

                Slider(value: $value, in: range)
                    .tint(Theme.branchIndicator)

                Text(trailingLabel)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ThemeColorPickerRow: View {
    let title: String
    let hexValue: String
    @Binding var color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Text(hexValue)
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .foregroundColor(Theme.textMuted)

            ColorPicker("", selection: $color)
                .labelsHidden()
        }
    }
}
