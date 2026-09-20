import Foundation
import MarkdownUI

/// Markdown 解析缓存 + 预热（B round 10）。
/// 兔兔 09-15：「百多条往上滑会整个卡死一下，上下左右都动不了」——那是主线程在同一帧里
/// 给一批新挂上的气泡做 Markdown 解析（cmark 解析 + 内联树），一批 24 条也能卡出几百毫秒。
/// 解析结果（MarkdownContent，值类型）按「节点 id + 文本长度」缓存；窗口扩到哪，就在后台线程
/// 提前把下一批解析好，滑到时只剩布局。解析本身不依赖主线程；NSCache 线程安全。
enum MarkdownParseCache {
    private final class Box { let content: MarkdownContent; init(_ c: MarkdownContent) { content = c } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 600
        return c
    }()

    static func key(nodeId: String, text: String) -> String { "\(nodeId)_\(text.count)" }

    /// 命中直接返回；未命中就地解析并存入（和以前一样在主线程，只是只做一次）
    static func content(nodeId: String, text: String) -> MarkdownContent {
        let k = key(nodeId: nodeId, text: text) as NSString
        if let b = cache.object(forKey: k) { return b.content }
        let c = MarkdownContent(text)
        cache.setObject(Box(c), forKey: k)
        return c
    }

    /// 后台预热：给即将进入渲染窗口的节点提前解析。已缓存的跳过。
    static func prewarm(_ items: [(nodeId: String, text: String)]) {
        let todo = items.filter { cache.object(forKey: key(nodeId: $0.nodeId, text: $0.text) as NSString) == nil }
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for it in todo {
                let k = key(nodeId: it.nodeId, text: it.text) as NSString
                if cache.object(forKey: k) != nil { continue }
                cache.setObject(Box(MarkdownContent(it.text)), forKey: k)
            }
        }
    }
}
