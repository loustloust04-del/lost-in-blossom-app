import SwiftUI
import UIKit

/// 覆盖在气泡上的可选取文本层。
/// 用 UITextView 实现原生文本选择（双击选词、长按自由选取、拖动手柄）。
struct SelectableTextOverlay: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: UIColor
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.showsVerticalScrollIndicator = false
        tv.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.font = font
        tv.textColor = textColor
        tv.layer.cornerRadius = 16
        tv.layer.borderWidth = 1.5
        tv.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.text = text
    }
}
