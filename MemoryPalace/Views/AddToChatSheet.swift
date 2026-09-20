import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// + 号功能面板（Claude App 风格底部 sheet）
/// 内容：添加文件/照片、选择模型、设置、导入聊天记录、贴纸
struct AddToChatSheet: View {
    /// 点击「贴纸」后回调——由 CardFlowView 传入，负责打开 StickerKeyboardPanel
    let onOpenSticker: () -> Void
    /// 点击「发送文件」后回调——由 CardFlowView 在外层弹出文件选择器（避免 sheet 嵌套触摸丢失）
    /// 选中照片后写入此 Binding，由 CardFlowView 持有并传给 ChatInputBar
    @Binding var pendingImageData: Data?
    /// 选中文件后写入，由 CardFlowView 持有并传给 ChatInputBar
    @Binding var pendingFileData: Data?
    @Binding var pendingFileName: String?
    /// 多附件（09-12）：多选照片 / 多选文件全进这里；旧的单件绑定不再由本 sheet 写
    @Binding var pendingAttachments: [PendingChatAttachment]

    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    @AppStorage("selectedChatModel") private var selectedModelId = ""

    @State private var showModelPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    /// 控制 staggered 入场动画
    @State private var appeared = false
    @State private var showFilePicker = false

    private func compressImage(_ uiImage: UIImage, maxDimension: CGFloat = 1024) -> Data? {
        var img = uiImage
        let maxSide = max(uiImage.size.width, uiImage.size.height)
        if maxSide > maxDimension {
            let scale = maxDimension / maxSide
            let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            img = renderer.image { _ in uiImage.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        if let data = img.jpegData(compressionQuality: 0.8), data.count <= 1_048_576 {
            return data
        }
        return img.jpegData(compressionQuality: 0.5)
    }

    private var currentModelName: String {
        guard let pm = providerManager else { return "未选择" }
        if !selectedModelId.isEmpty, let model = pm.model(byId: selectedModelId) {
            return model.name
        }
        return pm.availableModels.first?.name ?? "未选择"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // 间距
                Spacer().frame(height: 20)

                // ── 行 0：添加文件 / 照片 ──────────────────────────────
                PhotosPicker(
                    selection: $photoPickerItems,
                    maxSelectionCount: 9,   // 微信习惯；每张 ≤ PendingChatAttachment.maxImageBytes
                    matching: .images
                ) {
                    addToChatRow(
                        icon: "paperclip",
                        iconColor: Theme.branchIndicator,
                        title: "添加照片",
                        trailing: nil
                    )
                }
                .onChange(of: photoPickerItems) { (_: [PhotosPickerItem], newItems: [PhotosPickerItem]) in
                    guard !newItems.isEmpty else { return }
                    Task {
                        var picked: [PendingChatAttachment] = []
                        for (i, item) in newItems.enumerated() {
                            // 三级 fallback：Data.self → 自定义 TransferableImage → 降级 JPEG
                            var compressedData: Data? = nil
                            do {
                                if let data = try await item.loadTransferable(type: Data.self),
                                   let uiImage = UIImage(data: data) {
                                    compressedData = compressImage(uiImage)
                                }
                            } catch {
                                BreadcrumbLog.shared.add("📷", "loadTransferable(Data) failed: \(error.localizedDescription)")
                            }
                            if compressedData == nil {
                                do {
                                    if let img = try await item.loadTransferable(type: TransferableImage.self) {
                                        compressedData = compressImage(img.uiImage)
                                        if compressedData != nil { BreadcrumbLog.shared.add("📷", "fallback TransferableImage succeeded") }
                                    }
                                } catch {
                                    BreadcrumbLog.shared.add("📷", "loadTransferable(TransferableImage) failed: \(error.localizedDescription)")
                                }
                            }
                            guard let compressed = compressedData else {
                                BreadcrumbLog.shared.add("📷", "all image load paths failed for item \(i)")
                                continue
                            }
                            let name = "照片\(i + 1).jpg"
                            if let att = try? PendingChatAttachment.image(name: name, typeDescription: "JPEG", mimeType: "image/jpeg", data: compressed) {
                                picked.append(att)
                            } else {
                                BreadcrumbLog.shared.add("📷", "\(name) 超过单张上限，跳过")
                            }
                        }
                        let result = picked
                        await MainActor.run {
                            pendingAttachments.append(contentsOf: result)
                            photoPickerItems = []
                            dismiss()
                        }
                    }
                }
                .rowEntrance(index: 0, appeared: appeared)

                rowDivider

                // ── 行 1：选择文件 ──────────────────────────────────
                Button {
                    showFilePicker = true
                } label: {
                    addToChatRow(
                        icon: "doc",
                        iconColor: Color.red.opacity(0.8),
                        title: "选择文件",
                        trailing: nil
                    )
                }
                .buttonStyle(.plain)
                .rowEntrance(index: 1, appeared: appeared)

                rowDivider

                // ── 行 2：选择模型 ─────────────────────────────────────
                Button {
                    showModelPicker = true
                } label: {
                    addToChatRow(
                        icon: "cpu",
                        iconColor: Color.purple.opacity(0.85),
                        title: "选择模型",
                        trailing: AnyView(
                            Text(currentModelName)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        )
                    )
                }
                .buttonStyle(.plain)
                .rowEntrance(index: 2, appeared: appeared)

                rowDivider

                // ── 行 3：设置 ─────────────────────────────────────────
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        NotificationCenter.default.post(name: .requestShowSettings, object: nil)
                    }
                } label: {
                    addToChatRow(
                        icon: "gearshape",
                        iconColor: Theme.textMuted,
                        title: "设置",
                        trailing: nil
                    )
                }
                .buttonStyle(.plain)
                .rowEntrance(index: 3, appeared: appeared)

                rowDivider

                // ── 行 4：导入聊天记录 ─────────────────────────────────
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        NotificationCenter.default.post(name: .memoryPalaceRequestImport, object: nil)
                    }
                } label: {
                    addToChatRow(
                        icon: "square.and.arrow.down",
                        iconColor: Color.orange.opacity(0.85),
                        title: "导入聊天记录",
                        trailing: nil
                    )
                }
                .buttonStyle(.plain)
                .rowEntrance(index: 4, appeared: appeared)

                rowDivider

                // ── 行 5：贴纸 ─────────────────────────────────────────
                Button {
                    dismiss()
                    // 短暂延迟让 sheet dismiss 动画完成后再展开贴纸面板
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onOpenSticker()
                    }
                } label: {
                    addToChatRow(
                        icon: "face.smiling",
                        iconColor: Color.pink.opacity(0.85),
                        title: "贴纸",
                        trailing: nil
                    )
                }
                .buttonStyle(.plain)
                .rowEntrance(index: 5, appeared: appeared)

                Spacer()
            }
            .background(Theme.sidebarBg)
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
            .fileImporter(
                isPresented: $showFilePicker,
                // .text 是 .plainText 的父类型：txt/md/log 等文本变体都能选
                allowedContentTypes: [.item],   // 09-12 放开到任意文件：CC 什么都能读；API 车道抽不出文本的在发送时拒
                // 旧白名单（留档）：[.pdf, .json, .text, .html, .commaSeparatedText, .png, .jpeg, .gif, .webP, .heic, .xml],
                allowsMultipleSelection: true   // 09-12 多选
            ) { result in
                switch result {
                case .success(let urls):
                    // 每个文件走 AttachmentTextExtractor（图→image；pdf/代码/文本→抽文本；其余→原始字节给 CC）；
                    // 单个失败只跳过那个并记面包屑，不整批丢
                    for url in urls {
                        do {
                            pendingAttachments.append(try AttachmentTextExtractor.extract(from: url))
                        } catch {
                            BreadcrumbLog.shared.add("📎", "\(url.lastPathComponent)：\(error.localizedDescription)")
                        }
                    }
                case .failure:
                    break
                }
                dismiss()
            }
        .presentationBackground(Theme.sidebarBg)
        .onAppear {
            withAnimation(.easeOut(duration: 0.1)) {
                appeared = true
            }
        }
        // 模型选择器 sub-sheet
        .sheet(isPresented: $showModelPicker) {
            if let pm = providerManager {
                ModelPickerPopover(
                    providerManager: pm,
                    selectedModelId: selectedModelId
                ) { model in
                    selectedModelId = model.id
                    pm.touchLastUsed(providerId: model.providerId, modelId: model.modelId)
                    showModelPicker = false
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)

                .presentationBackground(Theme.sidebarBg)
            }
        }
    }

    // MARK: - Row layout

    @ViewBuilder
    private func addToChatRow(
        icon: String,
        iconColor: Color,
        title: String,
        trailing: AnyView?
    ) -> some View {
        HStack(spacing: 14) {
            // 图标圆形底
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
            }

            Text(title)
                .font(.system(size: 16))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            if let trailingView = trailing {
                trailingView
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.accent.opacity(0.25))
            .frame(height: 0.5)
            .padding(.leading, 70)
    }
}

// MARK: - 入场动画 ViewModifier

private struct RowEntranceModifier: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
                .easeOut(duration: 0.22).delay(Double(index) * 0.05),
                value: appeared
            )
    }
}

private extension View {
    func rowEntrance(index: Int, appeared: Bool) -> some View {
        modifier(RowEntranceModifier(index: index, appeared: appeared))
    }
}

// MARK: - TransferableImage（PhotosPicker fallback）

/// PhotosPicker 的 loadTransferable(type: Data.self) 在某些 iOS 版本 / HEIC 场景下
/// 会静默失败。此类型用 .image 表示类型，让系统自动解码为 UIImage。
struct TransferableImage: Transferable {
    let uiImage: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let img = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return TransferableImage(uiImage: img)
        }
    }
}
