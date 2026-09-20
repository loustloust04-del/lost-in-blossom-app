import SwiftUI
#if os(iOS)
import UIKit
#endif

// 粟粟原文搬运（2026-08-30 气泡整套搬运）：附件条 + 依赖零件。
// IdentifiableInt / HorizontalScrollEdgeFade / attachmentFileIcon / attachmentFileBlockStyle
// 原散在她 CardFlowView.swift 内，一并收进此文件；除 private 放开外一字未改。

struct IdentifiableInt: Identifiable {
    let id = UUID()
    let value: Int
}

enum BubbleAttachmentItem {
    case image(name: String, data: Data)
    case file(name: String, type: String?, content: String?)
    case fileData(name: String, mime: String, data: Data)   // C2：带原始字节的真文件（可 QuickLook/存 Files）
}

struct BubbleAttachmentStrip: View {
    let items: [BubbleAttachmentItem]
    let isUser: Bool
    private let thumbSize: CGFloat = 80
    private let gap: CGFloat = 4
    private let scrollThreshold = 3
    @State private var previewIndex: IdentifiableInt?

    var body: some View {
        Group {
            if items.count > scrollThreshold {
                ScrollView(.horizontal, showsIndicators: false) {
                    stripContent
                }
                #if os(iOS)
                .horizontalScrollEdgeFade()
                #endif
            } else {
                stripContent
            }
        }
        #if os(iOS)
        .sheet(item: $previewIndex) { wrapper in
            AttachmentPreviewSheet(items: items, initialIndex: wrapper.value)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
                .presentationCornerRadius(20)
        }
        #endif
    }

    private var stripContent: some View {
        HStack(spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                Button { previewIndex = IdentifiableInt(value: idx) } label: {
                    switch item {
                    case .image(_, let data):
                        imageBlock(data: data)
                    case .file(let name, let type, _):
                        fileBlock(name: name, type: type)
                    case .fileData(let name, let mime, _):
                        fileBlock(name: name, type: mime)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func imageBlock(data: Data) -> some View {
        Group {
            #if os(iOS)
            if let uiImg = UIImage(data: data) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbSize, height: thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #else
            if let nsImg = NSImage(data: data) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbSize, height: thumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #endif
        }
    }

    private func fileBlock(name: String, type: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: attachmentFileIcon(for: name))
                .font(.system(size: 20))
                .foregroundColor(Theme.textMuted.opacity(0.6))
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let type, !type.isEmpty {
                Text(type)
                    .font(.system(size: 8))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .attachmentFileBlockStyle(cornerRadius: 8)
    }
}

#if os(iOS)
/// 附件条左右淡出遮罩的边状态（onScrollGeometryChange 用，需 Equatable）。粟粟原文同段搬入。
private struct ScrollFadeEdges: Equatable {
    let leading: Bool
    let trailing: Bool
}

/// 横向滚动条左右 alpha 淡出：内容溢出且该侧有隐藏内容才淡（滚到头/不溢出不淡）。
/// 预发送附件条 + 已发送附件条共用。.mask 让边缘 alpha 渐隐（露背景），不是盖白色。
private struct HorizontalScrollEdgeFade: ViewModifier {
    @State private var fadeLeading = false
    @State private var fadeTrailing = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollFadeEdges.self) { geo in
                ScrollFadeEdges(
                    leading: geo.contentOffset.x > 1,
                    trailing: geo.contentOffset.x < geo.contentSize.width - geo.containerSize.width - 1
                )
            } action: { _, edges in
                fadeLeading = edges.leading
                fadeTrailing = edges.trailing
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: fadeLeading ? 0.05 : 0),
                        .init(color: .black, location: fadeTrailing ? 0.95 : 1),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
    }
}

extension View {
    func horizontalScrollEdgeFade() -> some View { modifier(HorizontalScrollEdgeFade()) }
}
#endif

/// 附件文件图标（按扩展名）。预发送方块 + 已发送 fileBlock 共用。
func attachmentFileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf": return "doc.richtext"
    case "txt", "md", "markdown": return "doc.text"
    case "json", "csv", "xml", "yaml", "yml": return "doc.badge.gearshape"
    case "swift", "py", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
    default: return "doc"
    }
}

extension View {
    /// 文件附件方块底：奶油白填充 + 淡薄荷描边（学 page2 日历卡片样式）。
    /// 预发送 + 已发送共用，保持一致。
    func attachmentFileBlockStyle(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.mainBg.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.accent.opacity(0.72), lineWidth: 1)
            )
    }
}
