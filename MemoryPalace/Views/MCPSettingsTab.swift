import SwiftUI

// MARK: - MCP Settings Tab

struct MCPSettingsTab: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("apiSelectedProvider") private var apiSelectedProviderId = "openrouter"

    @State private var editingServer: MCPServerConfig?
    @State private var isAddingServer = false
    @State private var backendTools: [BackendTool] = []
    @State private var loadingTools = false
    @State private var toolsError = ""

    // 网关 MCP 服务器（页面主体：全部接入的 MCP 集合在这里管理）
    @State private var gwServers: [GatewayConsoleClient.MCPServer] = []
    @State private var loadingServers = false
    @State private var showAddGwServer = false
    @State private var pendingDeleteServer: GatewayConsoleClient.MCPServer? = nil
    @State private var gwErrorMessage: String? = nil
    @State private var legacyExpanded = false

    private var selectedProvider: APIProvider? {
        providerManager?.providers.first(where: { $0.id == apiSelectedProviderId })
    }

    private var isAnthropic: Bool {
        selectedProvider?.type == .anthropic
    }

    private var servers: [MCPServerConfig] {
        selectedProvider?.mcpServers ?? []
    }

    private func loadGwServers() {
        loadingServers = true
        Task {
            GatewayConsoleClient.resetAuthFlag()
            let s = await GatewayConsoleClient.mcpServers()
            await MainActor.run {
                gwServers = s
                loadingServers = false
                // client 静默吞错：401 时列表是空的，别让它伪装成"没接服务器"
                if s.isEmpty && GatewayConsoleClient.lastAuthFailed {
                    gwErrorMessage = "网关拒绝访问（HTTP 401）：去 网关控制台 → 右上「连接」填访问令牌"
                }
            }
        }
    }

    struct BackendTool: Decodable, Identifiable {
        let name: String
        let description: String
        let source: String
        var id: String { name }

        // 字段宽容解码：任一工具缺 description/source 不再整条数组解码失败
        // （历史事故：网关某工具 name 为 null 时，非可选字段让整页报
        //  "data couldn't be read"）。name 缺失的工具在 resp 层被过滤掉。
        private enum CodingKeys: String, CodingKey { case name, description, source }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)   // 缺 name → 抛错 → resp 层跳过这条
            let desc = try? c.decodeIfPresent(String.self, forKey: .description)
            description = (desc ?? nil) ?? ""
            let src = try? c.decodeIfPresent(String.self, forKey: .source)
            source = (src ?? nil) ?? "builtin"
        }
    }
    private struct BackendToolsResp: Decodable {
        let tools: [BackendTool]
        // 单条坏数据（如 name 为 null）跳过，不拖垮整份列表
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var arr = try c.nestedUnkeyedContainer(forKey: .tools)
            var out: [BackendTool] = []
            while !arr.isAtEnd {
                if let t = try? arr.decode(BackendTool.self) {
                    out.append(t)
                } else {
                    _ = try? arr.decode(AnyDecodableSkip.self)
                }
            }
            tools = out
        }
        private enum CodingKeys: String, CodingKey { case tools }
    }
    private struct AnyDecodableSkip: Decodable {}

    private func loadBackendTools() {
        loadingTools = true
        toolsError = ""
        let base = UserDefaults.standard.string(forKey: "gatewayBaseURL") ?? "https://blossom.amberrib.com"
        guard let url = URL(string: "\(base)/api/mcp/tools") else { loadingTools = false; return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if let token = UserDefaults.standard.string(forKey: "gatewayAuthToken"), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    // 401/403 = 访问令牌没配或填错——指路到设置入口，别只甩状态码
                    let hint = (code == 401 || code == 403)
                        ? "HTTP \(code)（网关拒绝访问：去 网关控制台 → 右上「连接」填访问令牌）"
                        : "HTTP \(code)"
                    await MainActor.run { toolsError = hint; loadingTools = false }
                    return
                }
                let decoded = try JSONDecoder().decode(BackendToolsResp.self, from: data)
                await MainActor.run { backendTools = decoded.tools; loadingTools = false }
            } catch {
                await MainActor.run { toolsError = error.localizedDescription; loadingTools = false }
            }
        }
    }

    var body: some View {
        List {
            // Section 1：网关 MCP 服务器（管理主体：增删 + 可用性探活）
            Section {
                if loadingServers && gwServers.isEmpty {
                    HStack(spacing: 8) { ProgressView(); Text("探活中…").font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted) }
                } else if gwServers.isEmpty {
                    Text("网关没有接入任何 MCP 服务器")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(gwServers) { s in
                        gwServerRow(s)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteServer = s
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                Button {
                    showAddGwServer = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .foregroundColor(Theme.branchIndicator)
                        Text("添加 MCP 服务器")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("网关 MCP 服务器")
            } footer: {
                Text("所有模型的 MCP 工具都由网关统一接入。增删即时生效；删除只是断开接入，不会动服务器本身。")
                    .font(.system(size: Theme.F.caption))
            }
            .listRowBackground(Theme.mainBg)

            // Section 2：工具清单（按来源分组）
            Section("MCP 工具 · \(backendTools.filter { $0.source == "mcp" }.count)") {
                toolsListContent(source: "mcp")
            }
            .listRowBackground(Theme.mainBg)

            Section("网关内建工具 · \(backendTools.filter { $0.source == "builtin" }.count)") {
                toolsListContent(source: "builtin")
                Button("刷新工具列表") {
                    Task {
                        _ = await GatewayConsoleClient.refreshMcpTools()
                        loadBackendTools()
                    }
                }
                .font(.system(size: Theme.F.secondary))
                .disabled(loadingTools)
            }
            .listRowBackground(Theme.mainBg)

            // 高级：App 直连 MCP（旧通道，仅 Anthropic 直连 provider 用得上）
            Section {
                DisclosureGroup(isExpanded: $legacyExpanded) {
                    if !isAnthropic {
                        Text("当前提供商不是 Anthropic 直连，此通道未启用。日常 MCP 都走上面的网关，不需要配这里。")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        ForEach(servers) { server in
                            Button {
                                isAddingServer = false
                                editingServer = server
                            } label: {
                                serverRow(server)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    providerManager?.removeMCPServer(id: server.id, from: apiSelectedProviderId)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                        Button {
                            editingServer = nil
                            isAddingServer = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .foregroundColor(Theme.branchIndicator)
                                Text("添加直连 Server")
                                    .font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    Text("高级 · App 直连 MCP（仅 Anthropic 直连）")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg.ignoresSafeArea())
        .navigationTitle("MCP 工具")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            loadGwServers()
            loadBackendTools()
        }
        .onAppear {
            if backendTools.isEmpty && !loadingTools { loadBackendTools() }
            if gwServers.isEmpty && !loadingServers { loadGwServers() }
        }
        .sheet(isPresented: $showAddGwServer) {
            AddGatewayMCPServerSheet {
                loadGwServers()
                Task {
                    _ = await GatewayConsoleClient.refreshMcpTools()
                    loadBackendTools()
                }
            }
            .presentationDetents([.medium])
        }
        .alert("断开这个 MCP 服务器？", isPresented: Binding(
            get: { pendingDeleteServer != nil },
            set: { if !$0 { pendingDeleteServer = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeleteServer = nil }
            Button("断开", role: .destructive) {
                guard let s = pendingDeleteServer else { return }
                pendingDeleteServer = nil
                Task {
                    let ok = await GatewayConsoleClient.deleteMcpServer(name: s.name)
                    if !ok { gwErrorMessage = "断开失败" }
                    loadGwServers()
                    _ = await GatewayConsoleClient.refreshMcpTools()
                    loadBackendTools()
                }
            }
        } message: {
            Text("\(pendingDeleteServer?.name ?? "")\n\(pendingDeleteServer?.url ?? "")")
        }
        .alert("出错了", isPresented: Binding(
            get: { gwErrorMessage != nil },
            set: { if !$0 { gwErrorMessage = nil } }
        )) {
            Button("好") { gwErrorMessage = nil }
        } message: {
            Text(gwErrorMessage ?? "")
        }
        .sheet(isPresented: $isAddingServer) {
            MCPServerEditSheet(server: nil) { newServer in
                providerManager?.addOrUpdateMCPServer(newServer, for: apiSelectedProviderId)
            }
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditSheet(server: server) { updated in
                providerManager?.addOrUpdateMCPServer(updated, for: apiSelectedProviderId)
            }
        }
    }

    // MARK: - 网关服务器行 / 工具列表

    private func gwServerRow(_ s: GatewayConsoleClient.MCPServer) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(s.ok ? Color.green : Color.red.opacity(0.7))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(s.url)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                if let err = s.error, !s.ok {
                    Text(err)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.ok ? "\(s.toolCount) 工具" : "不可用")
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(s.ok ? Theme.textPrimary : .red.opacity(0.8))
                Text("\(s.ms) ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func toolsListContent(source: String) -> some View {
        let filtered = backendTools.filter { $0.source == source }
        if loadingTools && backendTools.isEmpty {
            HStack(spacing: 8) { ProgressView(); Text("加载中…").font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted) }
        } else if !toolsError.isEmpty && backendTools.isEmpty {
            Text("加载失败：\(toolsError)").font(.system(size: Theme.F.secondary)).foregroundColor(.red)
        } else if filtered.isEmpty {
            Text("暂无").font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
        } else {
            ForEach(filtered) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                    if !t.description.isEmpty {
                        Text(t.description)
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server.isEnabled ? Color.green : Theme.textMuted.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? "（未命名）" : server.name)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(server.url)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { newValue in
                    var updated = server
                    updated.isEnabled = newValue
                    providerManager?.addOrUpdateMCPServer(updated, for: apiSelectedProviderId)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 添加网关 MCP 服务器 sheet

struct AddGatewayMCPServerSheet: View {
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var force = false
    @State private var submitting = false
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址") {
                    TextField("http://127.0.0.1:3100/mcp", text: $url)
                        .font(.system(size: 13, design: .monospaced))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                Section("名字（可选，默认取 host:port）") {
                    TextField("如 browser", text: $name)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                if errorText != nil {
                    Section {
                        Text(errorText ?? "")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.85))
                        Toggle("探活失败也强行接入", isOn: $force)
                            .font(.system(size: 13))
                    }
                }
                Section {
                    Text("保存前网关会先探活（initialize + tools/list）；接入后所有模型即刻可用新工具。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .navigationTitle("添加 MCP 服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView()
                    } else {
                        Button("接入") {
                            let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !u.isEmpty else { return }
                            submitting = true
                            errorText = nil
                            Task {
                                let (ok, err) = await GatewayConsoleClient.addMcpServer(
                                    name: name.trimmingCharacters(in: .whitespaces),
                                    url: u, force: force
                                )
                                await MainActor.run {
                                    submitting = false
                                    if ok {
                                        dismiss()
                                        onDone()
                                    } else {
                                        errorText = err ?? "接入失败"
                                    }
                                }
                            }
                        }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - MCP Server Edit Sheet

struct MCPServerEditSheet: View {
    let server: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var token: String

    private var isNew: Bool { server == nil }

    init(server: MCPServerConfig?, onSave: @escaping (MCPServerConfig) -> Void) {
        self.server = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _url = State(initialValue: server?.url ?? "")
        _token = State(initialValue: server?.authorizationToken ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
                Spacer()
                Text(isNew ? "添加 MCP Server" : "编辑 MCP Server")
                    .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.plain)
                    .foregroundColor(canSave ? .white : Theme.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(canSave ? Theme.branchIndicator : Theme.textMuted.opacity(0.3)))
                    .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("名字") {
                        TextField("imprint-memory", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                    }

                    field("URL") {
                        TextField("https://mcp.example.com/sse", text: $url)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                    }

                    field("Token（可选）") {
                        TextField("Bearer token", text: $token)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: 500, minHeight: 360)
        .frame(maxWidth: .infinity)
        .background(Theme.sidebarBg)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
            content()
        }
    }

    private func save() {
        guard canSave else { return }
        var result = server ?? MCPServerConfig(name: "", url: "")
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.url = url.trimmingCharacters(in: .whitespaces)
        result.authorizationToken = token.trimmingCharacters(in: .whitespaces)
        onSave(result)
        dismiss()
    }
}
