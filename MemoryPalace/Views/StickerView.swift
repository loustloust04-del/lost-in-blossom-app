import SwiftUI
import UIKit

/// 单个贴纸渲染 — 纸质感 + 动画
struct StickerView: View {
    let sticker: PlacedSticker
    let profileId: String
    let isEditing: Bool
    let isSelected: Bool
    let onRemove: () -> Void
    var onSizeChanged: ((CGSize) -> Void)?

    @State private var stickerImage: Image?
    @State private var appearScale: CGFloat = 0.3
    @State private var appearRotation: Double = 0
    @State private var isRemoving = false

    // 撕掉动画
    @State private var tearRotation: Double = 0
    @State private var tearOpacity: Double = 1

    var body: some View {
        ZStack {
            if sticker.isNote {
                noteStickerContent
            } else if let img = stickerImage {
                imageStickerContent(img)
            } else {
                // 加载中占位
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 60, height: 60)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .task(id: geo.size.width + geo.size.height * 1000) {
                        onSizeChanged?(geo.size)
                    }
            }
        )
        // 纸质感：投影随"高度"变化（选中 = 拿起来 = 阴影大而散）
        .shadow(
            color: .black.opacity(isSelected ? 0.20 : 0.08),
            radius: isSelected ? 12 : 2,
            x: isSelected ? 2 : 1,
            y: isSelected ? 10 : 2
        )
        // 选中提亮（拿起来离光源近了）
        .brightness(isSelected ? 0.05 : 0)
        // 边角微翘（选中时倾斜稍大 — 拿起来的纸会比贴着桌面的歪一点）
        .rotation3DEffect(.degrees(isSelected ? 2.5 : 1.5), axis: (x: 0.3, y: 0.2, z: 0))
        // 贴纸自身旋转
        .rotationEffect(.degrees(sticker.rotation))
        // 缩放（选中 = 拿起来 = 视觉上离你更近 = 更大）
        .scaleEffect(sticker.scale * appearScale * (isSelected ? 1.06 : 1.0))
        // 浮起用快弹簧（手指一碰就弹起来），落下用慢弹簧（落桌面有微弹）
        .animation(
            isSelected
                ? .spring(response: 0.25, dampingFraction: 0.65)   // 浮起：快、略弹
                : .spring(response: 0.35, dampingFraction: 0.55),  // 沉下：慢、弹一下
            value: isSelected
        )
        // 撕掉动画
        .rotation3DEffect(.degrees(tearRotation), axis: (x: 0, y: 1, z: 0), anchor: .leading)
        .opacity(tearOpacity)
        .onChange(of: isSelected) { _, selected in
            let gen = UIImpactFeedbackGenerator(style: selected ? .light : .soft)
            gen.impactOccurred()
        }
        .onAppear {
            loadImage()
            animateAppear()
        }
    }

    // MARK: - Image Sticker

    private func imageStickerContent(_ img: Image) -> some View {
        img
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 120, maxHeight: 120)
            // 纸纹理 overlay（极淡噪波）
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.03))
            )
    }

    // MARK: - Note Sticker

    private var noteStickerContent: some View {
        let style = sticker.noteStyle ?? "yellow_square"
        return Text(sticker.noteContent ?? "")
            .font(.system(size: 12))
            .foregroundColor(noteTextColor(style))
            .padding(10)
            .frame(minWidth: 80, maxWidth: 160, minHeight: 40)
            .background(noteBackground(style))
            .clipShape(RoundedRectangle(cornerRadius: noteCornerRadius(style)))
    }

    private func noteBackground(_ style: String) -> some ShapeStyle {
        switch style {
        case "pink_rounded":
            return AnyShapeStyle(Color(red: 1, green: 0.85, blue: 0.88).opacity(0.95))
        case "glass":
            return AnyShapeStyle(Color.white.opacity(0.3))
        case "torn_paper":
            return AnyShapeStyle(Color.white.opacity(0.92))
        default: // yellow_square
            return AnyShapeStyle(Color(red: 1, green: 0.96, blue: 0.75).opacity(0.95))
        }
    }

    private func noteTextColor(_ style: String) -> Color {
        switch style {
        case "glass": return .white
        default: return Theme.textPrimary
        }
    }

    private func noteCornerRadius(_ style: String) -> CGFloat {
        switch style {
        case "pink_rounded": return 12
        case "torn_paper": return 2
        default: return 4
        }
    }

    // MARK: - Animations

    private func animateAppear() {
        // 贴上动画：弹性 scale + rotation 抖动
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            appearScale = 1.0
        }
    }

    private func animateRemoval() {
        // 撕掉动画：翻转 + 渐出
        withAnimation(.easeIn(duration: 0.4)) {
            tearRotation = 90
            tearOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onRemove()
        }
    }

    // MARK: - Image Loading

    private func loadImage() {
        guard !sticker.isNote, let assetId = sticker.stickerAssetId else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let imagePath = "\(assetId.uuidString).png"
            if let data = StickerFileManager.loadImageCached(path: imagePath, profileId: profileId) {
                if let uiImage = UIImage(data: data) {
                    let img = Image(uiImage: uiImage)
                    DispatchQueue.main.async { stickerImage = img }
                }
            }
        }
    }
}
