import Foundation
import SwiftData
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// 发语音条：```voice 意向协议（零新窄工具，模式同 AgentBookNoteWriter 的 ```book-note）。
///
/// AI 在回复里输出 ```voice 块（内容 = 表演脚本，≠ 气泡正文），turn 收口时本类把块
/// 变成占位行、异步走 ElevenLabs 生成 mp3、落文件库、往 node 挂 .audioRef segment。
/// 失败时占位行替换成灰字失败行（脚本原文保住）。流式期间块可见 = 「TA 在录语音」。
enum VoiceMessageWriter {

    static let placeholderLine = "🎤 语音条生成中…"

    // MARK: - 待办登记（防后台冻结）
    /// iOS 会在 App 进后台数秒后冻结进程：合成请求虽已返回，收尾代码却没机会跑，
    /// 占位行就永久卡住（兔兔发完就切走跟别人说话 = 每次必中）。
    /// 这里把 script 落 UserDefaults，回前台时续跑；配合 beginBackgroundTask 争取收尾时间。
    /// 这条消息是否处于「语音条生成中」（渲染层据此画成型态胶囊，而非露出占位文字）
    @MainActor
    static func isPending(node: MessageNode) -> Bool {
        if node.content.contains(placeholderLine) { return true }
        return node.segments?.contains(where: {
            if case .text(let t) = $0 { return t.contains(placeholderLine) }
            return false
        }) ?? false
    }

    /// 从展示文本里摘掉占位行（它已由胶囊代言）
    static func strippedForDisplay(_ text: String) -> String {
        guard text.contains(placeholderLine) else { return text }
        var out = text.replacingOccurrences(of: placeholderLine, with: "")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 流水线埋点：只发步骤名（无脚本无内容），落 nginx access.log，用于定位卡死位置。
    /// 排障期临时件，链路稳定后删。
    static func dbg(_ step: String) {
        let safe = step.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        guard let url = URL(string: "https://blossom.amberrib.com/vdbg/\(safe)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    private static let pendingKey = "voice.pendingScripts"
    private static let maxAttempts = 3

    private static func pendingLoad() -> [String: [String: Any]] {
        (UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: [String: Any]]) ?? [:]
    }
    private static func pendingPut(nodeId: String, script: String) {
        var d = pendingLoad()
        let attempts = (d[nodeId]?["n"] as? Int) ?? 0
        d[nodeId] = ["script": script, "n": attempts]
        UserDefaults.standard.set(d, forKey: pendingKey)
    }
    private static func pendingBumpAttempt(nodeId: String) {
        var d = pendingLoad()
        guard var item = d[nodeId] else { return }
        item["n"] = ((item["n"] as? Int) ?? 0) + 1
        d[nodeId] = item
        UserDefaults.standard.set(d, forKey: pendingKey)
    }
    private static func pendingClear(nodeId: String) {
        var d = pendingLoad()
        d.removeValue(forKey: nodeId)
        UserDefaults.standard.set(d, forKey: pendingKey)
    }

    /// App 回前台时调用：把被冻死的语音条续上（占位行还在的才跑）
    @MainActor
    static func resumePending(context: ModelContext) {
        let pend = pendingLoad()
        guard !pend.isEmpty else { return }
        let profiles = profilesProvider()
        let key = apiKeyProvider()
        for (nodeId, item) in pend {
            guard let script = item["script"] as? String, !script.isEmpty else { pendingClear(nodeId: nodeId); continue }
            guard ((item["n"] as? Int) ?? 0) < maxAttempts else { pendingClear(nodeId: nodeId); continue }
            guard let node = fetchNode(nodeId, context: context) else { pendingClear(nodeId: nodeId); continue }
            // 占位行不在了 = 已经成功或已改成失败行，不重跑
            let stillPending = node.content.contains(placeholderLine)
                || (node.segments?.contains(where: {
                    if case .text(let t) = $0 { return t.contains(placeholderLine) }
                    return false
                }) ?? false)
            guard stillPending else { pendingClear(nodeId: nodeId); continue }
            guard let voiceId = profiles.first(where: { $0.id == node.profileId })?.elevenVoiceId,
                  !voiceId.isEmpty, let key, !key.isEmpty else { continue }
            pendingBumpAttempt(nodeId: nodeId)
            generate(script: script, nodeId: nodeId, voiceId: voiceId, apiKey: key, context: context)
        }
    }
    /// 脚本长度上限（攻略纪律 60–120 字；超长截断防误写整篇）
    static let scriptCap = 1000

    private static let intentRegex = try! NSRegularExpression(
        pattern: "```voice\\s*\\n([\\s\\S]*?)```",
        options: []
    )

    // 测试注入点
    /// 当前后端实例（测试可注入）。默认按 VoiceTuning.provider 选，切后端不改调用方。
    static var clientOverride: TTSBackend? = nil
    static var client: TTSBackend {
        if let clientOverride { return clientOverride }
        switch VoiceTuning.provider {
        case .elevenLabs: return ElevenLabsClient()
        case .miniMax: return MiniMaxClient()
        }
    }
    /// key 按后端分开存，切换不用重填
    static var apiKeyProvider: () -> String? = { KeychainStore.get(account: VoiceTuning.provider.keychainAccount) }
    static var proactiveEnabledProvider: () -> Bool = { UserDefaults.standard.bool(forKey: VoiceTuning.proactiveKey) }
    /// 无 ProfileManager 引用的调用点（CC 主动消息 / 换一版）用；测试注入假楼层防污染真 UserDefaults
    static var profilesProvider: () -> [Profile] = { ProfileManager.loadProfiles() }

    /// 生成中的 node（占位/换一版共用，防重入）
    @MainActor static private(set) var inFlight = Set<String>()

    // MARK: - 收口入口

    /// assistant turn 收口时调（ContentView .assistantTurnDidFinish 订阅者）。
    /// 无块零成本；块被消费后不再匹配 = 天然幂等。
    @MainActor
    static func processChatIntents(nodeId: String, context: ModelContext, profiles: [Profile]) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first,
              node.role == "assistant" else { return }

        // 块可能在两个容器：content（普通消息）和 segments 的 .text 段（工具轮/segmented 消息正文副本）。
        // CC 走工具循环 → 回复几乎必为 segmented；只消费 content 会让渲染把残留块画成代码卡片 = 语音条出不来。
        let segs = node.segments
        let blockInContent = node.content.contains("```voice")
        let blockInSegments = segs?.contains(where: {
            if case .text(let t) = $0 { return t.contains("```voice") }
            return false
        }) ?? false
        guard blockInContent || blockInSegments else { return }

        let profile = profiles.first { $0.id == node.profileId }
        let key = apiKeyProvider()
        let voiceId = profile?.elevenVoiceId
        let script = firstScript(content: node.content, segments: segs) ?? ""
        let canGenerate = proactiveEnabledProvider()
            && !(key ?? "").isEmpty && !(voiceId ?? "").isEmpty && !script.isEmpty
        dbg(canGenerate ? "p1-can-yes" : "p1-can-no")

        // 降级要说明理由：此前静默摊成台词文字，用户完全不知道差哪一步（"只出台词没语音条"）
        var degradeNote: String? = nil
        if !canGenerate {
            if !proactiveEnabledProvider() { degradeNote = "语音条没发出（设置→声音里「主动语音」还没开）" }
            else if (key ?? "").isEmpty { degradeNote = "语音条没发出（还没填 ElevenLabs key）" }
            else if (voiceId ?? "").isEmpty { degradeNote = "语音条没发出（这个楼层还没选音色——音色按楼层保存，要在跟他聊天的这层选）" }
            else { degradeNote = "语音条没发出（脚本是空的）" }
        }

        // 两容器同步消费
        node.content = consumeVoiceBlocks(in: node.content, canGenerate: canGenerate, degradeNote: degradeNote)
        if var segs2 = segs, blockInSegments {
            for i in segs2.indices {
                if case .text(let t) = segs2[i], t.contains("```voice") {
                    segs2[i] = .text(consumeVoiceBlocks(in: t, canGenerate: canGenerate, degradeNote: degradeNote))
                }
            }
            node.setSegments(segs2)
        }
        try? context.save()

        guard canGenerate, let key, let voiceId else { return }
        generate(script: script, nodeId: nodeId, voiceId: voiceId, apiKey: key, context: context)
    }

    /// 首块脚本：content 优先，没有再扫 segments 的 .text（两容器是同一文本的副本）
    private static func firstScript(content: String, segments: [MessageSegment]?) -> String? {
        var candidates = [content]
        for seg in segments ?? [] {
            if case .text(let t) = seg { candidates.append(t) }
        }
        for c in candidates {
            let ns = c as NSString
            let ms = intentRegex.matches(in: c, range: NSRange(location: 0, length: ns.length))
            if let first = ms.first {
                let body = String(ns.substring(with: first.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(scriptCap))
                if !body.isEmpty { return body }
            }
        }
        return nil
    }

    /// 消费一段文本里的所有 voice 块：首块 → 占位行（可生成）/ 脚本文字（降级）；多余块 → 脚本文字。
    /// 倒序替换保 range 有效。
    private static func consumeVoiceBlocks(in text: String, canGenerate: Bool, degradeNote: String? = nil) -> String {
        let ns = text as NSString
        let matches = intentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for (idx, m) in Array(matches.enumerated()).reversed() {
            let body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            var replacement: String
            if idx == 0 && canGenerate {
                replacement = placeholderLine
            } else if idx == 0, let note = degradeNote {
                let quoted = body.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                replacement = "> 🎤 \(note)\n\(quoted)"
            } else {
                replacement = body
            }
            out = (out as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return out
    }

    /// 在 content + segments 两容器里同时替换占位行（失败行/清占位共用）
    @MainActor
    private static func replacePlaceholderEverywhere(node: MessageNode, with replacement: String) {
        node.content = node.content.replacingOccurrences(of: placeholderLine, with: replacement)
        if var segs = node.segments {
            var touched = false
            for i in segs.indices {
                if case .text(let t) = segs[i], t.contains(placeholderLine) {
                    segs[i] = .text(t.replacingOccurrences(of: placeholderLine, with: replacement))
                    touched = true
                }
            }
            if touched { node.setSegments(segs) }
        }
    }

    // MARK: - 换一版

    /// 语音条胶囊菜单「换一版」：拿 segment 里存的脚本重跑 TTS，原地换文件。
    @MainActor
    static func regenerate(nodeId: String, context: ModelContext) {
        guard !inFlight.contains(nodeId),
              let node = fetchNode(nodeId, context: context),
              let segs = node.segments,
              let audioIdx = segs.firstIndex(where: {
                  if case .audioRef = $0 { return true } else { return false }
              }),
              case .audioRef(_, _, let oldPath, _, let script?) = segs[audioIdx],
              !script.isEmpty,
              let key = apiKeyProvider(), !key.isEmpty else {
            ToastCenter.shared.show("换不了：脚本或 key 不在")
            return
        }
        // voice 用 node 所在楼层当前配置（楼层可能换过声音——换一版跟新声音走）
        guard let profile = profilesProvider().first(where: { $0.id == node.profileId }),
              let voiceId = profile.elevenVoiceId, !voiceId.isEmpty else {
            ToastCenter.shared.show("这个楼层还没选声音")
            return
        }

        inFlight.insert(nodeId)
        ToastCenter.shared.show("正在换一版…")
        Task { @MainActor in
            defer { inFlight.remove(nodeId) }
            do {
                let audio = try await client.synthesize(script: script, voiceId: voiceId, apiKey: key)
                guard let node = fetchNode(nodeId, context: context), var segs = node.segments else { return }
                let (path, duration) = try persistAudio(audio, node: node, context: context)
                // 删旧文件（失败不阻断——孤儿文件无害）
                if let old = FileLibraryStore.absoluteURL(oldPath, profileId: node.profileId) {
                    try? FileManager.default.removeItem(at: old)
                }
                if let idx = segs.firstIndex(where: {
                    if case .audioRef = $0 { return true } else { return false }
                }) {
                    segs[idx] = .audioRef(
                        name: (path as NSString).lastPathComponent, mime: "audio/mpeg",
                        path: path, duration: duration, script: script
                    )
                    node.setSegments(segs)
                    try? context.save()
                    ToastCenter.shared.show("换好了")
                }
            } catch {
                ToastCenter.shared.show("换一版没成功（\(shortPhrase(error))）")
            }
        }
    }

    // MARK: - 生成

    @MainActor
    private static func generate(script: String, nodeId: String, voiceId: String, apiKey: String, context: ModelContext) {
        guard !inFlight.contains(nodeId) else { return }
        inFlight.insert(nodeId)
        pendingPut(nodeId: nodeId, script: script)
        // 向系统申请一段后台执行时间：切走跟别人聊天时也能把收尾跑完
        #if canImport(UIKit)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "voice-tts") {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        #endif
        dbg("g0-enter")
        Task { @MainActor in
            defer {
                dbg("g9-defer")
                inFlight.remove(nodeId)
                #if canImport(UIKit)
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
                #endif
            }
            do {
                let audio = try await client.synthesize(script: script, voiceId: voiceId, apiKey: apiKey)
                dbg("g1-http-ok-\(audio.count)")
                // 收尾时 node 可能已被删/换楼层。此前静默 return → 占位行永久卡住且零线索，
                // 现在给可见反馈（音频已到手，只是挂不上去）。
                guard let node = fetchNode(nodeId, context: context) else {
                    dbg("g2-node-MISSING")
                    ToastCenter.shared.show("语音生成好了，但找不到那条消息")
                    return
                }
                dbg("g2-node-ok")
                let (path, duration) = try persistAudio(audio, node: node, context: context)
                dbg("g3-persist-ok")
                var segs = node.segments ?? []
                segs.append(.audioRef(
                    name: (path as NSString).lastPathComponent, mime: "audio/mpeg",
                    path: path, duration: duration, script: script
                ))
                node.setSegments(segs)
                dbg("g4-seg-appended")
                removePlaceholder(from: node)
                try context.save()   // 不再 try?：落库失败要走 catch 出反馈，而不是假装成功
                dbg("g5-SAVED")
                pendingClear(nodeId: nodeId)
            } catch {
                dbg("gx-catch-\(shortPhrase(error))")
                // 网络类失败多半是「App 被切到后台，下载被系统掐断」（服务端实测已完整发出音频）。
                // 这种不算终局：保留占位行 + 保留 pending，等回前台 resumePending 自动重试。
                var isNetwork = false
                if let e = error as? ElevenLabsError, case .network = e { isNetwork = true }
                let attempts = (pendingLoad()[nodeId]?["n"] as? Int) ?? 0
                if isNetwork && attempts < maxAttempts {
                    dbg("gx-network-will-retry")
                    ToastCenter.shared.show("语音条被打断了，回头自动重试（别急着切走 App）")
                    return   // 占位行留着，pending 留着
                }
                // 先弹 toast：即使下面 node 捞不到，也不会再出现「什么都没发生」
                ToastCenter.shared.show("语音条没成功（\(shortPhrase(error))）")
                guard let node = fetchNode(nodeId, context: context) else { return }
                let quoted = script.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                let failLine = "> 🎤 语音条没成功（\(shortPhrase(error))）\n\(quoted)"
                replacePlaceholderEverywhere(node: node, with: failLine)
                try? context.save()
                pendingClear(nodeId: nodeId)
            }
        }
    }

    /// mp3 落文件库（attachments/{对话目录}/voice-*.mp3），返回 (相对路径, 时长)
    private static func persistAudio(_ audio: Data, node: MessageNode, context: ModelContext) throws -> (String, Double?) {
        let stamp = Self.fileStampFormatter.string(from: Date())
        let path = try AttachmentStore.save(
            fileName: "voice-\(stamp).mp3", data: audio,
            conversationId: node.conversationId,
            conversationTitle: conversationTitle(node: node, context: context),
            profileId: node.profileId
        )
        var duration: Double? = nil
        if let url = FileLibraryStore.absoluteURL(path, profileId: node.profileId),
           let player = try? AVAudioPlayer(contentsOf: url),
           player.duration.isFinite, player.duration > 0 {
            duration = player.duration
        }
        return (path, duration)
    }

    @MainActor
    private static func removePlaceholder(from node: MessageNode) {
        replacePlaceholderEverywhere(node: node, with: "")
        // 清占位行留下的连续空行
        var content = node.content
        while content.contains("\n\n\n") { content = content.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        node.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if var segs = node.segments {
            var touched = false
            for i in segs.indices {
                if case .text(var t) = segs[i] {
                    while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if case .text(let orig) = segs[i], orig != trimmed { segs[i] = .text(trimmed); touched = true }
                }
            }
            if touched { node.setSegments(segs) }
        }
    }

    private static func fetchNode(_ nodeId: String, context: ModelContext) -> MessageNode? {
        let desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        return (try? context.fetch(desc))?.first
    }

    private static func conversationTitle(node: MessageNode, context: ModelContext) -> String? {
        let convId = node.conversationId
        let desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })
        return (try? context.fetch(desc))?.first?.title
    }

    private static func shortPhrase(_ error: Error) -> String {
        (error as? ElevenLabsError)?.shortPhrase ?? "出了点问题"
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
