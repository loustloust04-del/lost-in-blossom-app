import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

// MARK: - Persona Settings Tab

struct PersonaSettingsTab: View {
    var useSheetNavigation: Bool = false  // 右栏用 sheet 代替 push 导航

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @AppStorage("personaEditMode") private var personaEditMode = "simple"
    @State private var showPresetImporter = false
    @State private var expandedSlotIds: Set<String> = []
    @State private var samplingExpanded = false
    @State private var selectedSlotIndex: Int? = nil
    @State private var showFullEditor = false
    @State private var fullEditLabel = ""
    @State private var fullEditText = ""
    @State private var fullEditSlotId: String? = nil
    @State private var isRenamingPreset = false
    @State private var renamingPresetName = ""
    @State private var iOSSimpleDrafts: [String: String] = [:]
    @State private var iOSSimpleDraftPresetId: String? = nil
    @State private var iOSSimpleSaveTask: Task<Void, Never>? = nil
    @State private var iOSSimpleFocusedSlotId: String? = nil
    @State private var iOSSimpleScrollRequest = 0
    @State private var iOSSimpleVisibilityTask: Task<Void, Never>? = nil
    // 原始模式 JSON 缓冲
    @State private var rawJSONBuffer = ""
    @State private var rawJSONError: String? = nil
    @State private var rawJSONDirty = false

    private struct IOSSimplePromptField: Identifiable {
        let slotId: String
        let label: String
        let placeholder: String

        var id: String { slotId }
    }

    private static let iOSSimplePromptSlotIds = [
        PromptSlot.mainId,
        PromptSlot.charDescriptionId,
        PromptSlot.personaDescriptionId,
        PromptSlot.dialogueExamplesId,
        PromptSlot.jailbreakId,
    ]

    private static let iOSSimplePromptFields = [
        IOSSimplePromptField(slotId: PromptSlot.mainId, label: "系统指令", placeholder: "你是一个有帮助的助手..."),
        IOSSimplePromptField(slotId: PromptSlot.charDescriptionId, label: "助手设定", placeholder: "AI 助手的设定、风格、背景..."),
        IOSSimplePromptField(slotId: PromptSlot.personaDescriptionId, label: "用户描述", placeholder: "我叫天奕，喜欢..."),
        IOSSimplePromptField(slotId: PromptSlot.dialogueExamplesId, label: "对话示例", placeholder: "{{user}}: 你好\n{{char}}: 你好，今天能帮什么？"),
        IOSSimplePromptField(slotId: PromptSlot.jailbreakId, label: "后置提醒", placeholder: "保持角色设定，用自然的语气回应。"),
    ]

    var body: some View {
        iOSPromptPage
    }

    // MARK: - macOS Persona Tab

    @ViewBuilder
    private var personaTab: some View {
        if let pm = profileManager, let psm = presetManager {
            let profile = pm.currentProfile
            let preset = psm.preset(byId: profile.presetId) ?? Preset.balanced

            VStack(alignment: .leading, spacing: 16) {
                // 第一排：预设选择 + 管理按钮
                HStack(spacing: 6) {
                    Text("预设")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    if isRenamingPreset {
                        TextField("预设名称", text: $renamingPresetName, onCommit: {
                            if !renamingPresetName.isEmpty {
                                var p = preset
                                p.name = renamingPresetName
                                psm.save(p)
                            }
                            isRenamingPreset = false
                        })
                        .font(.system(size: Theme.SettingsFont.body))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                        Button("确定") {
                            if !renamingPresetName.isEmpty {
                                var p = preset
                                p.name = renamingPresetName
                                psm.save(p)
                            }
                            isRenamingPreset = false
                        }
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.accent)

                        Button("取消") { isRenamingPreset = false }
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .buttonStyle(.plain)
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Picker("", selection: Binding(
                            get: { profile.presetId },
                            set: { newId in
                                var p = profile
                                p.presetId = newId
                                pm.updateProfile(p)
                            }
                        )) {
                            ForEach(psm.allPresets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(Theme.branchIndicator)
                        .fixedSize()

                        Button {
                            let copy = psm.duplicate(preset)
                            var p = profile
                            p.presetId = copy.id
                            pm.updateProfile(p)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: Theme.SettingsFont.secondary))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("复制预设")

                        if !preset.isBuiltIn {
                            Button {
                                renamingPresetName = preset.name
                                isRenamingPreset = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: Theme.SettingsFont.secondary))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("重命名")
                        }

                        Button {
                            exportPreset(preset)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: Theme.SettingsFont.secondary))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("导出预设 JSON")

                        if !preset.isBuiltIn {
                            Button {
                                let fallbackId = Preset.balanced.id
                                psm.delete(preset)
                                var p = profile
                                p.presetId = fallbackId
                                pm.updateProfile(p)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: Theme.SettingsFont.secondary))
                                    .foregroundColor(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("删除预设")
                        }
                    }

                    Spacer()
                }

                // 第二排：模式切换
                HStack {
                    Picker("", selection: $personaEditMode) {
                        Text("简单").tag("simple")
                        Text("插槽").tag("slots")
                        Text("JSON").tag("raw")
                        Text("组装").tag("assembly")
                        Text("请求").tag("request")
                    }
                    .pickerStyle(.segmented)
                    .tint(Theme.branchIndicator)

                    Spacer()
                }

                Divider().opacity(0.15)

                // 采样参数只在插槽和 JSON 模式显示
                if personaEditMode == "slots" || personaEditMode == "raw" {
                    // iOS: collapsible section
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { samplingExpanded.toggle() }
                    } label: {
                        HStack {
                            Text("采样参数")
                                .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: samplingExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: Theme.SettingsFont.label))
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.assistantBubble))
                    }
                    .buttonStyle(.plain)
                    if samplingExpanded {
                        personaSamplingSection(preset: preset, profile: profile, pm: pm, psm: psm)
                    }
                    Divider().opacity(0.15)
                }

                // 模式内容
                switch personaEditMode {
                case "slots":
                    personaSlotsMode(preset: preset, psm: psm)
                case "raw":
                    personaRawMode(preset: preset, psm: psm)
                case "assembly":
                    personaAssemblyPreview(preset: preset, profile: profile)
                case "request":
                    personaRequestPreview(preset: preset, profile: profile)
                default:
                    personaSimpleMode(preset: preset, psm: psm)
                }
            }
        } else {
            Text("加载中...")
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - Preset Export / Import

    private func exportPreset(_ preset: Preset) {
    }

    private func importPresetData(_ data: Data) {
        guard let psm = presetManager else { return }
        if let imported = try? psm.importFromSillyTavern(data) {
            if let pm = profileManager {
                var p = pm.currentProfile
                p.presetId = imported.id
                pm.updateProfile(p)
            }
        }
    }

    private func handlePresetImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        importPresetData(data)
    }

    // MARK: Persona — 采样参数

    private func personaSamplingSection(preset: Preset, profile: Profile, pm: ProfileManager, psm: PresetManager) -> some View {
        let tempBinding = Binding<Double>(
            get: { preset.sampling.temperature },
            set: { val in
                var p = preset
                p.sampling.temperature = val
                psm.save(p)
            }
        )
        let contextBinding = Binding<Double>(
            get: { Double(preset.sampling.contextDepth) },
            set: { val in
                var p = preset
                p.sampling.contextDepth = Int(val)
                psm.save(p)
            }
        )
        let topPBinding = Binding<Double>(
            get: { preset.sampling.topP },
            set: { val in
                var p = preset
                p.sampling.topP = val
                psm.save(p)
            }
        )
        let maxTokensBinding = Binding<Double>(
            get: { Double(preset.sampling.maxTokens) },
            set: { val in
                var p = preset
                p.sampling.maxTokens = Int(val)
                psm.save(p)
            }
        )
        let topKBinding = Binding<Double>(
            get: { Double(preset.sampling.topK) },
            set: { val in
                var p = preset
                p.sampling.topK = Int(val)
                psm.save(p)
            }
        )
        let freqBinding = Binding<Double>(
            get: { preset.sampling.frequencyPenalty },
            set: { val in
                var p = preset
                p.sampling.frequencyPenalty = val
                psm.save(p)
            }
        )
        let presBinding = Binding<Double>(
            get: { preset.sampling.presencePenalty },
            set: { val in
                var p = preset
                p.sampling.presencePenalty = val
                psm.save(p)
            }
        )
        let seedBinding = Binding<Double>(
            get: { Double(preset.sampling.seed) },
            set: { val in
                var p = preset
                p.sampling.seed = Int(val)
                psm.save(p)
            }
        )
        let reasoningBinding = Binding<String>(
            get: { preset.sampling.reasoningEffort },
            set: { val in
                var p = preset
                p.sampling.reasoningEffort = val
                psm.save(p)
            }
        )
        let verbosityBinding = Binding<String>(
            get: { preset.sampling.verbosity },
            set: { val in
                var p = preset
                p.sampling.verbosity = val
                psm.save(p)
            }
        )
        let streamingBinding = Binding<Bool>(
            get: { preset.sampling.streaming },
            set: { val in
                var p = preset
                p.sampling.streaming = val
                psm.save(p)
            }
        )
        let continuePostfixBinding = Binding<String>(
            get: { preset.sampling.continuePostfix },
            set: { val in
                var p = preset
                p.sampling.continuePostfix = val
                psm.save(p)
            }
        )
        let postProcessingModeBinding = Binding<String>(
            get: { preset.sampling.postProcessingMode },
            set: { val in
                var p = preset
                p.sampling.postProcessingMode = val
                psm.save(p)
            }
        )
        let squashSystemMessagesBinding = Binding<Bool>(
            get: { preset.sampling.squashSystemMessages },
            set: { val in
                var p = preset
                p.sampling.squashSystemMessages = val
                psm.save(p)
            }
        )
        let continuePrefillBinding = Binding<Bool>(
            get: { preset.sampling.continuePrefill },
            set: { val in
                var p = preset
                p.sampling.continuePrefill = val
                psm.save(p)
            }
        )
        let cacheFriendlyBinding = Binding<Bool>(
            get: { preset.sampling.cacheFriendly },
            set: { val in
                var p = preset
                p.sampling.cacheFriendly = val
                psm.save(p)
            }
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text("采样参数")
                .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 12) {
                ParameterRow(label: "Temperature", value: tempBinding, range: 0...2, step: 0.1)
                ParameterRow(label: "上下文深度", value: contextBinding, range: 5...200, step: 5, intMode: true)
                ParameterRow(label: "Top P", value: topPBinding, range: 0...1, step: 0.05, format: "%.2f")
                ParameterRow(label: "Max Tokens", value: maxTokensBinding, range: 256...16384, step: 256, intMode: true)
                ParameterRow(label: "Top K", value: topKBinding, range: 0...500, step: 1, intMode: true)
                ParameterRow(label: "Freq Penalty", value: freqBinding, range: -2...2, step: 0.05, format: "%.2f")
                ParameterRow(label: "Pres Penalty", value: presBinding, range: -2...2, step: 0.05, format: "%.2f")
                ParameterRow(label: "Seed", value: seedBinding, range: -1...9999, step: 1, intMode: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("推理深度")
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textMuted)
                    Picker("", selection: reasoningBinding) {
                        Text("自动").tag("auto")
                        Text("低").tag("low")
                        Text("中").tag("medium")
                        Text("高").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("详细度")
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textMuted)
                    Picker("", selection: verbosityBinding) {
                        Text("自动").tag("auto")
                        Text("简洁").tag("concise")
                        Text("详细").tag("verbose")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                Toggle(isOn: streamingBinding) {
                    Text("流式输出")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("续写后缀")
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textMuted)
                    TextField("", text: continuePostfixBinding)
                        .font(.system(size: Theme.SettingsFont.body))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            Divider().opacity(0.1)

            Text("后处理")
                .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("消息规整")
                        .font(.system(size: Theme.SettingsFont.label))
                        .foregroundColor(Theme.textMuted)
                    Picker("", selection: postProcessingModeBinding) {
                        Text("无").tag("none")
                        Text("合并").tag("merge")
                        Text("严格").tag("strict")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                Toggle(isOn: squashSystemMessagesBinding) {
                    Text("合并连续 System")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted)
                }

                Toggle(isOn: continuePrefillBinding) {
                    Text("续写 Prefill")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted)
                }

                Toggle(isOn: cacheFriendlyBinding) {
                    Text("缓存优化（易变内容下沉）")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    // MARK: Persona — 简单模式（直接绑 slot content，无缓存）

    private func personaSimpleMode(preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            personaSlotField("系统指令", preset: preset, slotId: PromptSlot.mainId,
                            placeholder: "你是一个有帮助的助手...", psm: psm)
            personaSlotField("助手设定", preset: preset, slotId: PromptSlot.charDescriptionId,
                            placeholder: "AI 助手的设定、风格、背景...", psm: psm, height: 60)
            personaSlotField("用户描述", preset: preset, slotId: PromptSlot.personaDescriptionId,
                            placeholder: "我叫天奕，喜欢...", psm: psm)
            personaSlotField("对话示例", preset: preset, slotId: PromptSlot.dialogueExamplesId,
                            placeholder: "{{user}}: 你好\n{{char}}: 你好，今天能帮什么？", psm: psm, height: 50)
            personaSlotField("后置提醒", preset: preset, slotId: PromptSlot.jailbreakId,
                            placeholder: "保持角色设定...", psm: psm)

            Text("修改即时生效，切换模式可看到同步")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
        }
    }

    private func personaSlotField(_ label: String, preset: Preset, slotId: String,
                                   placeholder: String, psm: PresetManager, height: CGFloat = 40) -> some View {
        let binding = Binding<String>(
            get: { preset.prompts.first(where: { $0.id == slotId })?.content ?? "" },
            set: { newValue in
                var p = preset
                if let idx = p.prompts.firstIndex(where: { $0.id == slotId }) {
                    p.prompts[idx].content = newValue
                    psm.save(p)
                }
            }
        )
        return personaTextField(label, text: binding, placeholder: placeholder, height: height)
    }

    private func personaTextField(_ label: String, text: Binding<String>, placeholder: String, height: CGFloat = 40) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: Theme.SettingsFont.body))
                    .frame(height: height)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                        .padding(.leading, 10)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
        }
    }

    // MARK: Persona — 插槽模式

    private func personaSlotsMode(preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt 插槽")
                    .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    var p = preset
                    p.prompts.append(PromptSlot(name: "新插槽", role: "system", isSystemPrompt: false, isEnabled: false, injectionOrder: (preset.prompts.last?.injectionOrder ?? 100) + 10))
                    psm.save(p)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("添加")
                    }
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)

                Button {
                    showPresetImporter = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入 Prompt 预设")
                    }
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(preset.prompts.enumerated()), id: \.element.id) { index, slot in
                // iOS: card style, tap to push edit page
                Button {
                    selectedSlotIndex = index
                } label: {
                    HStack(spacing: 10) {
                        if !slot.isSystemPrompt {
                            Toggle("", isOn: Binding(
                                get: { slot.isEnabled },
                                set: { val in
                                    var p = preset
                                    p.prompts[index].isEnabled = val
                                    psm.save(p)
                                }
                            ))
                            .toggleStyle(.switch)
                            .scaleEffect(0.65)
                            .frame(width: 40)
                            .highPriorityGesture(TapGesture())
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 40)
                        }

                        Text(slot.name)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(slot.isEnabled || slot.isSystemPrompt ? Theme.textPrimary : Theme.textMuted)
                            .lineLimit(1)

                        Text(slot.role)
                            .font(.system(size: Theme.F.badge, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(
                                slot.role == "system" ? Theme.textMuted :
                                slot.role == "user" ? Theme.branchIndicator : .orange
                            ))

                        if slot.isMarker {
                            Text("占位")
                                .font(.system(size: Theme.F.badge))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().stroke(Theme.textMuted, lineWidth: 0.5))
                        }

                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill((slot.isEnabled || slot.isSystemPrompt) ? Theme.assistantBubble : Theme.mainBg.opacity(0.5))
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { selectedSlotIndex = index } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    if !slot.isSystemPrompt && !slot.isMarker {
                        Button(role: .destructive) {
                            var p = preset
                            p.prompts.remove(at: index)
                            psm.save(p)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .modifier(SlotNavigationModifier(
                selectedSlotIndex: $selectedSlotIndex,
                useSheet: useSheetNavigation,
                preset: preset,
                psm: psm
            ))
        }
    }

    // MARK: Persona — Slot Editors

    /// 普通插槽编辑器（名称/role/depth/内容）
    private func slotContentEditor(slot: PromptSlot, index: Int, preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("名称")
                    .font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textMuted)
                    .frame(width: 35, alignment: .trailing)
                TextField("插槽名称", text: Binding(
                    get: { slot.name },
                    set: { val in var p = preset; p.prompts[index].name = val; psm.save(p) }
                ))
                .font(.system(size: Theme.SettingsFont.body)).textFieldStyle(.plain)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
            }

            HStack(spacing: 8) {
                Text("角色")
                    .font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textMuted)
                    .frame(width: 35, alignment: .trailing)
                Picker("", selection: Binding(
                    get: { slot.role },
                    set: { val in var p = preset; p.prompts[index].role = val; psm.save(p) }
                )) {
                    Text("system").tag("system")
                    Text("user").tag("user")
                    Text("assistant").tag("assistant")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 200)
            }

            HStack(spacing: 8) {
                Text("深度")
                    .font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textMuted)
                    .frame(width: 35, alignment: .trailing)
                TextField("0", value: Binding(
                    get: { slot.injectionDepth },
                    set: { val in var p = preset; p.prompts[index].injectionDepth = val; psm.save(p) }
                ), format: .number)
                .font(.system(size: Theme.SettingsFont.body)).textFieldStyle(.plain).frame(width: 40)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
                Text("0=按顺序，>0=从末尾倒数第 N 条插入")
                    .font(.system(size: Theme.SettingsFont.caption)).foregroundColor(Theme.textMuted)
            }

            Text("内容")
                .font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textMuted)
            TextEditor(text: Binding(
                get: { slot.content },
                set: { val in var p = preset; p.prompts[index].content = val; psm.save(p) }
            ))
            .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
            .frame(height: 80).padding(4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
            .scrollContentBackground(.hidden)
        }
    }

    /// Marker 插槽编辑器（直接编辑 slot content，和简单模式同步）
    private func slotMarkerEditor(slot: PromptSlot, index: Int, preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if slot.id == PromptSlot.memoryInjectionId || slot.id == PromptSlot.chatHistoryId {
                Text("此插槽由系统自动填充")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                Text("内容")
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                TextEditor(text: Binding(
                    get: { slot.content },
                    set: { val in var p = preset; p.prompts[index].content = val; psm.save(p) }
                ))
                .font(.system(size: Theme.SettingsFont.body))
                .frame(height: 60).padding(4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.mainBg))
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Persona — 原始模式（JSON 编辑器）

    private func personaRawMode(preset: Preset, psm: PresetManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("JSON 编辑器")
                    .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()

                if rawJSONDirty {
                    Button(action: { applyRawJSON(preset: preset, psm: psm) }) {
                        Text("应用")
                            .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    rawJSONBuffer = preset.toJSONString()
                    rawJSONDirty = false
                    rawJSONError = nil
                }) {
                    Text("重置")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            if let error = rawJSONError {
                Text(error)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
            }

            TextEditor(text: $rawJSONBuffer)
                .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                .frame(minHeight: 300)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                .onChange(of: rawJSONBuffer) { _, _ in
                    rawJSONDirty = true
                    rawJSONError = nil
                }
        }
        .onAppear {
            if rawJSONBuffer.isEmpty || !rawJSONDirty {
                rawJSONBuffer = preset.toJSONString()
                rawJSONDirty = false
            }
        }
    }

    private func applyRawJSON(preset: Preset, psm: PresetManager) {
        do {
            var parsed = try Preset.fromJSONString(rawJSONBuffer)
            parsed.id = preset.id // 保持 ID
            parsed.name = preset.name // 保持名称
            parsed.isBuiltIn = preset.isBuiltIn
            psm.save(parsed)
            rawJSONDirty = false
            rawJSONError = nil
        } catch {
            rawJSONError = "JSON 解析失败: \(error.localizedDescription)"
        }
    }

    // MARK: Persona — Tab 4: 组装预览（后处理前）

    private func personaAssemblyPreview(preset: Preset, profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let store = SwiftDataMemoryStore()
            let memories = store.listHot(profileId: profile.id, context: modelContext)
            let worldBooks = WorldBookStore.fetchBooks(profileId: profile.id, context: modelContext)
            let result = PromptAssembler.assemble(
                preset: preset, profile: profile, memories: memories, chatHistory: [],
                worldBooks: worldBooks
            )
            let tokens = TokenEstimator.estimate(systemPrompt: result.systemPrompt, messages: result.messages)

            // 顶部统计
            HStack {
                Text("组装结果（后处理前）")
                    .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text("≈ \(tokens) tokens")
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    // System Prompt
                    if let sys = result.systemPrompt, !sys.isEmpty {
                        assemblyMessageBlock(role: "system", content: sys)
                    }

                    // Messages
                    ForEach(Array(result.messages.enumerated()), id: \.offset) { _, msg in
                        assemblyMessageBlock(role: msg.role, content: msg.content)
                    }

                    // 对话历史占位
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis.bubble")
                            .font(.system(size: Theme.SettingsFont.caption))
                        Text("对话历史将在这里（深度: \(preset.sampling.contextDepth) 条）")
                            .font(.system(size: Theme.SettingsFont.caption))
                    }
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.textMuted.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
        }
    }

    /// 组装预览里的单条消息块
    private func assemblyMessageBlock(role: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // role 标签
            Text(role.uppercased())
                .font(.system(size: Theme.SettingsFont.mono, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(roleColor(role)))

            // content
            Text(content)
                .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(roleColor(role).opacity(0.06)))
    }

    // MARK: Persona — Tab 5: 最终请求预览（后处理后）

    private func personaRequestPreview(preset: Preset, profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let store = SwiftDataMemoryStore()
            let memories = store.listHot(profileId: profile.id, context: modelContext)
            let worldBooks2 = WorldBookStore.fetchBooks(profileId: profile.id, context: modelContext)
            let assembled = PromptAssembler.assemble(
                preset: preset, profile: profile, memories: memories, chatHistory: [],
                worldBooks: worldBooks2
            )

            // 获取 provider 类型和 model ID
            let providerType = currentProviderType(profile: profile)
            let modelId = currentModelId(profile: profile)

            // 后处理
            let processed = PromptPostProcessor.process(
                systemPrompt: assembled.systemPrompt,
                messages: assembled.messages,
                sampling: preset.sampling,
                providerType: providerType
            )

            // 构建 request body
            let preview = PromptPostProcessor.buildRequestPreview(
                processed: processed,
                model: modelId,
                sampling: preset.sampling,
                providerType: providerType
            )

            // 顶部：provider 类型 + token
            HStack {
                Text("最终请求")
                    .font(.system(size: Theme.SettingsFont.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                Text(providerType == .anthropic ? "Anthropic" : "OpenAI")
                    .font(.system(size: Theme.SettingsFont.mono, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(
                        providerType == .anthropic ? Color.orange : Color.green
                    ))

                Spacer()

                Text("≈ \(preview.tokenEstimate) tokens")
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            // 变换步骤
            if !processed.transforms.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(processed.transforms, id: \.self) { t in
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(.orange)
                            Text(t)
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                .padding(.bottom, 2)
            }

            // JSON 视图
            let jsonString = PromptPostProcessor.prettyJSON(preview.body)

            ScrollView {
                Text(jsonString)
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))

            // 复制按钮
            HStack {
                Spacer()
                Button {
                    UIPasteboard.general.string = jsonString
                } label: {
                    Label("复制 JSON", systemImage: "doc.on.doc")
                        .font(.system(size: Theme.SettingsFont.secondary))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
            }
        }
    }

    // MARK: Persona — 预览辅助

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "system": return .purple
        case "user": return .blue
        case "assistant": return .green
        default: return .gray
        }
    }

    /// 获取当前 profile 选中模型对应的 provider 类型
    private func currentProviderType(profile: Profile) -> ProviderType {
        if let pm = providerManager, let model = pm.model(byId: profile.preferredModel),
           let provider = pm.provider(for: model) {
            return provider.type
        }
        return .openaiCompatible
    }

    /// 获取当前 profile 选中的 model ID
    private func currentModelId(profile: Profile) -> String {
        if let pm = providerManager, let model = pm.model(byId: profile.preferredModel) {
            return model.modelId
        }
        return profile.preferredModel
    }
}

// MARK: - iOS Prompt Page

extension PersonaSettingsTab {

    var iOSPersonaEditModeSelection: Binding<String> {
        Binding(
            get: { personaEditMode.isEmpty ? "simple" : personaEditMode },
            set: { personaEditMode = $0 }
        )
    }

    var iOSPromptPage: some View {
        Group {
            if let pm = profileManager, let psm = presetManager {
                let profile = pm.currentProfile
                let preset = psm.preset(byId: profile.presetId) ?? Preset.balanced

                iOSPromptPageContent(profile: profile, preset: preset, pm: pm, psm: psm)
                    .onAppear {
                        syncIOSSimpleDrafts(from: preset, force: true)
                    }
                    .onChange(of: profile.presetId) { _, newPresetId in
                        let latestPreset = psm.preset(byId: newPresetId) ?? preset
                        syncIOSSimpleDrafts(from: latestPreset, force: true)
                    }
                    .onChange(of: personaEditMode) { _, newMode in
                        if newMode == "simple" || newMode.isEmpty {
                            let latestPreset = psm.preset(byId: profile.presetId) ?? preset
                            syncIOSSimpleDrafts(from: latestPreset, force: true)
                        } else {
                            flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                            iOSSimpleVisibilityTask?.cancel()
                            iOSSimpleVisibilityTask = nil
                            iOSSimpleFocusedSlotId = nil
                        }
                    }
                    .onDisappear {
                        flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                        iOSSimpleVisibilityTask?.cancel()
                        iOSSimpleVisibilityTask = nil
                    }
                    .modifier(SlotNavigationModifier(
                        selectedSlotIndex: $selectedSlotIndex,
                        useSheet: useSheetNavigation,
                        presetManager: presetManager,
                        profileManager: profileManager
                    ))
            }
        }
        .navigationTitle("Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showFullEditor) {
            VStack(spacing: 0) {
                HStack {
                    Button("取消") { showFullEditor = false }
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Text(fullEditLabel)
                        .font(.system(size: Theme.F.label, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Button("完成") {
                        if let slotId = fullEditSlotId,
                           let psm = presetManager,
                           let pm = profileManager {
                            let profile = pm.currentProfile
                            applyIOSSimpleDraft(slotId: slotId, text: fullEditText, presetId: profile.presetId)
                            persistIOSSimpleDrafts(presetId: profile.presetId, psm: psm)
                        }
                        showFullEditor = false
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.2)

                TextEditor(text: $fullEditText)
                    .font(.system(size: Theme.F.body))
                    .padding(12)
                    .scrollContentBackground(.hidden)
            }
            .background(Theme.sidebarBg)
        }
        .sheet(isPresented: $showPresetImporter) {
            DocumentPickerView(contentTypes: [.json]) { urls in
                showPresetImporter = false
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                handlePresetImport(.success(url))
            } onCancel: {
                showPresetImporter = false
            }
        }
    }

    @ViewBuilder
    func iOSPromptPageContent(profile: Profile, preset: Preset, pm: ProfileManager, psm: PresetManager) -> some View {
        let isSimple = personaEditMode == "simple" || personaEditMode.isEmpty

        ScrollViewReader { proxy in
            List {
                // ── 共享：预设 ──
                Section("预设") {
                    iOSPromptPresetSectionContent(profile: profile, preset: preset, pm: pm, psm: psm)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // ── 共享：模式选择器 ──
                Section {
                    iOSPromptModePicker
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // ── 内容按模式切换 ──
                if isSimple {
                    iOSSimpleFieldsSections(preset: preset, psm: psm)
                } else if personaEditMode == "slots" {
                    iOSSlotsSection(preset: preset, profile: profile, pm: pm, psm: psm)
                } else {
                    // raw / assembly / request
                    if personaEditMode == "raw" {
                        Section {
                            DisclosureGroup(isExpanded: $samplingExpanded) {
                                personaSamplingSection(preset: preset, profile: profile, pm: pm, psm: psm)
                            } label: {
                                Text("采样参数")
                                    .font(.system(size: Theme.F.body, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                            }
                        }
                        .listRowBackground(Theme.mainBg)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        switch personaEditMode {
                        case "raw":
                            personaRawMode(preset: preset, psm: psm)
                        case "assembly":
                            personaAssemblyPreview(preset: preset, profile: profile)
                        case "request":
                            personaRequestPreview(preset: preset, profile: profile)
                        default:
                            EmptyView()
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: iOSSimpleScrollRequest) { _, _ in
                guard isSimple, let target = iOSSimpleFocusedSlotId else { return }
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                guard isSimple, let target = iOSSimpleFocusedSlotId else { return }
                requestIOSSimpleFieldVisibility(target, delay: 120_000_000)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                guard isSimple else { return }
                iOSSimpleVisibilityTask?.cancel()
                iOSSimpleVisibilityTask = nil
            }
        }
    }

    // MARK: - 简单模式字段（List sections）

    @ViewBuilder
    func iOSSimpleFieldsSections(preset: Preset, psm: PresetManager) -> some View {
        Section {
            ForEach(Self.iOSSimplePromptFields) { field in
                iOSSimpleField(
                    field.label,
                    preset: preset,
                    slotId: field.slotId,
                    placeholder: field.placeholder,
                    psm: psm,
                    onBeganEditing: {
                        requestIOSSimpleFieldVisibility(field.slotId)
                    },
                    onEndedEditing: {
                        clearIOSSimpleFieldFocus(field.slotId)
                    },
                    onHeightChange: { _ in
                        guard iOSSimpleFocusedSlotId == field.slotId else { return }
                        requestIOSSimpleFieldVisibility(field.slotId)
                    }
                )
                .id(field.slotId)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)
            }

            Text("修改即时生效，切换模式可看到同步")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .listRowSeparator(.hidden)
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - 插槽模式内容（List sections）

    @ViewBuilder
    func iOSSlotsSection(preset: Preset, profile: Profile, pm: ProfileManager, psm: PresetManager) -> some View {
        Section {
            DisclosureGroup(isExpanded: $samplingExpanded) {
                personaSamplingSection(preset: preset, profile: profile, pm: pm, psm: psm)
            } label: {
                Text("采样参数")
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section {
            ForEach(Array(preset.prompts.enumerated()), id: \.element.id) { index, slot in
                Button { selectedSlotIndex = index } label: {
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { slot.isEnabled },
                            set: { val in
                                var p = preset
                                p.prompts[index].isEnabled = val
                                psm.save(p)
                            }
                        ))
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                        .frame(width: 40)
                        .highPriorityGesture(TapGesture())

                        Text(slot.name)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(slot.isEnabled || slot.isSystemPrompt ? Theme.textPrimary : Theme.textMuted)
                            .lineLimit(1)

                        Text(slot.role)
                            .font(.system(size: Theme.F.badge, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(
                                slot.role == "system" ? Theme.textMuted :
                                slot.role == "user" ? Theme.branchIndicator : .orange
                            ))

                        if slot.isMarker {
                            Text("占位")
                                .font(.system(size: Theme.F.badge))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().stroke(Theme.textMuted, lineWidth: 0.5))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !slot.isSystemPrompt && !slot.isMarker {
                        Button(role: .destructive) {
                            var p = preset
                            p.prompts.remove(at: index)
                            psm.save(p)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    Button { selectedSlotIndex = index } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(Theme.branchIndicator)
                }
            }
            .onMove { from, to in
                var p = preset
                p.prompts.move(fromOffsets: from, toOffset: to)
                for i in p.prompts.indices { p.prompts[i].injectionOrder = i * 10 }
                psm.save(p)
            }
        } header: {
            HStack {
                Text("Prompt 插槽")
                Spacer()
                Button {
                    var p = preset
                    p.prompts.append(PromptSlot(name: "新插槽", role: "system", isSystemPrompt: false, isEnabled: false, injectionOrder: (preset.prompts.last?.injectionOrder ?? 100) + 10))
                    psm.save(p)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    func iOSPromptPresetSectionContent(profile: Profile, preset: Preset, pm: ProfileManager, psm: PresetManager) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { profile.presetId },
                set: { newId in
                    flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                    var p = profile
                    p.presetId = newId
                    pm.updateProfile(p)
                }
            )) {
                ForEach(psm.allPresets) { pr in
                    Text(pr.name).tag(pr.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.branchIndicator)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                    let latestPreset = psm.preset(byId: profile.presetId) ?? preset
                    let copy = psm.duplicate(latestPreset)
                    var p = profile
                    p.presetId = copy.id
                    pm.updateProfile(p)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    flushIOSSimpleDraftSave(presetId: profile.presetId, psm: psm)
                    exportPreset(psm.preset(byId: profile.presetId) ?? preset)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Button { showPresetImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)

                if !preset.isBuiltIn {
                    Button {
                        let fallbackId = Preset.balanced.id
                        psm.delete(preset)
                        var p = profile
                        p.presetId = fallbackId
                        pm.updateProfile(p)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 18))
                            .foregroundColor(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var iOSPromptModePicker: some View {
        Picker("", selection: iOSPersonaEditModeSelection) {
            Text("简单").tag("simple")
            Text("插槽").tag("slots")
            Text("JSON").tag("raw")
            Text("组装").tag("assembly")
            Text("请求").tag("request")
        }
        .pickerStyle(.segmented)
        .tint(Theme.branchIndicator)
    }

    func iOSPromptCard<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.mainBg)
        )
    }

    func requestIOSSimpleFieldVisibility(_ slotId: String, delay: UInt64 = 0) {
        iOSSimpleFocusedSlotId = slotId
        iOSSimpleVisibilityTask?.cancel()
        iOSSimpleVisibilityTask = Task { @MainActor [slotId] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            guard iOSSimpleFocusedSlotId == slotId else { return }
            iOSSimpleScrollRequest += 1
        }
    }

    func clearIOSSimpleFieldFocus(_ slotId: String) {
        guard iOSSimpleFocusedSlotId == slotId else { return }
        iOSSimpleVisibilityTask?.cancel()
        iOSSimpleVisibilityTask = nil
        iOSSimpleFocusedSlotId = nil
    }

    @ViewBuilder
    func iOSSimpleField(
        _ label: String,
        preset: Preset,
        slotId: String,
        placeholder: String,
        psm: PresetManager,
        onBeganEditing: @escaping () -> Void = {},
        onEndedEditing: @escaping () -> Void = {},
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) -> some View {
        let binding = iOSSimpleBinding(for: slotId, preset: preset, psm: psm)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    fullEditLabel = label
                    fullEditText = binding.wrappedValue
                    fullEditSlotId = slotId
                    showFullEditor = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            IOSPromptTextView(
                text: binding,
                placeholder: placeholder,
                onBeganEditing: onBeganEditing,
                onEndedEditing: onEndedEditing,
                onHeightChange: onHeightChange
            )
        }
        .id(slotId)
    }

    func iOSSimpleBinding(for slotId: String, preset: Preset, psm: PresetManager) -> Binding<String> {
        Binding(
            get: {
                if iOSSimpleDraftPresetId == preset.id {
                    return iOSSimpleDrafts[slotId] ?? preset.prompts.first(where: { $0.id == slotId })?.content ?? ""
                }
                return preset.prompts.first(where: { $0.id == slotId })?.content ?? ""
            },
            set: { newValue in
                if iOSSimpleDraftPresetId != preset.id {
                    syncIOSSimpleDrafts(from: preset, force: true)
                }
                applyIOSSimpleDraft(slotId: slotId, text: newValue, presetId: preset.id)
                scheduleIOSSimpleDraftSave(presetId: preset.id, psm: psm)
            }
        )
    }

    func syncIOSSimpleDrafts(from preset: Preset, force: Bool = false) {
        if !force, iOSSimpleDraftPresetId == preset.id, !iOSSimpleDrafts.isEmpty {
            return
        }
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = nil
        iOSSimpleDraftPresetId = preset.id
        iOSSimpleDrafts = iOSSimpleDraftSnapshot(from: preset)
    }

    func applyIOSSimpleDraft(slotId: String, text: String, presetId: String) {
        if iOSSimpleDraftPresetId != presetId {
            iOSSimpleDraftPresetId = presetId
        }
        iOSSimpleDrafts[slotId] = text
    }

    func scheduleIOSSimpleDraftSave(presetId: String, psm: PresetManager) {
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = Task { @MainActor [presetId, psm] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            persistIOSSimpleDrafts(presetId: presetId, psm: psm)
        }
    }

    func flushIOSSimpleDraftSave(presetId: String, psm: PresetManager) {
        iOSSimpleSaveTask?.cancel()
        iOSSimpleSaveTask = nil
        persistIOSSimpleDrafts(presetId: presetId, psm: psm)
    }

    func persistIOSSimpleDrafts(presetId: String, psm: PresetManager) {
        guard iOSSimpleDraftPresetId == presetId else { return }
        guard var preset = psm.preset(byId: presetId) else { return }

        var didChange = false
        for slotId in Self.iOSSimplePromptSlotIds {
            guard let text = iOSSimpleDrafts[slotId],
                  let idx = preset.prompts.firstIndex(where: { $0.id == slotId }),
                  preset.prompts[idx].content != text else {
                continue
            }
            preset.prompts[idx].content = text
            didChange = true
        }

        if didChange {
            psm.save(preset)
        }
    }

    func iOSSimpleDraftSnapshot(from preset: Preset) -> [String: String] {
        var snapshot: [String: String] = [:]
        for slotId in Self.iOSSimplePromptSlotIds {
            snapshot[slotId] = preset.prompts.first(where: { $0.id == slotId })?.content ?? ""
        }
        return snapshot
    }
}
