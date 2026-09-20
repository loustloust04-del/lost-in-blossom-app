import SwiftUI
import SwiftData

/// 健康设置区块（AI 可见 / 亲密 / 单位 / 预览），设置-健康页双端共用。
/// 粟粟 07-21 拍"不要面板单独设置页"——原面板 ⚙ HealthGatesSheet 内容挪家至此，⚙ 退役。
struct HealthGatesSections: View {
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #if os(iOS)
    @State private var health = HealthService.shared
    #endif

    @State private var tick = 0

    private var weightGate: Binding<Bool> {
        Binding(
            get: { HealthLogStore.weightGateEnabled },
            set: { HealthLogStore.weightGateEnabled = $0; tick += 1 }
        )
    }

    private var medsGate: Binding<Bool> {
        Binding(
            get: { HealthLogStore.medsGateEnabled },
            set: { HealthLogStore.medsGateEnabled = $0; tick += 1 }
        )
    }

    private var cycleGate: Binding<Bool> {
        Binding(
            get: { HealthLogStore.cycleGateEnabled },
            set: { HealthLogStore.cycleGateEnabled = $0; tick += 1 }
        )
    }

    private var intimacyShow: Binding<Bool> {
        Binding(
            get: { HealthLogStore.showIntimacyCard },
            set: { HealthLogStore.showIntimacyCard = $0; tick += 1 }
        )
    }

    private var intimacyGate: Binding<Bool> {
        Binding(
            get: { HealthLogStore.intimacyGateEnabled },
            set: { HealthLogStore.intimacyGateEnabled = $0; tick += 1 }
        )
    }

    private var unitBinding: Binding<WeightUnit> {
        Binding(
            get: { WeightUnit.current },
            set: { UserDefaults.standard.set($0.rawValue, forKey: WeightUnit.storageKey); tick += 1 }
        )
    }

    var body: some View {
        #if os(iOS)
        @Bindable var health = health
        #endif

        Group {
            Section {
                #if os(iOS)
                Toggle(isOn: $health.injectionEnabled) {
                    Text("聊天时让{{char}}知道我的健康".expandingMacros(profile: profileManager?.currentProfile))
                        .font(.system(size: Theme.F.body))
                }
                .tint(Theme.branchIndicator)
                #endif
                Toggle(isOn: weightGate) {
                    Text("聊天时让{{char}}看到体重".expandingMacros(profile: profileManager?.currentProfile))
                        .font(.system(size: Theme.F.body))
                }
                .tint(Theme.branchIndicator)
                Toggle(isOn: medsGate) {
                    Text("聊天时让{{char}}看到吃药情况".expandingMacros(profile: profileManager?.currentProfile))
                        .font(.system(size: Theme.F.body))
                }
                .tint(Theme.branchIndicator)
                Toggle(isOn: cycleGate) {
                    Text("聊天时让{{char}}看到月经周期".expandingMacros(profile: profileManager?.currentProfile))
                        .font(.system(size: Theme.F.body))
                }
                .tint(Theme.branchIndicator)
            } header: {
                Text("AI 可见")
            } footer: {
                Text("开着的部分会并进 `{{health}}` 宏，随对话发送给你配置的 AI 服务。")
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Toggle(isOn: intimacyShow) {
                    Text("显示亲密卡")
                        .font(.system(size: Theme.F.body))
                }
                .tint(Theme.branchIndicator)
                if intimacyShow.wrappedValue {
                    Toggle(isOn: intimacyGate) {
                        Text("聊天时让{{char}}看到亲密记录".expandingMacros(profile: profileManager?.currentProfile))
                            .font(.system(size: Theme.F.body))
                    }
                    .tint(Theme.branchIndicator)
                }
            } header: {
                Text("亲密")
            } footer: {
                Text("亲密记录只出现在自己的卡里，日历和最近流水都不显示。")
            }
            .listRowBackground(Theme.mainBg)

            Section("单位") {
                Picker("体重单位", selection: unitBinding) {
                    ForEach(WeightUnit.allCases, id: \.self) { u in
                        Text(u.label).tag(u)
                    }
                }
                .font(.system(size: Theme.F.body))
                #if os(iOS)
                .pickerStyle(.menu)
                #endif
            }
            .listRowBackground(Theme.mainBg)

            Section("AI 会看到") {
                let preview = previewText
                Text(preview.isEmpty ? "（现在是空的——没有数据或开关全关）" : preview)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(preview.isEmpty ? Theme.textMuted : Theme.textSecondary)
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    /// 与实发同源（composedHealthSummary），不是另写的近似。
    private var previewText: String {
        _ = tick
        return HealthLogStore.composedHealthSummary(context: modelContext, profileId: profileId)
    }
}
