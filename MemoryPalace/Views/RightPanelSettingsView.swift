import SwiftUI

// MARK: - iOS 右栏设置页

struct IOSRightPanelPage: View {
    @Environment(RightPanelToolManager.self) private var toolManager: RightPanelToolManager?

    var body: some View {
        List {
            Section("工具管理") {
                if let tm = toolManager {
                    ForEach(tm.allToolsSorted) { tool in
                        HStack(spacing: 12) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 16))
                                .foregroundColor(tool.isEnabled ? Theme.textSecondary : Theme.textMuted)
                                .frame(width: 28)

                            Text(tool.name)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(tool.isEnabled ? Theme.textPrimary : Theme.textMuted)

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { tool.isEnabled },
                                set: { tm.setEnabled(tool.id, $0) }
                            ))
                            .tint(Theme.branchIndicator)
                            .labelsHidden()
                        }
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                Text("关闭的工具不会出现在右栏工具栏和抽屉中。未来可在此管理插件。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("右栏")
        .navigationBarTitleDisplayMode(.inline)
    }
}
