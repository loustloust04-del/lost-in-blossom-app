import SwiftUI

// MARK: - Provider 管理页

struct ProviderManageView: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @State private var showAdd = false

    var body: some View {
        List {
            Section("已添加的 Provider") {
                if let pm = providerManager {
                    if pm.providers.isEmpty {
                        Text("还没有 Provider").foregroundStyle(.secondary)
                    } else {
                        ForEach(pm.providers) { p in
                            ProviderRow(pm: pm, provider: p)
                        }
                    }
                }
            }
        }
        .navigationTitle("Provider 管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProviderSheet()
        }
    }
}

// MARK: - 单行

private struct ProviderRow: View {
    let pm: ProviderManager
    let provider: APIProvider
    @State private var testResult: Bool? = nil
    @State private var testMsg: String = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.name).font(.system(size: 15, weight: .medium))
                Spacer()
                Text("\(provider.models.count) 个模型")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(provider.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("key: \(maskedKey)").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 4) {
                        if testing { ProgressView().scaleEffect(0.7) }
                        else if let r = testResult {
                            Image(systemName: r ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(r ? .green : .red)
                        }
                        Text("测试连接").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(testing)

                if let r = testResult, !r, !testMsg.isEmpty {
                    Text(testMsg).font(.caption2).foregroundColor(.red).lineLimit(2)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 3)
    }

    private var maskedKey: String {
        guard let k = pm.apiKey(for: provider.id), !k.isEmpty else { return "未设置" }
        return String(k.prefix(4)) + "••••••"
    }

    private func runTest() {
        testing = true
        testResult = nil
        testMsg = ""
        Task {
            let result = await pm.testConnection(providerId: provider.id)
            await MainActor.run {
                testing = false
                switch result {
                case .success: testResult = true
                case .failure(let err): testResult = false; testMsg = err.localizedDescription
                }
            }
        }
    }
}

// MARK: - 添加 Provider

private struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""

    @State private var stage = 0   // 0=填表 1=选模型
    @State private var fetching = false
    @State private var errorMsg = ""
    @State private var fetchedModels: [ProviderModel] = []
    @State private var selectedIds: Set<String> = []
    @State private var newProviderId = ""

    var body: some View {
        NavigationStack {
            Form {
                if stage == 0 {
                    Section("基本信息") {
                        TextField("名字", text: $name)
                        TextField("Base URL（如 https://api.openai.com/v1）", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("API Key", text: $apiKey)
                    }
                    if !errorMsg.isEmpty {
                        Section { Text(errorMsg).foregroundColor(.red).font(.caption) }
                    }
                    Section {
                        Button {
                            saveAndFetch()
                        } label: {
                            HStack {
                                if fetching { ProgressView().scaleEffect(0.8) }
                                Text("保存并拉取模型")
                            }
                        }
                        .disabled(fetching || name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Section("勾选要暴露的模型（\(selectedIds.count)）") {
                        ForEach(fetchedModels) { m in
                            Button {
                                if selectedIds.contains(m.id) { selectedIds.remove(m.id) }
                                else { selectedIds.insert(m.id) }
                            } label: {
                                HStack {
                                    Image(systemName: selectedIds.contains(m.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIds.contains(m.id) ? Color.accentColor : Color.secondary)
                                    Text(m.name).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if fetchedModels.isEmpty {
                            Text("没拉到模型，可稍后在 API 设置里手动加").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(stage == 0 ? "添加 Provider" : "选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                if stage == 1 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { finish() }
                    }
                }
            }
        }
    }

    private func saveAndFetch() {
        guard let pm = providerManager else { return }
        fetching = true
        errorMsg = ""
        let pid = "custom-\(UUID().uuidString.prefix(8))"
        newProviderId = pid
        let provider = APIProvider(
            id: pid,
            name: name.trimmingCharacters(in: .whitespaces),
            type: .openaiCompatible,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces)
        )
        pm.addProvider(provider)
        pm.setApiKey(apiKey.trimmingCharacters(in: .whitespaces), for: pid)

        Task {
            let result = await pm.fetchModels(providerId: pid)
            await MainActor.run {
                fetching = false
                switch result {
                case .success(let models):
                    fetchedModels = models
                    selectedIds = Set(models.map(\.id))   // 默认全选
                    stage = 1
                case .failure(let err):
                    errorMsg = "拉取模型失败：\(err.localizedDescription)（provider 已保存，可手动加模型）"
                    stage = 1
                }
            }
        }
    }

    private func finish() {
        guard let pm = providerManager,
              var provider = pm.providers.first(where: { $0.id == newProviderId }) else {
            dismiss(); return
        }
        provider.models = fetchedModels.filter { selectedIds.contains($0.id) }
        pm.updateProvider(provider)
        dismiss()
    }
}
