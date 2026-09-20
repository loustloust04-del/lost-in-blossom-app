import SwiftUI
import SwiftData

/// iOS 贴纸面板 — 工具栏胶囊 + 玻璃卡片（像键盘一样贴底）
struct StickerKeyboardPanel: View {
    var stickerVM: StickerViewModel
    var viewModel: ConversationViewModel
    var showCard: Bool = true
    var onDismiss: () -> Void
    var onStickerTap: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var showNoteEditor = false
    @State private var showDrawingBoard = false
    @State private var panelHeight: CGFloat = 260
    @State private var dragOffset: CGFloat = 0

    private let minHeight: CGFloat = 160
    private let maxHeight: CGFloat = 420

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        VStack(spacing: 12) {
            // 工具栏（和输入框同款 rect 玻璃）
            HStack(spacing: 0) {
                // 键盘按钮（左侧）
                Button(action: onDismiss) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                toolButton("star.circle.fill", isActive: showCard) { onStickerTap?() }
                toolButton("note.text.badge.plus") { showNoteEditor = true }
                toolButton("paintbrush.pointed") { showDrawingBoard = true }
                Spacer()

                // 编辑模式：完成按钮（右侧）
                if stickerVM.isEditingStickers {
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            stickerVM.isEditingStickers = false
                            stickerVM.selectedPlacedStickerId = nil
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("完成")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 4)
            .glassEffectCompat(tint: Color.black.opacity(0.01), interactive: true, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)

            // 玻璃卡片（像键盘贴底，顶部圆角底部直角，延伸到屏幕底边）
            // 始终在 layout 里，用高度动画收起（避免 if 移除导致工具栏穿模跳动）
            VStack(spacing: 0) {
                // 拖拽条（真的可拖）
                Capsule()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation.height
                            }
                            .onEnded { value in
                                panelHeight = max(minHeight, min(maxHeight, panelHeight - dragOffset))
                                dragOffset = 0
                            }
                    )

                // 贴纸网格
                if stickerVM.stickerAssets.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "star.circle")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textMuted.opacity(0.3))
                        Text("还没有贴纸")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(stickerVM.stickerAssets, id: \.id) { asset in
                                PanelStickerCell(asset: asset, profileId: profileManager?.currentProfile.id ?? "")
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                }
            }
            .frame(height: showCard ? max(minHeight, min(maxHeight, panelHeight - dragOffset)) : 0)
            .frame(maxWidth: .infinity)
            .clipped()
            .opacity(showCard ? 1 : 0)
            .background {
                if showCard {
                    // glass 放 background 闭包里 + ignoresSafeArea → 延伸到屏幕底边
                    Color.clear
                        .glassEffectCompat(tint: Color.black.opacity(0.01), interactive: true,
                                           in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 16, topTrailing: 16)))
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
        }
        .onAppear {
            if let pid = profileManager?.currentProfile.id {
                stickerVM.loadLibrary(profileId: pid, context: modelContext)
            }
        }
        .sheet(isPresented: $showNoteEditor) {
            if let pid = profileManager?.currentProfile.id {
                NoteStickerEditor { text, style in
                    stickerVM.createNoteAsset(content: text, style: style.rawValue, profileId: pid, context: modelContext)
                }
            }
        }
        .sheet(isPresented: $showDrawingBoard) {
            if let pid = profileManager?.currentProfile.id {
                DrawingBoardSheet { pngData in
                    stickerVM.addDrawingAsset(pngData: pngData, name: "画画", profileId: pid, context: modelContext)
                }
            }
        }
    }

    private func toolButton(_ icon: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isActive ? Theme.branchIndicator : Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Panel Sticker Cell（可拖拽）

struct PanelStickerCell: View {
    let asset: StickerAsset
    let profileId: String
    @State private var image: Image?

    var body: some View {
        Group {
            if asset.isNote {
                Text(asset.noteContent ?? "")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .padding(5)
                    .frame(maxWidth: .infinity, minHeight: 55)
                    .background(RoundedRectangle(cornerRadius: 4).fill(noteColor))
            } else if let img = image {
                img.resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 65)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.15))
                    .frame(height: 55)
                    .overlay(ProgressView().scaleEffect(0.4))
            }
        }
        .onDrag { NSItemProvider(object: asset.id.uuidString as NSString) }
        .task {
            guard !asset.isNote, image == nil else { return }
            if let data = StickerFileManager.loadImageCached(path: asset.thumbnailPath, profileId: profileId),
               let uiImage = UIImage(data: data) {
                image = Image(uiImage: uiImage)
            }
        }
    }

    private var noteColor: Color {
        switch asset.noteStyle {
        case "pink_rounded": return Color(red: 1, green: 0.85, blue: 0.88)
        case "glass": return Color.gray.opacity(0.3)
        case "torn_paper": return Color.white.opacity(0.9)
        default: return Color(red: 1, green: 0.96, blue: 0.75)
        }
    }
}
