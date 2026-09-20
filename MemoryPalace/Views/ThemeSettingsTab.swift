import SwiftUI

struct IOSThemePage: View {
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @State private var editingThemeId: String?
    @State private var showSaveSheet = false
    @State private var pendingThemeName = ""
    @State private var pendingDeleteTheme: AppThemeDefinition?

    private var manager: ThemeManager {
        themeManager ?? ThemeManager.shared
    }

    private var selectedTheme: AppThemeDefinition {
        manager.selectedTheme
    }

    var body: some View {
        let _ = manager.themeChangeID

        List {
            Section("显示模式") {
                ForEach(AppThemeMode.allCases) { mode in
                    ThemeModeRow(
                        title: mode.title,
                        subtitle: mode.subtitle,
                        isSelected: manager.themeMode == mode
                    ) {
                        manager.themeMode = mode
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("主题") {
                ThemePreviewCard(
                    title: selectedTheme.name,
                    subtitle: manager.themeMode.title,
                    tokenSet: manager.currentTokenSet,
                    scheme: manager.activeScheme,
                    backgroundImageURL: manager.currentBackgroundImageURL,
                    backgroundStyle: manager.currentBackgroundStyle
                )

                Button {
                    prepareSaveSheet()
                } label: {
                    ThemeActionRow(
                        icon: "square.and.arrow.down",
                        title: "保存当前主题",
                        subtitle: "把配色和背景图一起存成新主题"
                    )
                }
                .buttonStyle(.plain)

                if selectedTheme.isEditable {
                    Button {
                        editingThemeId = selectedTheme.id
                    } label: {
                        ThemeActionRow(
                            icon: "paintpalette",
                            title: "编辑当前主题",
                            subtitle: "继续改颜色或背景图片"
                        )
                    }
                    .buttonStyle(.plain)
                }

                ForEach(manager.themeDefinitions) { theme in
                    ThemeDefinitionRow(
                        theme: theme,
                        tokenSet: manager.previewTokenSet(for: theme.id, scheme: manager.activeScheme),
                        backgroundImageURL: manager.backgroundImageURL(for: theme.id),
                        backgroundStyle: manager.backgroundStyle(for: theme.id),
                        isSelected: manager.selectedThemeId == theme.id,
                        onSelect: {
                            manager.selectTheme(id: theme.id)
                        },
                        onEdit: theme.isEditable ? {
                            manager.selectTheme(id: theme.id)
                            editingThemeId = theme.id
                        } : nil,
                        onDelete: theme.isDeletable ? {
                            pendingDeleteTheme = theme
                        } : nil
                    )
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("背景策略") {
                Toggle(isOn: Binding(
                    get: { manager.usePureBackground },
                    set: { manager.usePureBackground = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("纯净背景")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Text("让背景更克制，但保留背景图和主题氛围。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: manager.currentBackgroundImageURL,
                scheme: manager.activeScheme,
                backgroundStyle: manager.currentBackgroundStyle
            )
            .ignoresSafeArea()
        }
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { editingThemeId != nil },
            set: { if !$0 { editingThemeId = nil } }
        )) {
            if let editingThemeId {
                ThemeEditorView(themeId: editingThemeId)
                    .environment(manager)
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            ThemeSaveSheet(
                name: $pendingThemeName,
                previewTheme: selectedTheme,
                previewTokenSet: manager.currentTokenSet,
                previewBackgroundImageURL: manager.currentBackgroundImageURL,
                previewBackgroundStyle: manager.currentBackgroundStyle
            ) {
                _ = manager.saveThemeCopy(from: selectedTheme.id, name: pendingThemeName)
                showSaveSheet = false
            }
            .environment(manager)
        }
        .alert(
            "删除主题？",
            isPresented: Binding(
                get: { pendingDeleteTheme != nil },
                set: { if !$0 { pendingDeleteTheme = nil } }
            ),
            presenting: pendingDeleteTheme
        ) { theme in
            Button("删除", role: .destructive) {
                manager.deleteTheme(id: theme.id)
                pendingDeleteTheme = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteTheme = nil
            }
        } message: { theme in
            Text("“\(theme.name)”和它的背景图会一起被删掉。")
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func prepareSaveSheet() {
        pendingThemeName = selectedTheme.isCustomDraft ? "我的主题" : "\(selectedTheme.name) 副本"
        showSaveSheet = true
    }
}

private struct ThemeModeRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(isSelected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.accent.opacity(0.45) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ThemeDefinitionRow: View {
    let theme: AppThemeDefinition
    let tokenSet: ThemeTokenSet
    let backgroundImageURL: URL?
    let backgroundStyle: ThemeBackgroundStyle
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    ThemePalettePreview(colors: tokenSet.previewColors)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(theme.name)
                                .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                                .foregroundColor(Theme.textPrimary)

                            ThemeMetaBadge(text: badgeText, tone: badgeTone)

                            if theme.hasBackgroundImage {
                                ThemeMetaBadge(text: "背景图", tone: .image)
                            }
                        }

                        Text(subtitle)
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(Theme.textMuted)
                    }

                    Spacer(minLength: 8)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: Theme.SettingsFont.secondary, weight: .semibold))
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
            }
            .buttonStyle(.plain)

            if let onEdit {
                Button("编辑") {
                    onEdit()
                }
                .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
            }

            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                        .foregroundColor(Theme.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            ZStack {
                ThemeBackgroundView(
                    fill: isSelected ? Theme.accent.opacity(0.45) : Theme.mainBg.opacity(0.5),
                    imageURL: backgroundImageURL,
                    scheme: Theme.activeScheme,
                    backgroundStyle: backgroundStyle
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Theme.branchIndicator.opacity(0.24) : Color.clear, lineWidth: 1)
        )
    }

    private var badgeText: String {
        if theme.isBuiltIn {
            return "内置"
        }
        if theme.isCustomDraft {
            return "草稿"
        }
        return "已保存"
    }

    private var subtitle: String {
        if theme.isBuiltIn {
            return "宫殿内置的基础主题。"
        }
        if theme.isCustomDraft {
            return "你的编辑草稿，可继续修改或另存为主题。"
        }
        return "已经保存到主题库里，可继续编辑和切换。"
    }

    private var badgeTone: ThemeMetaBadge.Tone {
        if theme.isBuiltIn {
            return .neutral
        }
        if theme.isCustomDraft {
            return .draft
        }
        return .saved
    }
}

private struct ThemeMetaBadge: View {
    enum Tone {
        case neutral
        case draft
        case saved
        case image

        var foreground: Color {
            switch self {
            case .neutral:
                return Theme.textMuted
            case .draft, .saved, .image:
                return Theme.branchIndicator
            }
        }

        var background: Color {
            switch self {
            case .neutral:
                return Theme.accent.opacity(0.35)
            case .draft:
                return Theme.branchIndicator.opacity(0.12)
            case .saved:
                return Theme.branchIndicator.opacity(0.16)
            case .image:
                return Theme.branchIndicator.opacity(0.10)
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: Theme.SettingsFont.badge, weight: .medium))
            .foregroundColor(tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(tone.background)
            )
    }
}

private struct ThemeActionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: Theme.SettingsFont.body))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textPrimary)

                Text(subtitle)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: Theme.SettingsFont.secondary, weight: .semibold))
                .foregroundColor(Theme.textMuted.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}

private struct ThemeSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    let previewTheme: AppThemeDefinition
    let previewTokenSet: ThemeTokenSet
    let previewBackgroundImageURL: URL?
    let previewBackgroundStyle: ThemeBackgroundStyle
    let onSave: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("名称") {
                    TextField("新主题", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("预览") {
                    ThemePreviewCard(
                        title: trimmedName.isEmpty ? previewTheme.name : trimmedName,
                        subtitle: "保存后可继续编辑和切换",
                        tokenSet: previewTokenSet,
                        scheme: Theme.activeScheme,
                        backgroundImageURL: previewBackgroundImageURL,
                        backgroundStyle: previewBackgroundStyle
                    )
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section {
                    Button("保存主题") {
                        onSave()
                        dismiss()
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(trimmedName.isEmpty)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("保存主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ThemeBackgroundView(
                fill: Theme.sidebarBg,
                imageURL: previewBackgroundImageURL,
                scheme: Theme.activeScheme,
                backgroundStyle: previewBackgroundStyle
            )
            .ignoresSafeArea()
        }
    }
}

struct ThemePreviewCard: View {
    let title: String
    let subtitle: String
    let tokenSet: ThemeTokenSet
    let scheme: ColorScheme
    let backgroundImageURL: URL?
    let backgroundStyle: ThemeBackgroundStyle

    init(
        title: String,
        subtitle: String,
        tokenSet: ThemeTokenSet,
        scheme: ColorScheme,
        backgroundImageURL: URL? = nil,
        backgroundStyle: ThemeBackgroundStyle = ThemeBackgroundStyle()
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tokenSet = tokenSet
        self.scheme = scheme
        self.backgroundImageURL = backgroundImageURL
        self.backgroundStyle = backgroundStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.SettingsFont.body, weight: .semibold))
                        .foregroundColor(tokenSet.textPrimary.color)
                    Text(subtitle)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(tokenSet.textMuted.color)
                }

                Spacer()

                ThemePalettePreview(colors: tokenSet.previewColors)
            }

            HStack(spacing: 10) {
                previewBubble("你", "这套背景舒服。", bubble: tokenSet.userBubble.color, text: tokenSet.textPrimary.color)
                previewBubble("助手", scheme == .dark ? "深色也接上了。" : "浅色这边也会即时更新。", bubble: tokenSet.assistantBubble.color, text: tokenSet.textPrimary.color)
            }

            HStack(spacing: 10) {
                Text("链接")
                    .font(.system(size: Theme.SettingsFont.caption, weight: .medium))
                    .foregroundColor(tokenSet.branchIndicator.color)

                Text(backgroundImageURL == nil ? "纯色主题" : "带背景图")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(tokenSet.textSecondary.color)

                Spacer()

                Image(systemName: "star.fill")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(tokenSet.favorite.color)
            }
        }
        .padding(14)
        .background(
            ThemeBackgroundView(
                fill: tokenSet.sidebarBg.color,
                imageURL: backgroundImageURL,
                scheme: scheme,
                backgroundStyle: backgroundStyle
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tokenSet.accent.color.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func previewBubble(_ name: String, _ text: String, bubble: Color, text textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.system(size: Theme.SettingsFont.caption, weight: .medium))
                .foregroundColor(tokenSet.textMuted.color)
            Text(text)
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bubble)
                )
        }
    }
}

struct ThemePalettePreview: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { entry in
                Circle()
                    .fill(entry.element)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
            }
        }
        .padding(.trailing, 4)
    }
}
