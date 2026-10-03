import SwiftUI

/// 气泡外的图（10-03）：一张 = 按比例大图；多张 = BubbleAttachmentStrip 长条。点开走 AttachmentPreviewSheet。
struct OutsideImages: View {
    let images: [(String, Data)]
    @State private var preview: Int? = nil

    var body: some View {
        Group {
            if images.count == 1, let ui = ThumbnailCache.thumbnail(for: images[0].1, maxPixel: 480) {
                let ratio = ui.size.height / max(1, ui.size.width)
                let w: CGFloat = min(240, ui.size.width)
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: min(320, max(80, w * ratio)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.06), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .onTapGesture { preview = 0 }
            } else {
                BubbleAttachmentStrip(items: images.map { .image(name: $0.0, data: $0.1) }, isUser: false)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            AttachmentPreviewSheet(items: images.map { .image(name: $0.0, data: $0.1) }, initialIndex: preview ?? 0)
        }
    }
}
