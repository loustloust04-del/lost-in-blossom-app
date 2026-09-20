import SwiftUI

struct HapticTestView: View {
    var body: some View {
        List {
            Section("Impact") {
                hapticButton("Light") { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                hapticButton("Medium") { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                hapticButton("Heavy") { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                hapticButton("Soft") { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                hapticButton("Rigid") { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            }
            Section("Notification") {
                hapticButton("Success") { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                hapticButton("Warning") { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
                hapticButton("Error") { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            }
            Section("Selection") {
                hapticButton("selectionChanged") { UISelectionFeedbackGenerator().selectionChanged() }
            }
        }
        .navigationTitle("震动测试")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func hapticButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundColor(Theme.textPrimary)
        }
    }
}
