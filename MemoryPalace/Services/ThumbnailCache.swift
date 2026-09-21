import UIKit

/// 缩略图缓存（09-20）：气泡里的图**只解码一次、只按缩略尺寸解码**。
/// 兔兔：「第一次发九张，第二次再发很多图，有概率整个聊天窗卡死」——根因是每次 body 重算都
/// 对每张原图跑一遍 UIImage(data:)＋按原分辨率解码（几张 4000×3000 就是几百 MB 像素和几百毫秒
/// 主线程），图越多越卡，卡住期间任何手势都没人理。
/// 这里用 ImageIO 直接生成缩略图（thumbnailFromImageAlways），按 数据长度+目标边长 缓存。
enum ThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        c.totalCostLimit = 64 * 1024 * 1024   // 约 64MB 像素
        return c
    }()

    static func thumbnail(for data: Data, maxPixel: CGFloat, scale: CGFloat = UIScreen.main.scale) -> UIImage? {
        let px = Int(maxPixel * scale)
        let key = "\(data.count)_\(data.hashValue)_\(px)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
        return img
    }
}
