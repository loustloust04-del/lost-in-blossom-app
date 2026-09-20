// 从 PersonaSettingsTab.swift 拆出：参数行 / Slot 编辑页 / 自增长文本编辑器 / Slot 导航修饰器

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit


// MARK: - Parameter Row

struct ParameterRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var format: String = "%.1f"
    var intMode: Bool = false

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    editText = intMode ? "\(Int(value))" : String(format: format, value)
                    isEditing = true
                } label: {
                    Text(intMode ? "\(Int(value))" : String(format: format, value))
                        .font(.system(size: Theme.F.secondary, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }

            Slider(value: $value, in: range, step: step)
                .tint(Theme.branchIndicator)
        }
        .alert("输入数值", isPresented: $isEditing) {
            TextField("", text: $editText)
                .keyboardType(intMode ? .numberPad : .decimalPad)
            Button("确定") {
                if let v = Double(editText) {
                    value = min(max(v, range.lowerBound), range.upperBound)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - Slot Edit Page (iOS)

struct SlotEditPage: View {
    let slot: PromptSlot
    let index: Int
    let preset: Preset
    let psm: PresetManager

    @State private var editName: String = ""
    @State private var editRole: String = ""
    @State private var editContent: String = ""
    @State private var editDepth: String = ""

    var body: some View {
        List {
            Section("基本") {
                HStack {
                    Text("名称")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                    TextField("插槽名称", text: $editName)
                        .font(.system(size: Theme.F.body))
                        .multilineTextAlignment(.trailing)
                        .onChange(of: editName) { _, val in
                            var p = preset
                            p.prompts[index].name = val
                            psm.save(p)
                        }
                }

                Picker("角色", selection: Binding(
                    get: { editRole },
                    set: { val in
                        editRole = val
                        var p = preset
                        p.prompts[index].role = val
                        psm.save(p)
                    }
                )) {
                    Text("system").tag("system")
                    Text("user").tag("user")
                    Text("assistant").tag("assistant")
                }
                .font(.system(size: Theme.F.body))
                .tint(Theme.branchIndicator)

                if !slot.isMarker {
                    HStack {
                        Text("注入深度")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("0=按顺序", text: $editDepth)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .onChange(of: editDepth) { _, val in
                                var p = preset
                                p.prompts[index].injectionDepth = Int(val) ?? 0
                                psm.save(p)
                            }
                    }
                }
            }
            .listRowBackground(Theme.mainBg)

            Section("内容") {
                if slot.isMarker {
                    Text("此插槽为占位符，内容由 Profile 对应字段填充")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                } else {
                    TextEditor(text: $editContent)
                        .font(.system(size: Theme.F.body))
                        .frame(minHeight: 300)
                        .scrollContentBackground(.hidden)
                        .onChange(of: editContent) { _, val in
                            var p = preset
                            p.prompts[index].content = val
                            psm.save(p)
                        }
                }
            }
            .listRowBackground(Theme.mainBg)

            if !slot.isSystemPrompt && !slot.isMarker {
                Section {
                    Button(role: .destructive) {
                        var p = preset
                        p.prompts.remove(at: index)
                        psm.save(p)
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除此插槽")
                        }
                        .font(.system(size: Theme.F.body))
                        .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Theme.danger.opacity(0.1))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle(slot.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editName = slot.name
            editRole = slot.role
            editContent = slot.content
            editDepth = "\(slot.injectionDepth)"
        }
    }
}

// MARK: - Slot Navigation Modifier（push vs sheet 切换）

/// 右栏用 sheet 弹出插槽编辑，设置页用 navigationDestination push
struct SlotNavigationModifier: ViewModifier {
    @Binding var selectedSlotIndex: Int?
    let useSheet: Bool

    // 两种初始化：直接传 preset 或从 environment 读
    var preset: Preset?
    var psm: PresetManager?
    var presetManager: PresetManager?
    var profileManager: ProfileManager?

    init(selectedSlotIndex: Binding<Int?>, useSheet: Bool, preset: Preset, psm: PresetManager) {
        self._selectedSlotIndex = selectedSlotIndex
        self.useSheet = useSheet
        self.preset = preset
        self.psm = psm
    }

    init(selectedSlotIndex: Binding<Int?>, useSheet: Bool, presetManager: PresetManager?, profileManager: ProfileManager?) {
        self._selectedSlotIndex = selectedSlotIndex
        self.useSheet = useSheet
        self.presetManager = presetManager
        self.profileManager = profileManager
    }

    private var resolvedPreset: Preset? {
        if let preset { return preset }
        guard let psm = presetManager, let pm = profileManager else { return nil }
        return psm.preset(byId: pm.currentProfile.presetId) ?? Preset.balanced
    }

    private var resolvedPsm: PresetManager? {
        psm ?? presetManager
    }

    func body(content: Content) -> some View {
        if useSheet {
            content
                .sheet(isPresented: Binding(
                    get: { selectedSlotIndex != nil },
                    set: { if !$0 { selectedSlotIndex = nil } }
                )) {
                    if let idx = selectedSlotIndex,
                       let preset = resolvedPreset, let psm = resolvedPsm,
                       idx < preset.prompts.count {
                        NavigationStack {
                            SlotEditPage(slot: preset.prompts[idx], index: idx, preset: preset, psm: psm)
                        }
                    }
                }
        } else {
            content
                .navigationDestination(item: $selectedSlotIndex) { idx in
                    if let preset = resolvedPreset, let psm = resolvedPsm, idx < preset.prompts.count {
                        SlotEditPage(slot: preset.prompts[idx], index: idx, preset: preset, psm: psm)
                    }
                }
        }
    }
}
