import SwiftUI

// MARK: - Glass Effect Compatibility
//
// .glassEffect() 需要 iOS 26 + Xcode 18 SDK。
// 当前 CI 用 Xcode 16.4，SDK 里没有这个 symbol，连 @available 包装都编译不过。
// 所以直接用 .ultraThinMaterial fallback。
// TODO: 等 Xcode 18 GA 后用 #if compiler(>=6.2) 加回原生 glassEffect。

extension View {
    @ViewBuilder
    func glassEffectCompat<S: Shape>(
        tint: Color,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        self.background(shape.fill(.ultraThinMaterial))
    }

    @ViewBuilder
    func glassEffectCompat(tint: Color, interactive: Bool = false) -> some View {
        self.background(.ultraThinMaterial)
    }

    @ViewBuilder
    func glassButtonStyleCompat() -> some View {
        self
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(.plain)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}
