import SwiftUI
import WebKit

// MARK: - Artifact Types

enum ArtifactType {
    case html
    case svg
    case mermaid

    var label: String {
        switch self {
        case .html: return "HTML"
        case .svg: return "SVG"
        case .mermaid: return "Mermaid"
        }
    }

    var icon: String {
        switch self {
        case .html: return "globe"
        case .svg: return "scribble.variable"
        case .mermaid: return "arrow.triangle.branch"
        }
    }
}

struct ArtifactContent {
    let code: String
    let type: ArtifactType
}

// MARK: - Artifact Detector

enum ArtifactDetector {

    /// Scans markdown content for the first renderable code block.
    static func find(in content: String) -> ArtifactContent? {
        let lines = content.components(separatedBy: "\n")
        var inBlock = false
        var blockLang = ""
        var blockLines: [String] = []

        for line in lines {
            if !inBlock {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                guard stripped.hasPrefix("```") else { continue }
                let lang = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                inBlock = true
                blockLang = lang
                blockLines = []
            } else {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    let code = blockLines.joined(separator: "\n")
                    if let artifact = classify(code: code, lang: blockLang) {
                        return artifact
                    }
                    inBlock = false
                    blockLang = ""
                    blockLines = []
                } else {
                    blockLines.append(line)
                }
            }
        }
        return nil
    }


    /// 从内容中移除第一个可渲染代码块，返回剩余内容。
    static func stripFirst(in content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var inBlock = false
        var blockLang = ""
        var blockStartIdx = 0
        var blockLines: [String] = []
        var removed = false

        for (i, line) in lines.enumerated() {
            if removed {
                result.append(line)
                continue
            }
            if !inBlock {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.hasPrefix("```") {
                    let lang = String(stripped.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    inBlock = true
                    blockLang = lang
                    blockStartIdx = i
                    blockLines = []
                } else {
                    result.append(line)
                }
            } else {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    let code = blockLines.joined(separator: "\n")
                    if classify(code: code, lang: blockLang) != nil {
                        removed = true
                    } else {
                        result.append(lines[blockStartIdx])
                        result.append(contentsOf: blockLines)
                        result.append(line)
                    }
                    inBlock = false
                    blockLang = ""
                    blockLines = []
                } else {
                    blockLines.append(line)
                }
            }
        }

        if inBlock {
            result.append(lines[blockStartIdx])
            result.append(contentsOf: blockLines)
        }

        return result.joined(separator: "\n")
    }

    static func classify(code: String, lang: String) -> ArtifactContent? {
        switch lang {
        case "html": return ArtifactContent(code: code, type: .html)
        case "svg": return ArtifactContent(code: code, type: .svg)
        case "mermaid": return ArtifactContent(code: code, type: .mermaid)
        default:
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<html") {
                return ArtifactContent(code: code, type: .html)
            }
            if trimmed.hasPrefix("<svg") {
                return ArtifactContent(code: code, type: .svg)
            }
            return nil
        }
    }
}

// MARK: - WKWebView Wrapper

struct ArtifactCanvasView: UIViewRepresentable {
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
}

// MARK: - Artifact Card (inline in bubble)

struct ArtifactCardView: View {
    let artifact: ArtifactContent
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.branchIndicator.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: artifact.type.icon)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.branchIndicator)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Artifact · \(artifact.type.label)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text("点击预览")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }

            Spacer()

            Button {
                UIPasteboard.general.string = artifact.code
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.textMuted.opacity(0.15), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - Artifact Canvas Sheet

struct ArtifactCanvasSheet: View {
    let artifact: ArtifactContent
    @Environment(\.dismiss) private var dismiss

    private var renderedHTML: String {
        switch artifact.type {
        case .html:
            let trimmed = artifact.code.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<html") {
                return artifact.code
            }
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:16px;font-family:-apple-system,sans-serif;font-size:14px;line-height:1.5;}</style>
            </head>
            <body>
            \(artifact.code)
            </body>
            </html>
            """
        case .svg:
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:0;display:flex;justify-content:center;align-items:flex-start;padding:16px;box-sizing:border-box;background:#fff;}svg{max-width:100%;height:auto;}</style>
            </head>
            <body>
            \(artifact.code)
            </body>
            </html>
            """
        case .mermaid:
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:16px;font-family:-apple-system,sans-serif;}</style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            </head>
            <body>
            <div class="mermaid">
            \(artifact.code)
            </div>
            <script>mermaid.initialize({startOnLoad:true,theme:'default'});</script>
            </body>
            </html>
            """
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: artifact.type.icon)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                    Text(artifact.type.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }

                Spacer()

                Button {
                    UIPasteboard.general.string = artifact.code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.2)

            ArtifactCanvasView(htmlContent: renderedHTML)
        }
        .background(Color(UIColor.systemBackground))
        .presentationDetents([.medium, .large])
    }
}
