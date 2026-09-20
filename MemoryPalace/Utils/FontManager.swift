import SwiftUI
import CoreText

/// Manages custom font import, registration, and selection.
enum FontManager {
    /// Directory for user-imported fonts
    static var fontsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MemoryPalace/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Built-in font options
    /// 说明：app bundle 内打包了 LXGWWenKai-Regular / SourceHanSerifSC-Regular（OFL 协议）
    static let presetFonts: [(name: String, displayName: String)] = [
        ("", "系统默认"),
        ("PingFangSC-Light", "苹方 Light"),
        ("PingFangSC-Regular", "苹方 Regular"),
        ("PingFangSC-Medium", "苹方 Medium"),
        ("PingFangSC-Semibold", "苹方 Semibold"),
        ("LXGWWenKai-Regular", "霞鹜文楷"),
        ("SourceHanSerifSC-Regular", "思源宋体"),
        ("CormorantGaramond-SemiBold", "Cormorant Garamond"),
    ]

    /// Register fonts bundled with the app (Resources/Fonts/*.ttf|*.otf)
    static func registerBundledFonts() {
        guard let resourceURL = Bundle.main.resourceURL else { return }

        var candidates: [URL] = []
        // bundle 顶层（资源被扁平化时会在这里）
        if let files = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: files)
        }
        // Fonts/ 子目录（保留目录结构时）
        let fontsDir = resourceURL.appendingPathComponent("Fonts", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDir,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: files)
        }

        for url in candidates where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Register all user-imported fonts at app launch
    static func registerImportedFonts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// Import a font file, copy to app fonts directory, register it
    @discardableResult
    static func importFont(from sourceURL: URL) -> String? {
        let dest = fontsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        if !FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                return nil
            }
        }

        CTFontManagerRegisterFontsForURL(dest as CFURL, .process, nil)

        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(dest as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else {
            return nil
        }

        return name
    }

    /// List user-imported fonts
    static func importedFonts() -> [(fileName: String, fontName: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var result: [(String, String)] = []
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
               let first = descriptors.first,
               let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
                let displayName = CTFontDescriptorCopyAttribute(first, kCTFontDisplayNameAttribute) as? String ?? name
                result.append((displayName, name))
            }
        }
        return result
    }

    /// Delete an imported font file by PostScript name
    static func deleteFont(named fontName: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
               let first = descriptors.first,
               let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String,
               name == fontName {
                CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
                try? FileManager.default.removeItem(at: file)
                return
            }
        }
    }

    /// Get a Font for the given settings
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = UserDefaults.standard.string(forKey: "selectedFont") ?? ""
        let scale = UserDefaults.standard.double(forKey: "fontScale")
        let effectiveScale = scale > 0 ? scale : 1.0
        let scaledSize = size * effectiveScale

        if fontName.isEmpty {
            return .system(size: scaledSize, weight: weight)
        } else {
            return .custom(fontName, size: scaledSize)
        }
    }
}
