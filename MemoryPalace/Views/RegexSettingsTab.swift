import SwiftUI
import SwiftData

// MARK: - iOS Regex Page

struct IOSRegexPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var editingRegex: RegexScript?
    @State private var isAddingRegex = false
    @State private var regexRefreshId = UUID()

    var body: some View {
        let scripts = profileManager?.currentProfile.regexScripts ?? []

        List {
            if scripts.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "textformat.abc")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                        Text("没有正则脚本")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textMuted)
                        Text("导入助手模板时会自动导入，也可手动新建")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            } else {
                Section("脚本列表") {
                    ForEach(Array(scripts.enumerated()), id: \.element.id) { index, script in
                        Button {
                            isAddingRegex = false
                            editingRegex = script
                        } label: {
                            HStack(spacing: 10) {
                                // Toggle
                                Toggle("", isOn: Binding(
                                    get: { !script.disabled },
                                    set: { enabled in
                                        var s = profileManager?.currentProfile.regexScripts ?? []
                                        guard index < s.count else { return }
                                        s[index].disabled = !enabled
                                        profileManager?.currentProfile.regexScripts = s
                                        if let profile = profileManager?.currentProfile {
                                            profileManager?.updateProfile(profile)
                                        }
                                        regexRefreshId = UUID()
                                    }
                                ))
                                .toggleStyle(.switch)
                                .scaleEffect(0.65)
                                .frame(width: 40)
                                .highPriorityGesture(TapGesture())

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(script.scriptName.isEmpty ? "未命名" : script.scriptName)
                                        .font(.system(size: Theme.F.body, weight: .medium))
                                        .foregroundColor(script.disabled ? Theme.textMuted : Theme.textPrimary)

                                    HStack(spacing: 4) {
                                        if script.markdownOnly {
                                            Text("渲染")
                                                .font(.system(size: Theme.F.badge, weight: .semibold))
                                                .foregroundColor(Theme.branchIndicator)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                                        }
                                        if script.promptOnly {
                                            Text("API")
                                                .font(.system(size: Theme.F.badge, weight: .semibold))
                                                .foregroundColor(Theme.branchIndicator)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                                        }
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteRegexScript(at: index)
                                regexRefreshId = UUID()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                isAddingRegex = false
                                editingRegex = script
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(Theme.branchIndicator)
                        }
                    }
                }
                .listRowBackground(Theme.mainBg)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("正则脚本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingRegex = true
                    editingRegex = RegexScript()
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .sheet(item: $editingRegex) { script in
            RegexScriptEditor(
                script: script,
                isNew: isAddingRegex,
                onSave: { updated in
                    saveRegexScript(updated)
                    editingRegex = nil
                    regexRefreshId = UUID()
                },
                onCancel: { editingRegex = nil }
            )
        }
        .id(regexRefreshId)
    }

    private func saveRegexScript(_ script: RegexScript) {
        guard var profile = profileManager?.currentProfile else { return }
        var scripts = profile.regexScripts
        if isAddingRegex {
            scripts.append(script)
        } else if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[idx] = script
        }
        profile.regexScripts = scripts
        profileManager?.updateProfile(profile)
    }

    private func deleteRegexScript(at index: Int) {
        guard var profile = profileManager?.currentProfile else { return }
        var scripts = profile.regexScripts
        guard index < scripts.count else { return }
        scripts.remove(at: index)
        profile.regexScripts = scripts
        profileManager?.updateProfile(profile)
    }
}
