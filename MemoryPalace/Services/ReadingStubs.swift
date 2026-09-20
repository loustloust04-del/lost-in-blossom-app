import Foundation
import SwiftData
import PDFKit

// MARK: - 共读系统 no-op 替身（TASK-READER：本次只搬「能看书」）
// 批注抽屉 / 问 AI / 在场信号 / 生词本 / OCR 划词的真身后续从粟粟单独搬，
// 届时删掉本文件、恢复 BookReaderSheet 里注释掉的 UI 入口即可。
// 这些替身让阅读器核心（书架/翻章/进度/书签/笔记/高亮）不用大改保持原结构。

/// 在场信号（共读心跳/事件上报）——替身：静默丢弃
enum ReadingSignals {
    static func logTick(bookSafeName: String, bookDisplayName: String, chapter: Int, profileId: String) {}
    static func logEvent(type: String, book: String, chapter: Int, word: String? = nil, profileId: String) {}
    static func buildPersonaPackage(profile: Profile, context: ModelContext) -> String { "" }
}

/// 生词本——替身：不收集、无已收词（阅读器里生词虚线不出现）
enum VocabCollector {
    /// 思考链弹窗打开请求（粟粟 ThinkingSheet 的 onReceive 挂着；我们无人发送=静默）
    static let openThinkingNotification = Notification.Name("vocabOpenThinkingRequested")
    static func collectedWords(context: ModelContext) -> [String] { [] }
    static func collect(rawText: String, bookSafeName: String, chapter: Int, anchorStart: Int, context: ModelContext) -> String? { nil }
}

// OCRStore / BookOCRIndexer 的真身已从粟粟搬入（2026-08-12）：
// MemoryPalace/Services/OCRStore.swift + BookOCRIndexer.swift。
// 此前是替身（识别不到任何行），所以扫描版 PDF 框选永远提示"框里没认出文字"，
// 批注入口够不到——兔兔实测「PDF 导入了但没法批注」就是这个。

// MARK: - 阅读器通知名（真身在共读系统里 post；现在只有 onReceive 挂着，无人发送=静默）
extension Notification.Name {
    static let bookNotesDidChange = Notification.Name("mp.bookNotesDidChange")
    static let openVocabTool = Notification.Name("mp.openVocabTool")
    // bookTextLayerReady 由 BookOCRIndexer.swift 定义（真身自带），此处删除避免重复声明
}

// MARK: - 外链跳系统浏览器（粟粟 WebViewHost.swift 的通用 helper，我们没搬那个文件，抄函数）
import UIKit
func openExternalWebViewLink(_ href: String?) {
    guard let href,
          let url = URL(string: href),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme) else {
        return
    }
    UIApplication.shared.open(url)
}
