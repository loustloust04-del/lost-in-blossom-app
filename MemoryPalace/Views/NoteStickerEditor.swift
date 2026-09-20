import SwiftUI

/// 便签样式枚举
enum NoteStyle: String, CaseIterable {
    case yellowSquare = "yellow_square"
    case pinkRounded = "pink_rounded"
    case glass = "glass"
    case tornPaper = "torn_paper"

    var displayName: String {
        switch self {
        case .yellowSquare: return "黄色方块"
        case .pinkRounded: return "粉色圆角"
        case .glass: return "毛玻璃"
        case .tornPaper: return "白纸条"
        }
    }

    var icon: String {
        switch self {
        case .yellowSquare: return "square.fill"
        case .pinkRounded: return "rectangle.roundedtop.fill"
        case .glass: return "rectangle.fill"
        case .tornPaper: return "doc.text.fill"
        }
    }

    var previewColor: Color {
        switch self {
        case .yellowSquare: return Color(red: 1, green: 0.96, blue: 0.75)
        case .pinkRounded: return Color(red: 1, green: 0.85, blue: 0.88)
        case .glass: return Color.gray.opacity(0.3)
        case .tornPaper: return Color.white.opacity(0.9)
        }
    }
}

/// 便签编辑浮窗
struct NoteStickerEditor: View {
    var initialText: String = ""
    var initialStyle: NoteStyle = .yellowSquare
    var isEditMode: Bool = false
    let onConfirm: (String, NoteStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var selectedStyle: NoteStyle = .yellowSquare
    @State private var selectedFont = "system"
    @FocusState private var isFocused: Bool

    private let availableFonts = [
        ("system", "默认"),
        ("Noteworthy", "手写"),
        ("Marker Felt", "马克笔"),
        ("American Typewriter", "打字机"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // 样式选择
                HStack(spacing: 8) {
                    ForEach(NoteStyle.allCases, id: \.rawValue) { style in
                        Button(action: { selectedStyle = style }) {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: style == .pinkRounded ? 8 : 3)
                                    .fill(style.previewColor)
                                    .frame(width: 36, height: 28)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: style == .pinkRounded ? 8 : 3)
                                            .stroke(
                                                selectedStyle == style ? Theme.branchIndicator : Theme.textMuted.opacity(0.2),
                                                lineWidth: selectedStyle == style ? 2 : 1
                                            )
                                    )
                                Text(style.displayName)
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(selectedStyle == style ? Theme.textPrimary : Theme.textMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 字体选择
                HStack(spacing: 6) {
                    Text("字体")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                    ForEach(availableFonts, id: \.0) { fontId, fontName in
                        Button(action: { selectedFont = fontId }) {
                            Text(fontName)
                                .font(.system(size: Theme.F.caption, weight: selectedFont == fontId ? .semibold : .regular))
                                .foregroundColor(selectedFont == fontId ? Theme.branchIndicator : Theme.textMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(selectedFont == fontId ? Theme.branchIndicator.opacity(0.1) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 文本编辑
                TextEditor(text: $text)
                    .font(noteFont)
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(minHeight: 80, maxHeight: 140)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: selectedStyle == .pinkRounded ? 12 : 4)
                            .fill(selectedStyle.previewColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: selectedStyle == .pinkRounded ? 12 : 4)
                            .stroke(Theme.accent, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebarBg)
            .navigationTitle(isEditMode ? "编辑便签" : "新建便签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditMode ? "更新" : "保存") {
                        confirm()
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            if isEditMode {
                text = initialText
                selectedStyle = initialStyle
            }
            isFocused = true
        }
    }

    private var noteFont: Font {
        switch selectedFont {
        case "Noteworthy": return .custom("Noteworthy", size: 14)
        case "Marker Felt": return .custom("Marker Felt", size: 14)
        case "American Typewriter": return .custom("American Typewriter", size: 13)
        default: return .system(size: 13)
        }
    }

    private func confirm() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed, selectedStyle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            dismiss()
        }
    }
}
