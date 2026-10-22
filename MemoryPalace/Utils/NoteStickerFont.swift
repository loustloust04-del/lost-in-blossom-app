import SwiftUI

/// 编辑、贴纸预览和 PNG 导出共用字体映射；旧便签或未知字体回退默认。
enum NoteStickerFont {
    static func font(_ id: String?, size: CGFloat) -> Font {
        switch id {
        case "Noteworthy": return .custom("Noteworthy", size: size)
        case "Marker Felt": return .custom("Marker Felt", size: size)
        case "American Typewriter": return .custom("American Typewriter", size: size)
        default: return .system(size: size)
        }
    }
}
