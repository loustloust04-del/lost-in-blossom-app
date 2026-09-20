import SwiftUI

/// 贴纸编辑模式工具栏 — 替换 ChatInputBar
/// macOS Dock 风格毛玻璃胶囊
struct StickerToolbar: View {
    var stickerVM: StickerViewModel
    var viewModel: ConversationViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var showNoteEditor = false
    @State private var showDrawingBoard = false

    var body: some View {
        HStack(spacing: 0) {
            // 功能工具组
            HStack(spacing: 4) {
                toolButton("cursorarrow", label: "选择", isActive: true) {
                    // 默认模式，已激活
                }

                toolButton("star.circle", label: "贴纸库") {
                    NotificationCenter.default.post(name: .showStickerLibrary, object: nil)
                }

                toolButton("note.text.badge.plus", label: "便签") {
                    showNoteEditor = true
                }

                toolButton("paintbrush.pointed", label: "画画") {
                    showDrawingBoard = true
                }
            }

            // 分隔线
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 8)

            // 完成按钮
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    stickerVM.isEditingStickers = false
                    stickerVM.selectedPlacedStickerId = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("完成")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.branchIndicator))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.15), lineWidth: 0.5)
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showNoteEditor) {
            if let pid = profileManager?.currentProfile.id {
                NoteStickerEditor { text, style in
                    stickerVM.createNoteAsset(
                        content: text,
                        style: style.rawValue,
                        profileId: pid,
                        context: modelContext
                    )
                }
            }
        }
        .sheet(isPresented: $showDrawingBoard) {
            if let pid = profileManager?.currentProfile.id {
                DrawingBoardSheet { pngData in
                    saveDrawing(pngData: pngData, profileId: pid)
                }
            }
        }
    }

    private func saveDrawing(pngData: Data, profileId: String) {
        let name = "画画 \(Date().formatted(.dateTime.hour().minute()))"
        stickerVM.addDrawingAsset(pngData: pngData, name: name, profileId: profileId, context: modelContext)
    }

    private func toolButton(_ icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isActive ? Theme.branchIndicator.opacity(0.2) : .clear)
                )
                .foregroundColor(isActive ? Theme.branchIndicator : Theme.textPrimary)
                .help(label)
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let showStickerLibrary = Notification.Name("showStickerLibrary")
}
