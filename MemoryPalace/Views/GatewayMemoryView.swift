import SwiftUI

// MARK: - 网关记忆页（PR-3）
//
// 从后端网关拉取记忆系统数据展示，与粟儿的本地 MemoryPanelView 并列：
//   · 记忆     — GET /api/memories（按 category 分组，标注 tier/heat/来源/gatekeeper）
//   · 做梦日记 — GET /api/memories/dreams（日 / 周 / 月摘要）
//   · 碎碎念   — GET /api/memories/desires（欲望系统生成的念头）
//
// 网关地址 / token 复用全局约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"
// （与 ChatroomService / DesireInboxService 一致）。纯展示，不写本地 SwiftData。

// MARK: 数据模型（对应网关 JSON）

private struct GWMemory: Decodable, Identifiable {
    let id: String
    let content: String
    let category: String?
    let tier: Int?
    let heat: Double?
    let source: String?
    let gatekeeper: String?
    let created_at: String?
}

private struct GWMemoriesResp: Decodable { let memories: [GWMemory] }

private struct GWDream: Decodable, Identifiable {
    let id: String?
    let date: String?
    let layer: String?
    let summary: String?
    var stableId: String { id ?? "\(date ?? "")-\(layer ?? "")" }
}
private struct GWDreamsResp: Decodable { let dreams: [GWDream] }

private struct GWDesire: Decodable, Identifiable {
    let id: String?
    let content: String
    let created_at: String?
    var stableId: String { id ?? "\(created_at ?? "")-\(content.prefix(12))" }
}
private struct GWDesiresResp: Decodable { let desires: [GWDesire] }

// MARK: 网关请求

private enum GatewayMemoryAPI {
    static let fallbackBase = "https://blossom.amberrib.com"

    static func request(path: String, query: [URLQueryItem] = []) -> URLRequest? {
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? fallbackBase
        guard var comps = URLComponents(string: "\(base)\(path)") else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if let token = UserDefaults.standard.string(forKey: "gatewayAuthToken"), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    static func fetch<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let req = request(path: path, query: query) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: 主视图

struct GatewayMemoryView: View {
    private enum Tab: Int, CaseIterable { case memories, dreams, desires
        var title: String {
            switch self {
            case .memories: return "记忆"
            case .dreams: return "做梦日记"
            case .desires: return "碎碎念"
            }
        }
    }

    @State private var tab: Tab = .memories
    @State private var memories: [GWMemory] = []
    @State private var dreams: [GWDream] = []
    @State private var desires: [GWDesire] = []
    @State private var loading = false
    @State private var errorText: String? = nil
    @State private var loadedOnce = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.rawValue) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .onChange(of: tab) { _, _ in Task { await load() } }

            content
        }
        .background(Theme.sidebarBg)
        .task {
            if !loadedOnce { loadedOnce = true; await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && currentIsEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("从网关加载…")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = errorText, currentIsEmpty {
            errorState(err)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case .memories: memoriesList
                    case .dreams: dreamsList
                    case .desires: desiresList
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .refreshable { await load(force: true) }
        }
    }

    private var currentIsEmpty: Bool {
        switch tab {
        case .memories: return memories.isEmpty
        case .dreams: return dreams.isEmpty
        case .desires: return desires.isEmpty
        }
    }

    // MARK: 记忆（按 category 分组）

    private var memoriesList: some View {
        let groups = Dictionary(grouping: memories, by: { $0.category ?? "未分类" })
        let keys = groups.keys.sorted()
        return ForEach(keys, id: \.self) { key in
            sectionHeader(categoryLabel(key), count: groups[key]?.count ?? 0)
            ForEach(groups[key] ?? []) { mem in
                memoryRow(mem)
            }
        }
    }

    private func memoryRow(_ mem: GWMemory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(mem.content)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let tier = mem.tier { tagPill("T\(tier)", Theme.branchIndicator) }
                if let heat = mem.heat { tagPill("热度 \(String(format: "%.1f", heat))", Color(hex: 0xD4A574)) }
                if let s = mem.source { tagPill(sourceLabel(s), Color(hex: 0x9AA7B0)) }
                if let g = mem.gatekeeper { tagPill(gatekeeperLabel(g), gatekeeperColor(g)) }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textPrimary.opacity(0.04)))
    }

    // MARK: 做梦日记（日/周/月）

    private var dreamsList: some View {
        let order: [String] = ["daily", "weekly", "monthly"]
        let grouped = Dictionary(grouping: dreams, by: { dreamPeriod($0.layer) })
        let keys = grouped.keys.sorted { a, b in
            (order.firstIndex(of: a) ?? 9) < (order.firstIndex(of: b) ?? 9)
        }
        return ForEach(keys, id: \.self) { key in
            sectionHeader(dreamPeriodLabel(key), count: grouped[key]?.count ?? 0)
            ForEach(grouped[key] ?? [], id: \.stableId) { d in
                VStack(alignment: .leading, spacing: 4) {
                    if let date = d.date { Text(date).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted) }
                    Text(d.summary ?? "")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textPrimary.opacity(0.04)))
            }
        }
    }

    // MARK: 碎碎念

    private var desiresList: some View {
        ForEach(desires, id: \.stableId) { d in
            VStack(alignment: .leading, spacing: 4) {
                Text(d.content)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let ts = d.created_at {
                    Text(ts).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textPrimary.opacity(0.04)))
        }
    }

    // MARK: 组件

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: Theme.F.caption, weight: .semibold)).foregroundColor(Theme.textMuted)
            Text("\(count)").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted.opacity(0.6))
            Spacer()
        }
        .padding(.top, 6)
    }

    private func tagPill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption - 1))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 22)).foregroundColor(Theme.textMuted.opacity(0.5))
            Text("无法连接网关").font(.system(size: Theme.F.body)).foregroundColor(Theme.textMuted)
            Text(err).font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load(force: true) } }
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: 标签映射

    private func categoryLabel(_ c: String) -> String {
        switch c {
        case "preference": return "偏好"
        case "fact": return "事实"
        case "relationship": return "关系"
        case "goal": return "目标"
        case "context": return "情境"
        default: return c
        }
    }
    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "auto", "inline": return "自动提取"
        case "ai_explicit": return "AI自主写入"
        case "manual": return "手动同步"
        case "dream": return "做梦固化"
        default: return s
        }
    }
    private func gatekeeperLabel(_ g: String) -> String {
        switch g {
        case "inject": return "注入 ✅"
        case "influence": return "影响 🟡"
        case "suppress": return "压抑 ⚫"
        default: return g
        }
    }
    private func gatekeeperColor(_ g: String) -> Color {
        switch g {
        case "inject": return Color(hex: 0x6FAE7A)
        case "influence": return Color(hex: 0xD4A574)
        case "suppress": return Color(hex: 0x8A8F96)
        default: return Theme.textMuted
        }
    }
    private func dreamPeriod(_ layer: String?) -> String {
        let l = (layer ?? "").lowercased()
        if l.contains("month") { return "monthly" }
        if l.contains("week") { return "weekly" }
        return "daily"
    }
    private func dreamPeriodLabel(_ key: String) -> String {
        switch key {
        case "monthly": return "月摘要"
        case "weekly": return "周摘要"
        default: return "日摘要"
        }
    }

    // MARK: 加载

    @MainActor
    private func load(force: Bool = false) async {
        loading = true
        errorText = nil
        do {
            switch tab {
            case .memories:
                memories = try await GatewayMemoryAPI.fetch(GWMemoriesResp.self, path: "/api/memories",
                    query: [URLQueryItem(name: "limit", value: "200")]).memories
            case .dreams:
                dreams = try await GatewayMemoryAPI.fetch(GWDreamsResp.self, path: "/api/memories/dreams").dreams
            case .desires:
                desires = try await GatewayMemoryAPI.fetch(GWDesiresResp.self, path: "/api/memories/desires",
                    query: [URLQueryItem(name: "limit", value: "100")]).desires
            }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - 本地/网关 双轨容器
//
// 右侧面板「记忆」工具里用分段控件并列两个轨道：
//   本地记忆 = 粟儿的 MemoryPanelView（不改动）
//   网关记忆 = GatewayMemoryView

struct MemoryDualTrackView: View {
    var viewModel: ConversationViewModel
    @State private var track: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $track) {
                Text("本地记忆").tag(0)
                Text("网关记忆").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if track == 0 {
                MemoryPanelView(viewModel: viewModel)
            } else {
                GatewayMemoryView()
            }
        }
        .background(Theme.sidebarBg)
    }
}
