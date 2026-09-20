import Foundation
import SwiftData
import SwiftUI

import UIKit

/// 贴纸系统状态管理
@Observable
final class StickerViewModel {
    // 贴纸库
    var stickerAssets: [StickerAsset] = []

    // 当前对话已贴的贴纸
    var placedStickers: [PlacedSticker] = []

    // 编辑模式
    var isEditingStickers = false
    var selectedPlacedStickerId: UUID?

    // 贴纸实际渲染尺寸（不参与 observation，避免触发 ScrollView 重绘）
    @ObservationIgnored var stickerSizes: [UUID: CGSize] = [:]

    // 气泡位置（不参与 observation，仅供贴纸定位查询）
    @ObservationIgnored var bubblePositions: [String: CGFloat] = [:]

    // 当前对话 path 长度（CardFlowView 同步）。clamp positionY 算上限用，
    // bubblePositions 在 LazyVStack 渲染后才填，迁移启动时为空，用 pathCount × 200 兜底。
    // 详见 docs/research-b20-sticker-overflow.md
    @ObservationIgnored var currentPathCount: Int = 0

    // 内部剪贴板
    var copiedSnapshot: StickerSnapshot?

    // 重命名弹窗
    var renamingStickerId: UUID?
    var renameText: String = ""

    // 便签编辑
    var editingNoteStickerId: UUID?

    // 手势初始值（同一时间只有一个贴纸选中）
    @ObservationIgnored var gestureStartScale: Double = 1.0
    @ObservationIgnored var gestureStartRotation: Double = 0
    @ObservationIgnored var dragStarted: Bool = false      // 单指拖拽
    @ObservationIgnored var pinchStarted: Bool = false     // 双指缩放/旋转
    @ObservationIgnored var dragTouchOffset: CGPoint = .zero  // 触摸点相对贴纸中心偏移（物理拖拽用）
    @ObservationIgnored var lastRotationDelta: Double = 0     // 角速度追踪（惯性用）
    @ObservationIgnored var lastDragTranslation: CGSize = .zero // macOS DragGesture 帧间 delta 用

    // Undo 栈
    @ObservationIgnored var undoStack: [StickerUndoSnapshot] = []
    private let maxUndoSteps = 30

    // 导入状态
    var isImporting = false
    var importProgress: String?

    /// 贴纸加/删后通知（由 CardFlowView 注入）。实现应写 Conversation.updateTime = Date()
    /// + ConversationViewModel.markConversationDirty()，触发 3 秒 debounce 重排。
    /// 贴纸的移动 / 缩放 / 旋转 / 文本编辑不触发（只认增删）。
    @ObservationIgnored var onConversationMutated: ((String) -> Void)?

    // MARK: - Profile Switch Race Defense
    //
    // 切楼层（ProfileManager.switchTo）会 reset modelContainer → 旧 PlacedSticker /
    // StickerAsset @Model 实例被 destroy。路线 C 下 UIHostingController 嵌套 SwiftUI
    // sub-tree 的 dismount 跟主 tree 不同步，旧 StickerCanvasLayer.body 在 dismount 最后
    // 一拍会 iterate placedStickers / stickerAssets → 读 `.id` → fatal。
    //
    // 修法：post .profileWillSwitch 时同步清所有 @Model ref。queue:nil 确保同步在
    // posting（main）线程跑，observer 返回后 currentProfile/container 才 flip。
    // xcdoc: /documentation/foundation/notificationcenter/addobserver(forname:object:queue:using:)
    // Plan: docs/plan-profile-switch-crash-v2.md
    @ObservationIgnored private var profileSwitchObserver: NSObjectProtocol?

    init() {
        profileSwitchObserver = NotificationCenter.default.addObserver(
            forName: .profileWillSwitch, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.placedStickers = []
            self.stickerAssets = []
            self.selectedPlacedStickerId = nil
            self.renamingStickerId = nil
            self.editingNoteStickerId = nil
            self.copiedSnapshot = nil
            self.undoStack.removeAll()
            self.stickerSizes.removeAll()
            self.bubblePositions.removeAll()
        }
    }

    deinit {
        if let observer = profileSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load

    func loadLibrary(profileId: String, context: ModelContext) {
        let pid = profileId
        let desc = FetchDescriptor<StickerAsset>(
            predicate: #Predicate<StickerAsset> { asset in asset.profileId == pid },
            sortBy: [SortDescriptor(\StickerAsset.createdAt, order: .reverse)]
        )
        stickerAssets = (try? context.fetch(desc)) ?? []
    }

    func loadPlacedStickers(conversationId: String, profileId: String, context: ModelContext) {
        let cid = conversationId
        let pid = profileId
        let desc = FetchDescriptor<PlacedSticker>(
            predicate: #Predicate<PlacedSticker> { s in
                s.conversationId == cid && s.profileId == pid
            },
            sortBy: [SortDescriptor(\PlacedSticker.zIndex)]
        )
        placedStickers = (try? context.fetch(desc)) ?? []
    }

    /// 当前楼层贴纸素材数（设置页统计用，fetchCount 不拉全量；static——设置页没有 vm 实例）
    static func assetCount(profileId: String, context: ModelContext) -> Int {
        let pid = profileId
        let desc = FetchDescriptor<StickerAsset>(
            predicate: #Predicate<StickerAsset> { a in a.profileId == pid }
        )
        return (try? context.fetchCount(desc)) ?? 0
    }

    /// 当前楼层已放置贴纸数（设置页统计用）
    static func placedCount(profileId: String, context: ModelContext) -> Int {
        let pid = profileId
        let desc = FetchDescriptor<PlacedSticker>(
            predicate: #Predicate<PlacedSticker> { s in s.profileId == pid }
        )
        return (try? context.fetchCount(desc)) ?? 0
    }

    /// 托管对象就地修改（手势拖拽/缩放/旋转、便签内容等）后的统一落盘出口
    func persist(context: ModelContext) {
        try? context.save()
    }

    // MARK: - Import

    /// 画板 PNG → 贴纸库（StickerToolbar / StickerKeyboardPanel / StickerLibraryView 共用）
    func addDrawingAsset(pngData: Data, name: String, profileId: String, context: ModelContext) {
        let assetId = UUID()
        do {
            let paths = try StickerFileManager.saveStickerImage(pngData, id: assetId, profileId: profileId)
            let asset = StickerAsset(
                name: name,
                imagePath: paths.imagePath,
                thumbnailPath: paths.thumbnailPath,
                profileId: profileId
            )
            asset.id = assetId
            context.insert(asset)
            stickerAssets.insert(asset, at: 0)
            try? context.save()
        } catch {
            print("画画保存失败: \(error.localizedDescription)")
        }
    }

    /// 导入图片 → 抠图 → 默认描边 → 保存到贴纸库
    @MainActor
    func importImages(urls: [URL], name: String? = nil, profileId: String, context: ModelContext) async {
        isImporting = true
        defer { isImporting = false }

        var failedNames: [String] = []

        for (index, url) in urls.enumerated() {
            importProgress = "处理中 \(index + 1)/\(urls.count)..."

            // 沙箱安全作用域
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                // 1. 读取图片
                let imageData = try Data(contentsOf: url)

                // 2. 去重命名（在主 actor 上读取 stickerAssets）
                let baseName = name ?? url.deletingPathExtension().lastPathComponent
                let rawName = urls.count > 1 ? "\(baseName) \(index + 1)" : baseName
                let displayName = deduplicateName(rawName)
                let assetId = UUID()

                // 3. 抠图 / 描边 / 存盘（CPU 密集，丢到后台线程）
                let (imagePath, thumbnailPath, originalPath) = try await Task.detached(priority: .userInitiated) { () -> (String, String, String?) in
                    let liftedData = try SubjectLifter.liftSubject(from: imageData)
                    let borderedData = try StickerBorderRenderer.renderBorder(
                        on: liftedData, style: .solidWhite, width: 8
                    )
                    let paths = try StickerFileManager.saveStickerImage(borderedData, id: assetId, profileId: profileId)
                    let originalPath = try? StickerFileManager.saveOriginalImage(imageData, id: assetId, profileId: profileId)
                    return (paths.imagePath, paths.thumbnailPath, originalPath)
                }.value

                // 4. 创建模型（回到主 actor，直接建立 @Model）
                let asset = StickerAsset(
                    name: displayName,
                    imagePath: imagePath,
                    thumbnailPath: thumbnailPath,
                    originalImagePath: originalPath,
                    borderStyle: BorderStyle.solidWhite.rawValue,
                    borderWidth: 8.0,
                    profileId: profileId
                )
                asset.id = assetId
                context.insert(asset)
                stickerAssets.insert(asset, at: 0)
            } catch {
                failedNames.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 保存 + 反馈结果
        try? context.save()
        if failedNames.isEmpty {
            importProgress = nil
        } else {
            importProgress = "失败：\(failedNames.joined(separator: "; "))"
        }
    }

    /// iOS: 从 Data 导入（PhotosPicker 返回 Data 而不是 URL）
    @MainActor
    func importImageData(_ dataList: [Data], name: String, profileId: String, context: ModelContext) async {
        isImporting = true
        defer { isImporting = false }

        var failCount = 0

        for (index, imageData) in dataList.enumerated() {
            importProgress = "处理中 \(index + 1)/\(dataList.count)..."
            do {
                let displayName = deduplicateName(dataList.count > 1 ? "\(name) \(index + 1)" : name)
                let assetId = UUID()
                let (imagePath, thumbnailPath) = try await Task.detached(priority: .userInitiated) { () -> (String, String) in
                    let liftedData = try SubjectLifter.liftSubject(from: imageData)
                    let borderedData = try StickerBorderRenderer.renderBorder(on: liftedData, style: .solidWhite, width: 8)
                    let paths = try StickerFileManager.saveStickerImage(borderedData, id: assetId, profileId: profileId)
                    return (paths.imagePath, paths.thumbnailPath)
                }.value
                let asset = StickerAsset(name: displayName, imagePath: imagePath, thumbnailPath: thumbnailPath,
                                         borderStyle: BorderStyle.solidWhite.rawValue, borderWidth: 8.0, profileId: profileId)
                asset.id = assetId
                context.insert(asset)
                stickerAssets.insert(asset, at: 0)
            } catch {
                failCount += 1
            }
        }
        try? context.save()
        if failCount > 0 {
            importProgress = "\(failCount) 张处理失败（抠图不支持此图片格式）"
        } else {
            importProgress = nil
        }
    }

    // MARK: - Create Note Asset

    /// 新建便签 → 存入贴纸库
    func createNoteAsset(content: String, style: String, profileId: String, context: ModelContext) {
        let asset = StickerAsset(noteContent: content, noteStyle: style, profileId: profileId)
        context.insert(asset)
        stickerAssets.insert(asset, at: 0)
        try? context.save()
    }

    // MARK: - Place Sticker

    /// 从贴纸库放置一张贴纸到画布
    func placeSticker(
        assetId: UUID,
        conversationId: String,
        position: CGPoint,
        nearestMessageId: String?,
        profileId: String,
        context: ModelContext
    ) {
        let maxZ = placedStickers.map(\.zIndex).max() ?? 0
        let sticker = PlacedSticker(
            stickerAssetId: assetId,
            conversationId: conversationId,
            nearestMessageId: nearestMessageId,
            positionX: position.x,
            positionY: position.y,
            zIndex: maxZ + 1,
            profileId: profileId
        )
        context.insert(sticker)
        placedStickers.append(sticker)
        clampStickerY(sticker)
        try? context.save()
        onConversationMutated?(conversationId)
    }

    /// 放置便签贴纸
    func placeNote(
        content: String,
        style: String,
        conversationId: String,
        position: CGPoint,
        nearestMessageId: String?,
        profileId: String,
        context: ModelContext
    ) {
        let maxZ = placedStickers.map(\.zIndex).max() ?? 0
        let sticker = PlacedSticker(
            conversationId: conversationId,
            nearestMessageId: nearestMessageId,
            positionX: position.x,
            positionY: position.y,
            zIndex: maxZ + 1,
            noteContent: content,
            noteStyle: style,
            profileId: profileId
        )
        context.insert(sticker)
        placedStickers.append(sticker)
        clampStickerY(sticker)
        try? context.save()
        onConversationMutated?(conversationId)
    }

    // MARK: - Lock

    func toggleLock(_ sticker: PlacedSticker, context: ModelContext) {
        sticker.isLocked.toggle()
        try? context.save()
    }

    // MARK: - Remove

    /// 撕掉贴纸（从画布移除）
    func removePlacedSticker(_ sticker: PlacedSticker, context: ModelContext) {
        guard !sticker.isLocked else { return }
        let id = sticker.id
        let convId = sticker.conversationId
        placedStickers.removeAll { $0.id == id }
        undoStack.removeAll { $0.stickerId == id }
        context.delete(sticker)
        try? context.save()
        onConversationMutated?(convId)
    }

    /// 从贴纸库删除资产（同时删除文件和所有已贴实例）
    func deleteAsset(_ asset: StickerAsset, context: ModelContext) {
        // 删除文件 + 清除缓存
        StickerFileManager.deleteStickerFiles(id: asset.id, profileId: asset.profileId)
        StickerFileManager.evictCache(id: asset.id, profileId: asset.profileId)

        // 删除所有已贴实例
        let assetId = asset.id
        let desc = FetchDescriptor<PlacedSticker>(
            predicate: #Predicate<PlacedSticker> { s in s.stickerAssetId == assetId }
        )
        if let placed = try? context.fetch(desc) {
            for s in placed {
                placedStickers.removeAll { $0.id == s.id }
                context.delete(s)
            }
        }

        // 删除资产
        stickerAssets.removeAll { $0.id == asset.id }
        context.delete(asset)
        try? context.save()
    }

    // MARK: - Update Border

    /// 修改贴纸样式（描边 + 滤镜，重新渲染 PNG）
    @MainActor
    func updateStyle(asset: StickerAsset, borderStyle: BorderStyle, borderWidth: CGFloat, filterStyle: FilterStyle, profileId: String, context: ModelContext) async {
        // 先在主 actor 上快照 @Model 属性，后台线程只碰值类型
        let assetId = asset.id
        let hasOriginal = asset.originalImagePath != nil
        let sourcePath = asset.originalImagePath ?? asset.imagePath

        do {
            let rendered = try await Task.detached(priority: .userInitiated) { () -> (String, String)? in
                guard let sourceData = StickerFileManager.loadImage(path: sourcePath, profileId: profileId) else { return nil }

                // 1. 抠图（如果有原图）
                let liftedData: Data
                if hasOriginal {
                    liftedData = try SubjectLifter.liftSubject(from: sourceData)
                } else {
                    liftedData = sourceData
                }

                // 2. 滤镜
                let filteredData = try StickerFilterRenderer.applyFilter(on: liftedData, style: filterStyle)

                // 3. 描边
                let borderedData = try StickerBorderRenderer.renderBorder(on: filteredData, style: borderStyle, width: borderWidth)

                // 4. 保存
                let paths = try StickerFileManager.saveStickerImage(borderedData, id: assetId, profileId: profileId)
                return (paths.imagePath, paths.thumbnailPath)
            }.value

            guard let (imagePath, thumbnailPath) = rendered else { return }

            asset.imagePath = imagePath
            asset.thumbnailPath = thumbnailPath
            asset.borderStyle = borderStyle.rawValue
            asset.borderWidth = Double(borderWidth)
            asset.filterStyle = filterStyle.rawValue
            try? context.save()
        } catch {
            print("样式更新失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Copy / Paste

    func copySticker(_ sticker: PlacedSticker) {
        copiedSnapshot = StickerSnapshot(
            stickerAssetId: sticker.stickerAssetId,
            noteContent: sticker.noteContent,
            noteStyle: sticker.noteStyle,
            scale: sticker.scale,
            rotation: sticker.rotation
        )
    }

    func pasteSticker(conversationId: String, nearPosition: CGPoint, profileId: String, context: ModelContext) {
        guard let snap = copiedSnapshot else { return }
        let offset: CGFloat = 20
        let maxZ = placedStickers.map(\.zIndex).max() ?? 0
        let sticker = PlacedSticker(
            stickerAssetId: snap.stickerAssetId,
            conversationId: conversationId,
            positionX: nearPosition.x + offset,
            positionY: nearPosition.y + offset,
            rotation: snap.rotation,
            scale: snap.scale,
            zIndex: maxZ + 1,
            noteContent: snap.noteContent,
            noteStyle: snap.noteStyle,
            profileId: profileId
        )
        context.insert(sticker)
        placedStickers.append(sticker)
        clampStickerY(sticker)
        try? context.save()
        onConversationMutated?(conversationId)
    }

    // MARK: - Position Clamp (B20 修复 — 防贴纸 positionY 飞远撑虚高 ZStack)

    /// 把 sticker.positionY 收敛到合理上限。
    /// 上限 = max(已渲染 bubble 最远 midY, currentPathCount × 200) + 1500 buffer。
    /// 在 drag end / fling end / drop / paste 后调用（都从 main actor 来）。
    /// 详见 docs/research-b20-sticker-overflow.md
    func clampStickerY(_ sticker: PlacedSticker) {
        let bubbleMaxY = bubblePositions.values.max() ?? 0
        let estimatedFullH = CGFloat(currentPathCount) * 200
        let maxAllowed = max(bubbleMaxY, estimatedFullH) + 1500
        if sticker.positionY > maxAllowed {
            sticker.positionY = maxAllowed
        }
    }

    /// 一次性扫描所有 placedStickers，把飞出合理上限的 clamp 回来。
    /// 在 conversation load 完成（isLoading=false + currentPath 非空）后调用。
    /// 注意：bubblePositions 此时通常还为空（LazyVStack 还没渲染），只能用 pathCount × 200 兜底。
    func migrateStickerPositions(context: ModelContext) {
        let maxAllowed = CGFloat(currentPathCount) * 200 + 1500
        var migrated = 0
        for sticker in placedStickers where sticker.positionY > maxAllowed {
            sticker.positionY = maxAllowed
            migrated += 1
        }
        if migrated > 0 {
            try? context.save()
            print("[StickerMigration] clamped \(migrated)/\(placedStickers.count), maxY=\(maxAllowed), pathCount=\(currentPathCount)")
        }
    }

    // MARK: - Layer Order

    func bringToFront(_ sticker: PlacedSticker, context: ModelContext) {
        let maxZ = placedStickers.map(\.zIndex).max() ?? 0
        sticker.zIndex = maxZ + 1
        try? context.save()
    }

    func sendToBack(_ sticker: PlacedSticker, context: ModelContext) {
        let minZ = placedStickers.map(\.zIndex).min() ?? 0
        sticker.zIndex = minZ - 1
        try? context.save()
    }

    // MARK: - Rename

    func renameAsset(assetId: UUID, newName: String, context: ModelContext) {
        guard let asset = stickerAssets.first(where: { $0.id == assetId }) else { return }
        asset.name = newName
        try? context.save()
    }

    // MARK: - Undo

    /// 保存贴纸当前变换状态到 undo 栈（在变换开始前调用）
    func pushUndo(for sticker: PlacedSticker) {
        let snapshot = StickerUndoSnapshot(
            stickerId: sticker.id,
            positionX: sticker.positionX,
            positionY: sticker.positionY,
            scale: sticker.scale,
            rotation: sticker.rotation
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst()
        }
    }

    /// 撤回上一步变换
    func undo(context: ModelContext) {
        guard let snapshot = undoStack.popLast() else { return }
        guard let sticker = placedStickers.first(where: { $0.id == snapshot.stickerId }) else { return }
        sticker.positionX = snapshot.positionX
        sticker.positionY = snapshot.positionY
        sticker.scale = snapshot.scale
        sticker.rotation = snapshot.rotation
        try? context.save()
    }

    // MARK: - Export Note as PNG

    /// iOS 导出触发：设了 data 后 SwiftUI sheet 弹出分享面板
    var exportedNotePNGData: Data?

    /// 渲染便签为 PNG（不带画布上的 scale/rotation，原始尺寸 3x 高清）
    @MainActor
    func exportNoteAsPNG(content: String, style: String) -> Data? {
        let view = NoteExportView(content: content, style: style)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3.0
        guard let cgImage = renderer.cgImage else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }

    /// macOS: NSSavePanel 保存 PNG 文件

    /// iOS: 直接弹 UIActivityViewController（UIKit 回调触发 SwiftUI sheet 不可靠）
    @MainActor
    func shareNoteAsPNG(content: String, style: String) {
        guard let data = exportNoteAsPNG(content: content, style: style),
              let image = UIImage(data: data) else { return }
        let vc = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            vc.popoverPresentationController?.sourceView = topVC.view
            vc.popoverPresentationController?.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            topVC.present(vc, animated: true)
        }
    }

    // MARK: - Deduplicate Name

    /// 检查现有贴纸库是否有同名，有则自动加序号
    private func deduplicateName(_ name: String) -> String {
        let existingNames = Set(stickerAssets.map(\.name))
        guard existingNames.contains(name) else { return name }
        var n = 2
        while existingNames.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }
}

// MARK: - Snapshot (内部剪贴板)

struct StickerSnapshot {
    let stickerAssetId: UUID?
    let noteContent: String?
    let noteStyle: String?
    let scale: Double
    let rotation: Double
}

// MARK: - Undo Snapshot

struct StickerUndoSnapshot {
    let stickerId: UUID
    let positionX: Double
    let positionY: Double
    let scale: Double
    let rotation: Double
}
