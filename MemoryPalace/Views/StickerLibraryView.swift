import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 右栏贴纸库 Gallery
struct StickerLibraryView: View {
    var viewModel: ConversationViewModel
    var stickerVM: StickerViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var showImportSheet = false
    @State private var showNoteEditor = false
    @State private var showDrawingBoard = false
    @State private var editingStyleAsset: StickerAsset?
    @State private var searchText = ""
    @State private var hasAppeared = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private var filteredAssets: [StickerAsset] {
        let assets = stickerVM.stickerAssets
        guard !searchText.isEmpty else { return assets }
        let query = searchText.lowercased()
        return assets.filter {
            $0.name.lowercased().contains(query) ||
            $0.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：搜索 + 操作按钮
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                    TextField("搜索贴纸...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.mainBg.opacity(0.6))
                )

                stickerActionButton("photo.badge.plus") { showImportSheet = true }
                stickerActionButton("note.text.badge.plus") { showNoteEditor = true }
                stickerActionButton("paintbrush.pointed") { showDrawingBoard = true }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if filteredAssets.isEmpty {
                emptyState
            } else {
                // Gallery 网格
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(filteredAssets.enumerated()), id: \.element.id) { index, asset in
                            Group {
                                if asset.isNote {
                                    NoteThumbnailView(
                                        asset: asset,
                                        index: index,
                                        hasAppeared: hasAppeared
                                    )
                                } else {
                                    StickerThumbnailView(
                                        asset: asset,
                                        profileId: profileManager?.currentProfile.id ?? "",
                                        index: index,
                                        hasAppeared: hasAppeared
                                    )
                                }
                            }
                            .onTapGesture {
                                placeStickerFromTap(asset: asset)
                            }
                            .contextMenu {
                                Button { placeStickerFromTap(asset: asset) } label: {
                                    Label("添加到对话", systemImage: "plus.circle")
                                }
                                Divider()
                                Button(action: { renameSticker(asset) }) {
                                    Label("重命名", systemImage: "pencil")
                                }
                                if asset.isNote {
                                    Button {
                                        stickerVM.shareNoteAsPNG(content: asset.noteContent ?? "", style: asset.noteStyle ?? "yellow_square")
                                    } label: {
                                        Label("导出为图片", systemImage: "square.and.arrow.up")
                                    }
                                } else {
                                    Button { editingStyleAsset = asset } label: {
                                        Label("修改样式", systemImage: "paintbrush")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    stickerVM.deleteAsset(asset, context: modelContext)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if let pid = profileManager?.currentProfile.id {
                stickerVM.loadLibrary(profileId: pid, context: modelContext)
            }
            // 触发飘入动画
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    hasAppeared = true
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            if let pid = profileManager?.currentProfile.id {
                StickerImportSheet(profileId: pid, stickerVM: stickerVM)
            }
        }
        .sheet(isPresented: $showNoteEditor) {
            NoteStickerEditor { text, style in
                // 便签存入贴纸库（不直接贴画布，用户从库里拖）
                guard let pid = profileManager?.currentProfile.id else { return }
                stickerVM.createNoteAsset(
                    content: text,
                    style: style.rawValue,
                    profileId: pid,
                    context: modelContext
                )
            }
        }
        .sheet(isPresented: $showDrawingBoard) {
            if let pid = profileManager?.currentProfile.id {
                DrawingBoardSheet { pngData in
                    let name = "画画 \(Date().formatted(.dateTime.hour().minute()))"
                    stickerVM.addDrawingAsset(pngData: pngData, name: name, profileId: pid, context: modelContext)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.sidebarBg)
            }
        }
        .sheet(item: $editingStyleAsset) { asset in
            if let pid = profileManager?.currentProfile.id {
                StickerStyleSheet(asset: asset, profileId: pid) { border, filter in
                    Task {
                        await stickerVM.updateStyle(
                            asset: asset, borderStyle: border, borderWidth: CGFloat(asset.borderWidth),
                            filterStyle: filter, profileId: pid, context: modelContext
                        )
                    }
                }
            }
        }
    }

    private func stickerActionButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textMuted)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.mainBg.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "star.circle")
                .font(.system(size: 32))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text(searchText.isEmpty ? "还没有贴纸" : "没有匹配的贴纸")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
            if searchText.isEmpty {
                Text("点击下方按钮导入图片")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// iOS：点击贴纸直接放到当前对话画布中央
    private func placeStickerFromTap(asset: StickerAsset) {
        guard let convId = viewModel.selectedConversation?.id,
              let pid = profileManager?.currentProfile.id else { return }
        let y = max(200, CGFloat(viewModel.currentPath.count) * 50)
        if asset.isNote {
            stickerVM.placeNote(
                content: asset.noteContent ?? "", style: asset.noteStyle ?? "yellow_square",
                conversationId: convId, position: CGPoint(x: 200, y: y),
                nearestMessageId: viewModel.currentPath.first?.id,
                profileId: pid, context: modelContext
            )
        } else {
            stickerVM.placeSticker(
                assetId: asset.id, conversationId: convId,
                position: CGPoint(x: 200, y: y),
                nearestMessageId: viewModel.currentPath.first?.id,
                profileId: pid, context: modelContext
            )
        }
    }

    private func renameSticker(_ asset: StickerAsset) {
        // 简单实现：用 alert 输入新名字
        // 后续可以做 inline 编辑
    }

}

// MARK: - Sticker Thumbnail (Gallery Item)

struct StickerThumbnailView: View {
    let asset: StickerAsset
    let profileId: String
    let index: Int
    let hasAppeared: Bool

    @State private var thumbnailImage: Image?
    // 每个贴纸固定的微旋转角度
    private var tiltAngle: Double {
        // 基于 id 生成确定性的微旋转
        let hash = abs(asset.id.hashValue)
        return Double(hash % 11) - 5.0  // -5° 到 +5°
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = thumbnailImage {
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 80)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent.opacity(0.3))
                        .frame(height: 80)
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.5)
                        )
                }
            }
            Text(asset.name)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .rotationEffect(.degrees(hasAppeared ? tiltAngle : Double.random(in: -30...30)))
        .scaleEffect(hasAppeared ? 1.0 : 0.3)
        .opacity(hasAppeared ? 1.0 : 0)
        .offset(
            x: hasAppeared ? 0 : CGFloat.random(in: -100...100),
            y: hasAppeared ? 0 : CGFloat.random(in: -100...100)
        )
        .animation(
            .spring(response: 0.5, dampingFraction: 0.65)
                .delay(Double(index) * 0.03),
            value: hasAppeared
        )
        .onDrag {
            NSItemProvider(object: asset.id.uuidString as NSString)
        }
        .task(id: "\(asset.thumbnailPath)_\(asset.borderStyle)_\(asset.filterStyle)") { loadThumbnail() }
    }

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = StickerFileManager.loadImageCached(path: asset.thumbnailPath, profileId: profileId) {
                if let uiImage = UIImage(data: data) {
                    let img = Image(uiImage: uiImage)
                    DispatchQueue.main.async { thumbnailImage = img }
                }
            }
        }
    }
}

// MARK: - Note Thumbnail (便签预览)

struct NoteThumbnailView: View {
    let asset: StickerAsset
    let index: Int
    let hasAppeared: Bool

    private var tiltAngle: Double {
        let hash = abs(asset.id.hashValue)
        return Double(hash % 11) - 5.0
    }

    private var bgColor: Color {
        switch asset.noteStyle {
        case "pink_rounded": return Color(red: 1, green: 0.85, blue: 0.88)
        case "glass": return Color.gray.opacity(0.3)
        case "torn_paper": return Color.white.opacity(0.9)
        default: return Color(red: 1, green: 0.96, blue: 0.75) // yellow
        }
    }

    private var cornerRadius: CGFloat {
        switch asset.noteStyle {
        case "pink_rounded": return 8
        case "torn_paper": return 2
        default: return 4
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(asset.noteContent ?? "")
                .font(.system(size: 9))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(3)
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(bgColor)
                )
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)

            Text(asset.name)
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .rotationEffect(.degrees(hasAppeared ? tiltAngle : Double.random(in: -30...30)))
            .scaleEffect(hasAppeared ? 1.0 : 0.3)
            .opacity(hasAppeared ? 1.0 : 0)
            .offset(
                x: hasAppeared ? 0 : CGFloat.random(in: -100...100),
                y: hasAppeared ? 0 : CGFloat.random(in: -100...100)
            )
            .animation(
                .spring(response: 0.5, dampingFraction: 0.65)
                    .delay(Double(index) * 0.03),
                value: hasAppeared
            )
            .onDrag {
                NSItemProvider(object: asset.id.uuidString as NSString)
            }
    }
}
