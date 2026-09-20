import Foundation
import SwiftData

/// 亲密卡双向同步。原本纯本地、他读不到——兔兔 2026-08-02 拍板改为共享：
/// 备注共用一个框，她写他也写。这是她主动开的门。
enum IntimacySyncService {
    private static var base: String {
        UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    }
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); return f
    }()

    /// 她改了 → 推上去
    static func push(date: Date, note: String, myNote: String? = nil,
                     tags: [String]? = nil, milestone: String? = nil, deleted: Bool = false) {
        guard let url = URL(string: "\(base)/api/intimacy?key=bunny-lib-2026") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        var body: [String: Any] = ["date": stamp.string(from: date), "note": note, "deleted": deleted]
        if let myNote { body["myNote"] = myNote }
        if let tags { body["tags"] = tags }
        if let milestone { body["milestone"] = milestone }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private struct Remote: Codable { let date: String; let note: String; var myNote: String? = nil; var tags: [String]? = nil; var milestone: String? = nil; let updatedBy: String; let updatedAt: String }
    private struct Wrap: Codable { let entries: [String: Remote] }

    /// 他改了 → 拉下来（打开健康面板/亲密详情时调）
    @MainActor
    static func pull(context: ModelContext, profileId: String) async {
        guard let url = URL(string: "\(base)/api/intimacy?key=bunny-lib-2026") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { return }

        var changed = false
        for (_, r) in wrap.entries {
            guard r.updatedBy == "caelum", let d = stamp.date(from: r.date) else { continue }
            let day = Calendar.current.startOfDay(for: d)
            if let existing = HealthLogStore.fetchIntimacy(context: context, profileId: profileId, date: day) {
                // 本地刚改过、还没推上去 → 以本地为准，别被服务器旧值冲掉（同药物同步那个坑）
                if let edited = existing.localEditedAt,
                   let remoteAt = ISO8601DateFormatter().date(from: r.updatedAt),
                   edited > remoteAt {
                    continue
                }
                if existing.note != r.note { existing.note = r.note; changed = true }
                if let t = r.tags, existing.tags != t { existing.tags = t; changed = true }
                if let ms = r.milestone, existing.milestone != ms { existing.milestone = ms; changed = true }
            } else if !r.note.isEmpty {
                // 他写了备注但她那天还没点心——也建一条，让她看得到他写的
                context.insert(IntimacyEntry(profileId: profileId, date: day, note: r.note))
                changed = true
            }
        }
        if changed { try? context.save() }
    }
}
