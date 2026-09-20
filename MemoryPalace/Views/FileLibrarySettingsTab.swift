import SwiftUI

// MARK: - 文件库设置（注入提示词模板可编辑）

struct FileLibrarySettingsTab: View {
    @AppStorage("fileLibraryInjectionTemplate") private var template = ""

    var body: some View {
        #if os(iOS)
        ScrollView { content }
            .background(Theme.sidebarBg)
            .navigationTitle("文件库")
            .navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("注入提示词模板")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            TextEditor(text: $template)
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .frame(minHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                .scrollContentBackground(.hidden)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.5), lineWidth: 0.5))

            if !template.isEmpty {
                Button("恢复默认") { template = "" }
                    .foregroundColor(.red.opacity(0.7))
                    .font(.system(size: Theme.F.secondary))
                    .buttonStyle(.plain)
            }

            Text("留空使用默认模板。占位符：{{files}}（文件清单）、{{fileContents}}（本对话涉及文件的当前最终内容）。系统会自动用 <文件库>…</文件库> 包裹整段。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
