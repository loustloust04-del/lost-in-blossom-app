import SwiftUI

/// 网关控制台：网关(4567/blossom.amberrib.com)所有内容的管理页。
/// Phase 1（App 侧只读 + 添加记忆）：状态 / 通道模型 / 记忆库 / 梦境日记 /
/// 碎碎念 / MCP 工具。删除与通道管理需网关侧 admin API，待 Phase 2。
/// 设计语言完全复用 Caelum's Console（白卡 16 圆角 / 暖灰标签，ConsoleView 设计 tokens）。
struct GatewayConsoleView: View {

    @State private var health: GatewayConsoleClient.HealthInfo? = nil
    @State private var healthLoaded = false
    @State private var models: [GatewayConsoleClient.GatewayModel] = []
    @State private var memories: [GatewayConsoleClient.GatewayMemory] = []
    @State private var memoryTotal = 0
    @State private var dreams: [GatewayConsoleClient.GatewayDream] = []
    @State private var desires: [GatewayConsoleClient.GatewayDesire] = []
    @State private var tools: [GatewayConsoleClient.GatewayTool] = []
    @State private var channels: [GatewayConsoleClient.GatewayChannel] = []
    @State private var editingChannel: GatewayConsoleClient.GatewayChannel? = nil

    @State private var modelsExpanded = false
    @State private var toolsExpanded = false
    @State private var dreamsExpanded = false
    @State private var showAddMemory = false
    @State private var addMemoryResult: String? = nil
    @State private var showConnectionSheet = false
    @State private var authIssue: String? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                statusCard
                channelsCard
                modelsCard
                memoriesCard
                dreamsCard
                desiresCard
                toolsCard
                cronCard
                Color.clear.frame(height: 32)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ConsoleView.pageBg.ignoresSafeArea())
        .navigationTitle("网关控制台")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadAll() }
        .task { await loadAll() }
        .sheet(isPresented: $showAddMemory) {
            AddGatewayMemorySheet { added in
                addMemoryResult = added ? "已入库（source: manual）" : "没有入库——可能与已有记忆重复"
                Task { await loadMemories() }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingChannel) { ch in
            ChannelKeySheet(channel: ch) {
                Task { channels = await GatewayConsoleClient.channels() }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showConnectionSheet) {
            GatewayConnectionSheet {
                Task { await loadAll() }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("添加记忆", isPresented: Binding(
            get: { addMemoryResult != nil },
            set: { if !$0 { addMemoryResult = nil } }
        )) {
            Button("好") { addMemoryResult = nil }
        } message: {
            Text(addMemoryResult ?? "")
        }
    }

    // MARK: - 数据加载

    private func loadAll() async {
        GatewayConsoleClient.resetAuthFlag()
        async let h = GatewayConsoleClient.health()
        async let m = GatewayConsoleClient.models()
        async let d = GatewayConsoleClient.dreams()
        async let de = GatewayConsoleClient.desires(limit: 10)
        async let t = GatewayConsoleClient.mcpTools()
        async let ch = GatewayConsoleClient.channels()
        health = await h
        healthLoaded = true
        models = await m
        dreams = await d
        desires = await de
        tools = await t
        channels = await ch
        await loadMemories()
        // 加载完统一诊断鉴权：token 没配 / 被拒都在状态卡横幅明说，
        // 不再让页面静默显示一排 0（历史坑：client 吞错 + 没有任何设置入口）
        if !GatewayConsoleClient.tokenConfigured {
            authIssue = "还没配置访问令牌，网关会拒绝所有请求（HTTP 401）。点右上「连接」填入 token。"
        } else if GatewayConsoleClient.lastAuthFailed {
            authIssue = "网关拒绝了当前令牌（HTTP 401）。点右上「连接」检查 token 是否填对。"
        } else {
            authIssue = nil
        }
    }

    private func loadMemories() async {
        let r = await GatewayConsoleClient.memories(limit: 5)
        memories = r.items
        memoryTotal = r.total
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        GatewayCard {
            HStack {
                gwLabel("GATEWAY", icon: "server.rack")
                Spacer()
                Button {
                    showConnectionSheet = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                        Text("连接")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(ConsoleView.textLabel)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(health?.ok == true ? Color(red: 0.55, green: 0.72, blue: 0.46) : Color(red: 0.78, green: 0.45, blue: 0.45))
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(ConsoleView.textPrimary)
                Spacer()
                if let h = health {
                    Text("\(h.latencyMs) ms")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(ConsoleView.textMuted)
                }
            }
            .padding(.top, 6)
            Text(GatewayConsoleClient.baseURL)
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
                .lineLimit(1)
                .padding(.top, 2)
            if let h = health {
                gwSubRow(icon: "brain", text: h.memoryConnected ? "记忆库已连接（Supabase）" : "记忆库未配置")
                    .padding(.top, 6)
            }
            if let issue = authIssue {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.78, green: 0.55, blue: 0.25))
                    Text(issue)
                        .font(.system(size: 12))
                        .foregroundColor(ConsoleView.textPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.98, green: 0.93, blue: 0.82))
                )
                .padding(.top, 8)
            }
        }
    }

    private var statusText: String {
        if !healthLoaded { return "检查中…" }
        return health?.ok == true ? "在线" : "离线"
    }

    // MARK: - 通道 key 管理卡

    private var channelsCard: some View {
        GatewayCard {
            gwLabel("通道 KEY", icon: "key")
            Text("\(channels.filter(\.configured).count)/\(channels.count)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ConsoleView.textPrimary)
                .padding(.top, 6)
            Text("已配置 · 点通道改 key，改完即时生效不用重启")
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
            VStack(spacing: 0) {
                ForEach(channels) { ch in
                    Button {
                        editingChannel = ch
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(ch.configured
                                      ? Color(red: 0.55, green: 0.72, blue: 0.46)
                                      : ConsoleView.textMuted.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(ch.name)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(ConsoleView.textPrimary)
                            if ch.overridden { gwBadge("覆盖") }
                            Spacer()
                            Text(ch.configured ? ch.masked : "未配置")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(ConsoleView.textMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundColor(ConsoleView.textMuted.opacity(0.6))
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - 定时任务卡

    private var cronCard: some View {
        GatewayCard {
            HStack {
                gwLabel("定时任务", icon: "clock.arrow.circlepath")
                Spacer()
                NavigationLink {
                    GatewayCronPage()
                } label: {
                    HStack(spacing: 3) {
                        Text("管理")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ConsoleView.textLabel)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(ConsoleView.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
            Text("VPS crontab")
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
                .padding(.top, 6)
            Text("Twitter 同步 / CC token 刷新 / 主动推送等，进「管理」页开关、增删")
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
                .padding(.top, 2)
        }
    }

    // MARK: - 通道 & 模型卡

    private var modelsCard: some View {
        GatewayCard {
            HStack {
                gwLabel("通道 & 模型", icon: "shippingbox")
                Spacer()
                expandChevron($modelsExpanded, enabled: !models.isEmpty)
            }
            Text("\(models.count)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ConsoleView.textPrimary)
                .padding(.top, 6)
            // 按 owned_by 分组统计
            let groups = Dictionary(grouping: models, by: { $0.owned_by })
                .map { (key: $0.key, count: $0.value.count) }
                .sorted { $0.count > $1.count }
            FlowChips(items: groups.map { "\($0.key) · \($0.count)" })
                .padding(.top, 6)
            if modelsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(models) { m in
                        HStack {
                            Text(m.id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(ConsoleView.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(m.owned_by)
                                .font(.system(size: 10))
                                .foregroundColor(ConsoleView.textMuted)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .onTapGesture {
            guard !models.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) { modelsExpanded.toggle() }
        }
    }

    // MARK: - 记忆库卡

    private var memoriesCard: some View {
        GatewayCard {
            HStack {
                gwLabel("记忆库", icon: "brain.head.profile")
                Spacer()
                Button {
                    showAddMemory = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(ConsoleView.textLabel)
                }
                .buttonStyle(.plain)
            }
            Text("\(memoryTotal)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ConsoleView.textPrimary)
                .padding(.top, 6)
            Text("条长期记忆 · 置顶 > 热度 > 时间")
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(memories.prefix(3)) { m in
                    memoryRow(m)
                }
            }
            .padding(.top, 10)
            NavigationLink {
                GatewayMemoriesPage()
            } label: {
                HStack {
                    Text("浏览全部记忆")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ConsoleView.textLabel)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(ConsoleView.textMuted)
                }
                .padding(.top, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func memoryRow(_ m: GatewayConsoleClient.GatewayMemory) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if m.is_pinned == true {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(ConsoleView.textLabel)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.content)
                    .font(.system(size: 13))
                    .foregroundColor(ConsoleView.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let cat = m.category, !cat.isEmpty {
                        gwBadge(cat)
                    }
                    if let t = m.tier { gwBadge("T\(t)") }
                    Text(gwShortDate(m.created_at))
                        .font(.system(size: 10))
                        .foregroundColor(ConsoleView.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 梦境日记卡

    private var dreamsCard: some View {
        GatewayCard {
            HStack {
                gwLabel("梦境日记", icon: "moon.stars")
                Spacer()
                expandChevron($dreamsExpanded, enabled: dreams.count > 2)
            }
            Text("\(dreams.count)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ConsoleView.textPrimary)
                .padding(.top, 6)
            Text("篇日/周/月摘要（AI 夜间自动生成）")
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
            if dreams.isEmpty {
                Text("还没有梦境日记")
                    .font(.system(size: 12))
                    .foregroundColor(ConsoleView.textMuted)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(dreamsExpanded ? dreams : Array(dreams.prefix(2))) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                gwBadge(d.layer ?? "daily")
                                Text(d.date ?? gwShortDate(d.created_at))
                                    .font(.system(size: 10))
                                    .foregroundColor(ConsoleView.textMuted)
                            }
                            Text(d.summary ?? "")
                                .font(.system(size: 13))
                                .foregroundColor(ConsoleView.textPrimary)
                                .lineLimit(dreamsExpanded ? 6 : 2)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .onTapGesture {
            guard dreams.count > 2 else { return }
            withAnimation(.easeInOut(duration: 0.15)) { dreamsExpanded.toggle() }
        }
    }

    // MARK: - 碎碎念卡

    private var desiresCard: some View {
        GatewayCard {
            gwLabel("碎碎念", icon: "bubble.left.and.text.bubble.right")
            Text("\(desires.count)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ConsoleView.textPrimary)
                .padding(.top, 6)
            Text("条主动念头（欲望系统生成）")
                .font(.system(size: 12))
                .foregroundColor(ConsoleView.textMuted)
            if desires.isEmpty {
                Text("最近没有碎碎念")
                    .font(.system(size: 12))
                    .foregroundColor(ConsoleView.textMuted)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(desires.prefix(3)) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.content)
                                .font(.system(size: 13))
                                .foregroundColor(ConsoleView.textPrimary)
                                .lineLimit(2)
                            Text(gwShortDate(d.created_at))
                                .font(.system(size: 10))
                                .foregroundColor(ConsoleView.textMuted)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - MCP 工具卡

    private var toolsCard: some View {
        GatewayCard {
            HStack {
                gwLabel("MCP & 内建工具", icon: "wrench.and.screwdriver")
                Spacer()
                expandChevron($toolsExpanded, enabled: !tools.isEmpty)
            }
            Text("\(tools.count)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ConsoleView.textPrimary)
                .padding(.top, 6)
            let groups = Dictionary(grouping: tools, by: { $0.source ?? "mcp" })
                .map { (key: $0.key, count: $0.value.count) }
                .sorted { $0.count > $1.count }
            FlowChips(items: groups.map { "\($0.key) · \($0.count)" })
                .padding(.top, 6)
            if toolsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tools) { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(ConsoleView.textPrimary)
                            if let desc = t.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundColor(ConsoleView.textMuted)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .onTapGesture {
            guard !tools.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15)) { toolsExpanded.toggle() }
        }
    }

    // MARK: - 小组件

    private func expandChevron(_ expanded: Binding<Bool>, enabled: Bool) -> some View {
        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
            .font(.system(size: 11))
            .foregroundColor(ConsoleView.textMuted.opacity(enabled ? 1 : 0.3))
    }
}

// MARK: - 共享样式（网关控制台系列页面共用）

func gwLabel(_ text: String, icon: String) -> some View {
    HStack(spacing: 5) {
        Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundColor(ConsoleView.textLabel)
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(ConsoleView.textLabel)
            .tracking(1)
    }
}

func gwBadge(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 9, weight: .medium))
        .foregroundColor(ConsoleView.textLabel)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(ConsoleView.pageBg))
}

func gwSubRow(icon: String, text: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundColor(ConsoleView.textLabel)
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(ConsoleView.textMuted)
    }
}

func gwShortDate(_ iso: String?) -> String {
    guard let iso, iso.count >= 10 else { return "" }
    return String(iso.prefix(10))
}

/// 白卡容器：与 Caelum's Console 的 ConsoleCard 同一视觉（那边是 private，这里独立一份）
struct GatewayCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
        )
    }
}

/// 简易 chip 行（自动换行）
struct FlowChips: View {
    let items: [String]

    var body: some View {
        // 简化：横向可滚动一行，chips 少时看起来就是静态行
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { text in
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ConsoleView.textUnit)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(ConsoleView.pageBg))
                }
            }
        }
    }
}

// MARK: - 添加记忆 sheet

struct AddGatewayMemorySheet: View {
    var onDone: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var category = "fact"
    @State private var submitting = false

    private let categories = ["fact", "preference", "goal", "event", "emotion"]

    var body: some View {
        NavigationStack {
            Form {
                Section("记忆内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 100)
                }
                Section("分类") {
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("将写入网关记忆库（source: manual），与已有记忆自动查重。")
                        .font(.system(size: 12))
                        .foregroundColor(ConsoleView.textMuted)
                }
            }
            .navigationTitle("添加记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("保存") {
                            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            submitting = true
                            Task {
                                let ok = await GatewayConsoleClient.addMemory(content: text, category: category)
                                await MainActor.run {
                                    submitting = false
                                    dismiss()
                                    onDone(ok)
                                }
                            }
                        }
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - 通道 key 编辑 sheet

struct ChannelKeySheet: View {
    let channel: GatewayConsoleClient.GatewayChannel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var submitting = false
    @State private var resultMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("当前") {
                    HStack {
                        Text(channel.name)
                            .font(.system(size: 14, design: .monospaced))
                        Spacer()
                        Text(channel.configured ? channel.masked : "未配置")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(ConsoleView.textMuted)
                    }
                }
                Section("新 key") {
                    SecureField("粘贴新的 API key", text: $newKey)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                if channel.overridden {
                    Section {
                        Button(role: .destructive) {
                            submitting = true
                            Task {
                                let ok = await GatewayConsoleClient.clearChannelKey(name: channel.name)
                                await MainActor.run {
                                    submitting = false
                                    resultMessage = ok ? "已清除覆盖，回落到网关启动配置" : "清除失败"
                                }
                            }
                        } label: {
                            Text("清除覆盖（回落到 .env）")
                        }
                        .disabled(submitting)
                    } footer: {
                        Text("这个通道的 key 当前被控制台覆盖过；清除后恢复网关启动时的环境变量值。")
                            .font(.system(size: 12))
                    }
                }
                Section {
                    Text("保存后立刻生效（网关热更新，不用重启）。key 持久化在网关的 config-overrides.json。")
                        .font(.system(size: 12))
                        .foregroundColor(ConsoleView.textMuted)
                }
            }
            .navigationTitle("通道 · \(channel.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("保存") {
                            let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty else { return }
                            submitting = true
                            Task {
                                let ok = await GatewayConsoleClient.setChannelKey(name: channel.name, key: key)
                                await MainActor.run {
                                    submitting = false
                                    resultMessage = ok ? "已保存，即时生效" : "保存失败"
                                }
                            }
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("通道 key", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("好") {
                    resultMessage = nil
                    dismiss()
                    onDone()
                }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }
}

// MARK: - 网关连接设置 sheet

/// 网关地址 + 访问令牌设置。历史坑：gatewayAuthToken 全 App 只读不写、
/// 没有任何设置入口，token 永远是空串 → 控制台/MCP 页全被 401 拒掉。
struct GatewayConnectionSheet: View {
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
    @State private var token = UserDefaults.standard.string(forKey: "gatewayAuthToken") ?? ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("网关地址") {
                    TextField("https://…", text: $baseURL)
                        .font(.system(size: 13, design: .monospaced))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                Section {
                    SecureField("粘贴网关访问令牌", text: $token)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("访问令牌")
                } footer: {
                    Text("即网关 .env 里的 GATEWAY_TOKEN。控制台、MCP 页、记忆同步、体征上报全都用这一个令牌。")
                        .font(.system(size: 12))
                }
                Section {
                    Button {
                        testing = true
                        testResult = nil
                        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tk = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            let (code, msg) = await GatewayConsoleClient.testConnection(baseURL: url, token: tk)
                            await MainActor.run {
                                testing = false
                                testResult = (code == 200, msg)
                            }
                        }
                    } label: {
                        HStack {
                            if testing {
                                ProgressView().controlSize(.small)
                                Text("测试中…")
                            } else {
                                Image(systemName: "bolt.horizontal")
                                Text("测试连接")
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                    .disabled(testing)
                    if let r = testResult {
                        HStack(spacing: 6) {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(r.ok ? .green : .red)
                            Text(r.message)
                                .font(.system(size: 13))
                        }
                    }
                }
            }
            .navigationTitle("网关连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        GatewayConsoleClient.saveConnection(
                            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                        onSaved()
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - 定时任务管理页

struct GatewayCronPage: View {
    @State private var jobs: [GatewayConsoleClient.GatewayCronJob] = []
    @State private var loading = true
    @State private var showAdd = false
    @State private var newLine = ""
    @State private var errorMessage: String? = nil
    @State private var pendingDelete: GatewayConsoleClient.GatewayCronJob? = nil

    var body: some View {
        List {
            Section {
                if loading && jobs.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("读取 crontab…").foregroundColor(ConsoleView.textMuted) }
                        .listRowBackground(Color.white)
                } else if jobs.isEmpty {
                    Text("crontab 为空")
                        .font(.system(size: 13))
                        .foregroundColor(ConsoleView.textMuted)
                        .listRowBackground(Color.white)
                } else {
                    ForEach(jobs) { job in
                        cronRow(job)
                            .listRowBackground(Color.white)
                    }
                }
            } header: {
                Text("VPS crontab · \(jobs.count) 条")
            } footer: {
                Text("开关 = 注释/解注释该行；删除有二次确认。所有改动即时写回 crontab。")
                    .font(.system(size: 12))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ConsoleView.pageBg.ignoresSafeArea())
        .navigationTitle("定时任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newLine = ""
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(ConsoleView.textLabel)
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .alert("新增定时任务", isPresented: $showAdd) {
            TextField("如 */30 * * * * /path/to/script.sh", text: $newLine)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button("取消", role: .cancel) {}
            Button("添加") {
                let line = newLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return }
                Task {
                    let ok = await GatewayConsoleClient.cronAdd(line: line)
                    if !ok { errorMessage = "添加失败" }
                    await reload()
                }
            }
        } message: {
            Text("标准 5 段 cron 表达式 + 命令")
        }
        .alert("删除这条任务？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let job = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    let ok = await GatewayConsoleClient.cronDelete(job: job)
                    if !ok { errorMessage = "删除失败（行内容可能已变化，请下拉刷新重试）" }
                    await reload()
                }
            }
        } message: {
            Text(pendingDelete?.line ?? "")
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func cronRow(_ job: GatewayConsoleClient.GatewayCronJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(cronSchedule(job.line))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(job.enabled ? ConsoleView.textPrimary : ConsoleView.textMuted)
                Text(cronCommand(job.line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ConsoleView.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { job.enabled },
                set: { on in
                    Task {
                        let ok = await GatewayConsoleClient.cronToggle(job: job, enabled: on)
                        if !ok { errorMessage = "开关失败（行内容可能已变化，请下拉刷新重试）" }
                        await reload()
                    }
                }
            ))
            .labelsHidden()
            .tint(Color(red: 0.55, green: 0.72, blue: 0.46))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = job
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 拆 cron 行：前 5 段是时间表达式（被注释的行先剥掉 #）
    private func cronSchedule(_ line: String) -> String {
        let clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#\\s*", with: "", options: .regularExpression)
        let parts = clean.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 5 else { return clean }
        return parts.prefix(5).joined(separator: " ")
    }

    private func cronCommand(_ line: String) -> String {
        let clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#\\s*", with: "", options: .regularExpression)
        let parts = clean.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 5 else { return "" }
        return parts.dropFirst(5).joined(separator: " ")
    }

    private func reload() async {
        loading = true
        jobs = await GatewayConsoleClient.cronJobs()
        loading = false
    }
}

// MARK: - 全部记忆浏览页

struct GatewayMemoriesPage: View {
    @State private var items: [GatewayConsoleClient.GatewayMemory] = []
    @State private var total = 0
    @State private var loading = false
    @State private var category: String? = nil
    @State private var pendingDelete: GatewayConsoleClient.GatewayMemory? = nil
    @State private var errorMessage: String? = nil

    private let pageSize = 50
    private let categories = ["fact", "preference", "goal", "event", "emotion"]

    var body: some View {
        List {
            Section {
                ForEach(items) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.content)
                            .font(.system(size: 14))
                            .foregroundColor(ConsoleView.textPrimary)
                        HStack(spacing: 6) {
                            if m.is_pinned == true {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(ConsoleView.textLabel)
                            }
                            if let cat = m.category, !cat.isEmpty { gwBadge(cat) }
                            if let t = m.tier { gwBadge("T\(t)") }
                            if let s = m.source, !s.isEmpty { gwBadge(s) }
                            Text(gwShortDate(m.created_at))
                                .font(.system(size: 10))
                                .foregroundColor(ConsoleView.textMuted)
                        }
                    }
                    .listRowBackground(Color.white)
                    .onAppear {
                        if m.id == items.last?.id { Task { await loadMore() } }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = m
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            let target = !(m.is_pinned ?? false)
                            Task {
                                let ok = await GatewayConsoleClient.pinMemory(id: m.id, pinned: target)
                                if !ok { errorMessage = "置顶操作失败" }
                                await reload()
                            }
                        } label: {
                            Label(m.is_pinned == true ? "取消置顶" : "置顶",
                                  systemImage: m.is_pinned == true ? "pin.slash" : "pin")
                        }
                        .tint(Color(red: 0.66, green: 0.62, blue: 0.56))
                    }
                }
            } header: {
                Text("\(total) 条 · \(category ?? "全部分类")")
            } footer: {
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ConsoleView.pageBg.ignoresSafeArea())
        .navigationTitle("记忆库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部分类") { category = nil; Task { await reload() } }
                    ForEach(categories, id: \.self) { c in
                        Button(c) { category = c; Task { await reload() } }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(ConsoleView.textLabel)
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .alert("删除这条记忆？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let m = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    let ok = await GatewayConsoleClient.deleteMemory(id: m.id)
                    if !ok { errorMessage = "删除失败" }
                    await reload()
                }
            }
        } message: {
            Text(pendingDelete?.content ?? "")
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() async {
        loading = true
        let r = await GatewayConsoleClient.memories(limit: pageSize, offset: 0, category: category)
        items = r.items
        total = r.total
        loading = false
    }

    private func loadMore() async {
        guard !loading, items.count < total else { return }
        loading = true
        let r = await GatewayConsoleClient.memories(limit: pageSize, offset: items.count, category: category)
        items += r.items
        total = r.total
        loading = false
    }
}
