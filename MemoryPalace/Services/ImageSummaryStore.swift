import Foundation

/// 旧图转述省 token（粟粟 M7，兔兔 09-12 拍板一起做）：
/// 用户发过图的消息，三条之前的旧图不再每轮整张 base64 发给模型，换成一句 ≤80 字的描述。
/// 描述由主模型（须能看图）在消息发出后后台生成一次，按 node.id 存这里；没生成好之前照旧发原图。
/// 存 UserDefaults（JSON dict），几百条也就几十 KB。
enum ImageSummaryStore {
    private static let key = "imageSummaries.v1"
    private static var cache: [String: String] = {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }()
    private static var inFlight: Set<String> = []

    static func summary(for nodeId: String) -> String? { cache[nodeId] }

    static func set(_ summary: String, for nodeId: String) {
        cache[nodeId] = summary
        if let d = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// 从 multimodal_text JSON 里把文字块拼出来（转述后用它 + 描述代替整条 JSON）
    static func textPart(of content: String) -> String {
        guard let data = content.data(using: .utf8),
              let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return content }
        return blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    static func hasImage(_ content: String) -> Bool {
        content.hasPrefix("[{") && (content.contains("\"type\":\"image\"") || content.contains("\"type\" : \"image\""))
    }

    /// 后台生成描述：主模型看图，≤80 字，只输出描述。失败静默（下次发消息再试）。
    static func summarizeInBackground(nodeId: String, content: String, model: ProviderModel, providerManager: ProviderManager) {
        guard cache[nodeId] == nil, !inFlight.contains(nodeId), hasImage(content) else { return }
        guard OpenAICompatibleProvider.supportsVision(model: model.modelId) else { return }
        inFlight.insert(nodeId)
        Task.detached(priority: .background) {
            defer { Task { @MainActor in _ = inFlight.remove(nodeId) } }
            // 把图块保留、文字块换成指令
            guard let data = content.data(using: .utf8),
                  var blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            blocks.removeAll { ($0["type"] as? String) == "text" }
            blocks.append(["type": "text", "text": "用不超过 80 个字描述上面这些图片里有什么（主体、场景、文字），只输出描述本身。"])
            guard let json = (try? JSONSerialization.data(withJSONObject: blocks)).flatMap({ String(data: $0, encoding: .utf8) }) else { return }
            do {
                let (reply, _) = try await ProviderRouter().sendNonStreaming(
                    model: model, messages: [(role: "user", content: json)],
                    systemPrompt: nil, providerManager: providerManager)
                let s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { return }
                await MainActor.run {
                    set(String(s.prefix(160)), for: nodeId)
                    BreadcrumbLog.shared.add("🖼️", "旧图转述已存：\(s.prefix(30))…")
                }
            } catch {
                await MainActor.run { BreadcrumbLog.shared.add("🖼️", "旧图转述失败：\(error.localizedDescription)") }
            }
        }
    }
}
