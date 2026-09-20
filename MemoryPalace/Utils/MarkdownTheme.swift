import SwiftUI
import UIKit
import MarkdownUI

extension MarkdownUI.Theme {
    static func memoryPalace(
        fontName: String = "",
        scale: CGFloat = 1.0,
        lineSpacingScale: CGFloat = 1.0,
        paragraphSpacingScale: CGFloat = 1.0
    ) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            // MARK: - Text Styles
            .text {
                if !fontName.isEmpty {
                    FontFamily(.custom(fontName))
                }
                ForegroundColor(Theme.textPrimary)
                FontSize(13.5 * scale)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                ForegroundColor(Theme.textPrimary)
                BackgroundColor(Theme.accent.opacity(0.72))
            }
            .link {
                ForegroundColor(Theme.branchIndicator)
            }
            .strong {
                FontWeight(.semibold)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if !fontName.isEmpty {
                            FontFamily(.custom(fontName))
                        }
                        FontSize(20 * scale)
                        FontWeight(.bold)
                        ForegroundColor(Theme.textPrimary)
                    }
                    .markdownMargin(top: 32, bottom: 16)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if !fontName.isEmpty {
                            FontFamily(.custom(fontName))
                        }
                        FontSize(17 * scale)
                        FontWeight(.semibold)
                        ForegroundColor(Theme.textPrimary)
                    }
                    .markdownMargin(top: 28, bottom: 14)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        if !fontName.isEmpty {
                            FontFamily(.custom(fontName))
                        }
                        FontSize(15 * scale)
                        FontWeight(.semibold)
                        ForegroundColor(Theme.textPrimary)
                    }
                    .markdownMargin(top: 24, bottom: 12)
            }
            // MARK: - Block Styles
            .paragraph { configuration in
                configuration.label
                    // 行间距：scale 必须在这里乘进去。外层 SwiftUI .lineSpacing()
                    // 会被 relativeLineSpacing 内层覆盖（离 Text 更近的 .lineSpacing 优先生效）。
                    .relativeLineSpacing(.em(0.42 * lineSpacingScale))
                    // 段间距：top 留 0、bottom 给 12 * scale。BlockSequence 的 topPaddingLength
                    // 对第一个 block 强制返回 0、最后一个 block 不加 bottom padding，所以 bottom 不会
                    // 漏到气泡边缘。之前以为"bottom: 12 导致气泡底部多一截"是误判，实际来自空 HStack。
                    .markdownMargin(top: 0, bottom: 12 * paragraphSpacingScale)
            }
            .codeBlock { configuration in
                ZStack(alignment: .topTrailing) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        configuration.label
                            .relativeLineSpacing(.em(0.25))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.85))
                                ForegroundColor(Theme.textPrimary)
                            }
                            .padding(12)
                    }
                    .background(Theme.mainBg.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button {
                        UIPasteboard.general.string = configuration.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                            .padding(8)
                    }
                }
                .markdownMargin(top: 8, bottom: 8)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(Theme.textSecondary)
                        FontSize(13 * scale)
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.branchIndicator.opacity(0.6))
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 4, bottom: 8)
            }
            .thematicBreak {
                Rectangle()
                    .fill(Theme.accent.opacity(0.6))
                    .frame(height: 0.5)
                    .padding(.horizontal, 48)
                    .markdownMargin(top: 28, bottom: 28)
            }
            .list { configuration in
                configuration.label
                    .markdownMargin(top: 12, bottom: 12)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.55))
            }
            // MARK: - Table Styles
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(
                        TableBorderStyle(
                            .horizontalBorders,
                            color: Theme.accent.opacity(0.9),
                            width: 0.5
                        )
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Theme.mainBg,
                            Theme.accent.opacity(0.22),
                            header: Theme.accent.opacity(0.38)
                        )
                    )
                    .markdownMargin(top: 10, bottom: 14)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.25))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
    }
}
