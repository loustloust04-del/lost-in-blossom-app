import SwiftUI

// MARK: - Token 统计数据

struct TokenRecord: Codable {
    let date: Date
    let model: String
    let conversationId: String
    let conversationTitle: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cost: Double          // 估算花费（美元）
    let responseTime: Double  // 秒
}

/// UserDefaults 持久化（key: tokenRecords）。
enum TokenStatsStore {
    static let key = "tokenRecords"
    private static let maxRecords = 2000

    static func load() -> [TokenRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TokenRecord].self, from: data)) ?? []
    }

    static func save(_ records: [TokenRecord]) {
        let trimmed = records.count > maxRecords ? Array(records.suffix(maxRecords)) : records
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func append(_ record: TokenRecord) {
        var all = load()
        all.append(record)
        save(all)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - 页面

struct TokenStatsView: View {
    @State private var records: [TokenRecord] = []

    private var totalInput: Int { records.reduce(0) { $0 + $1.inputTokens } }
    private var totalOutput: Int { records.reduce(0) { $0 + $1.outputTokens } }
    private var totalCacheRead: Int { records.reduce(0) { $0 + $1.cacheReadTokens } }
    private var totalCacheWrite: Int { records.reduce(0) { $0 + $1.cacheWriteTokens } }
    private var totalCost: Double { records.reduce(0) { $0 + $1.cost } }

    /// 命中率 = 缓存读 / (缓存读 + 未缓存输入)
    private var cacheHitRate: Double {
        let denom = Double(totalCacheRead + totalInput)
        return denom > 0 ? Double(totalCacheRead) / denom : 0
    }

    /// 节省估算：缓存读 token 若按全价是 1.0×，命中只付 0.1×，省 0.9×。按 ~$3/M 输入粗估。
    private var estimatedSaved: Double {
        Double(totalCacheRead) / 1_000_000.0 * 3.0 * 0.9
    }

    private var avgResponseTime: Double {
        guard !records.isEmpty else { return 0 }
        let withTime = records.filter { $0.responseTime > 0 }
        guard !withTime.isEmpty else { return 0 }
        return withTime.reduce(0) { $0 + $1.responseTime } / Double(withTime.count)
    }

    private struct ModelStat: Identifiable {
        let id: String
        var rounds: Int = 0
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cost: Double = 0
    }

    private var byModel: [ModelStat] {
        var map: [String: ModelStat] = [:]
        for r in records {
            var st = map[r.model] ?? ModelStat(id: r.model)
            st.rounds += 1
            st.input += r.inputTokens
            st.output += r.outputTokens
            st.cacheRead += r.cacheReadTokens
            st.cost += r.cost
            map[r.model] = st
        }
        return map.values.sorted { $0.cost > $1.cost }
    }

    // MARK: - 近 7 天趋势（P1-1）

    private struct DayStat: Identifiable {
        let id: String       // "M/d"
        let day: Date
        var rounds: Int = 0
        var input: Int = 0
        var cacheRead: Int = 0
        var cost: Double = 0
        var hitRate: Double {
            let denom = Double(cacheRead + input)
            return denom > 0 ? Double(cacheRead) / denom : 0
        }
    }

    private var last7Days: [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var map: [Date: DayStat] = [:]
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            map[day] = DayStat(id: day.formatted(.dateTime.month(.defaultDigits).day()), day: day)
        }
        for r in records {
            let day = cal.startOfDay(for: r.date)
            guard var st = map[day] else { continue }
            st.rounds += 1
            st.input += r.inputTokens
            st.cacheRead += r.cacheReadTokens
            st.cost += r.cost
            map[day] = st
        }
        return map.values.sorted { $0.day < $1.day }
    }

    var body: some View {
        List {
            // 总览
            Section("总览") {
                statRow("缓存命中", "\(formatTokens(totalCacheRead)) · \(percent(cacheHitRate))", green: true)
                statRow("总节省估算", String(format: "~$%.4f", estimatedSaved), green: true)
                statRow("平均响应", String(format: "%.1fs", avgResponseTime), green: false)
                statRow("累计花费", String(format: "$%.4f", totalCost), green: false)
                statRow("总轮次", "\(records.count)", green: false)
            }

            // 近 7 天命中率趋势（P1-1）：轻量条形，不引 Charts
            Section("近 7 天缓存命中") {
                if records.isEmpty {
                    Text("暂无数据").foregroundStyle(.secondary)
                } else {
                    ForEach(last7Days) { d in
                        HStack(spacing: 8) {
                            Text(d.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.green.opacity(0.12))
                                    Capsule().fill(Color.green.opacity(0.75))
                                        .frame(width: max(d.hitRate > 0 ? CGFloat(3) : 0, geo.size.width * CGFloat(d.hitRate)))
                                }
                            }
                            .frame(height: 6)
                            Text(d.rounds > 0 ? percent(d.hitRate) : "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(d.rounds > 0 ? .primary : .secondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(d.rounds > 0 ? String(format: "$%.2f", d.cost) : "")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            // 按模型分组
            Section("按模型") {
                if byModel.isEmpty {
                    Text("暂无数据").foregroundStyle(.secondary)
                } else {
                    ForEach(byModel) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(m.id).font(.system(size: 14, weight: .medium))
                                Spacer()
                                Text(String(format: "$%.4f", m.cost))
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 10) {
                                Text("\(m.rounds) 轮").font(.caption).foregroundStyle(.secondary)
                                Text("↑\(formatTokens(m.input))").font(.caption).foregroundStyle(.secondary)
                                Text("↓\(formatTokens(m.output))").font(.caption).foregroundStyle(.secondary)
                                if m.cacheRead > 0 {
                                    let denom = Double(m.cacheRead + m.input)
                                    let rate = denom > 0 ? Double(m.cacheRead) / denom : 0
                                    Text("缓存 \(formatTokens(m.cacheRead)) · \(percent(rate))")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // 最近
            Section("最近 30 次") {
                if records.isEmpty {
                    Text("暂无数据").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(records.suffix(30).reversed().enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.date.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.secondary)
                                Text(r.model).font(.caption).foregroundStyle(.primary)
                                Spacer()
                                Text(String(format: "$%.4f", r.cost))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 10) {
                                Text("↑\(formatTokens(r.inputTokens))").font(.caption2).foregroundStyle(.secondary)
                                Text("↓\(formatTokens(r.outputTokens))").font(.caption2).foregroundStyle(.secondary)
                                if r.cacheReadTokens > 0 {
                                    Text("缓存 \(formatTokens(r.cacheReadTokens))").font(.caption2).foregroundColor(.green)
                                }
                                if r.responseTime > 0 {
                                    Text(String(format: "%.1fs", r.responseTime)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .navigationTitle("Token 统计")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { records = TokenStatsStore.load() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { records = TokenStatsStore.load() }
    }

    // MARK: - helpers

    private func statRow(_ title: String, _ value: String, green: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(green ? .green : .primary)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func percent(_ x: Double) -> String {
        String(format: "%.0f%%", x * 100)
    }
}
