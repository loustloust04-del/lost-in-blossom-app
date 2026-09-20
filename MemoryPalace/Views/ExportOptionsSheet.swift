import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportOptionsSheet: View {
    let conversation: Conversation
    var viewModel: ConversationViewModel
    let userName: String
    let assistantName: String
    /// 导出成功后把文件 URL 交给父视图，由它在本 sheet 关闭后呈现分享面板。
    var onExported: (URL) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ExportPathMode = .longest

    /// Whether the conversation is currently loaded in the ViewModel
    private var isConversationLoaded: Bool {
        viewModel.selectedConversation?.id == conversation.id && !viewModel.currentPath.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("导出选项")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Text(conversation.title)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)

            VStack(spacing: 4) {
                exportOption(
                    title: "最长分支",
                    description: "自动选择最长的对话路径",
                    mode: .longest
                )

                if isConversationLoaded {
                    exportOption(
                        title: "当前显示路径",
                        description: "导出当前正在查看的路径",
                        mode: .current
                    )
                }

                exportOption(
                    title: "主路径",
                    description: "导出 ChatGPT 默认的主路径",
                    mode: .mainPath
                )

                exportOption(
                    title: "完整树",
                    description: "所有分支，非主线用折叠显示",
                    mode: .fullTree
                )
            }

            HStack {
                Button("取消") { dismiss() }
                    .foregroundColor(Theme.textMuted)
                    .buttonStyle(.plain)

                Spacer()

                Button(action: { performExport() }) {
                    Text("导出")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Theme.branchIndicator)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func exportOption(title: String, description: String, mode: ExportPathMode) -> some View {
        Button(action: { selectedMode = mode }) {
            HStack(spacing: 8) {
                Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(selectedMode == mode ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                    Text(description)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedMode == mode ? Theme.accent.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func performExport() {
        let markdown: String

        if selectedMode == .current && isConversationLoaded {
            // Use ViewModel's loaded data for current path
            markdown = viewModel.exportMarkdown(
                mode: .current,
                userName: userName,
                assistantName: assistantName
            )
        } else if (selectedMode == .mainPath || selectedMode == .longest || selectedMode == .fullTree) && isConversationLoaded {
            // Can use ViewModel data for these too
            markdown = viewModel.exportMarkdown(
                mode: selectedMode,
                userName: userName,
                assistantName: assistantName
            )
        } else {
            // Load from context (conversation not displayed)
            markdown = MarkdownExporter.loadAndExport(
                conversation: conversation,
                context: modelContext,
                mode: selectedMode,
                userName: userName,
                assistantName: assistantName
            )
        }

        // 写临时 .md，然后弹系统分享面板（存文件/隔空投送/发给自己…）
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(MarkdownExporter.sanitizedFileName(conversation.title)).md")
        do {
            try markdown.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            ToastCenter.shared.show("导出失败：\(error.localizedDescription)")
            dismiss()
            return
        }
        // 交棒给父视图（SidebarView）：它在本 sheet 关闭后用 SwiftUI 原生 .sheet 呈现分享
        // 面板。不再手动 connectedScenes.first + present——那套无序取 scene，在本 App 上
        // 贴纸/导出分享都弹不出来（真机确诊：贴纸也弹不出）。
        onExported(tmpURL)
        dismiss()
    }
}

/// 系统分享面板的 SwiftUI 包装——用 .sheet 呈现，由 SwiftUI 管理，不手动找 window/VC。
struct ExportActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 待分享的导出文件（Identifiable 供 .sheet(item:)）。
struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
