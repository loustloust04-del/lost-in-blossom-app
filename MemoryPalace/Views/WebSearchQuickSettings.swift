import SwiftUI

/// 联网搜索快捷设置：总开关 + 免费引擎选择（无需 API key），保证开箱即用。
/// 需要更强的付费搜索源（Tavily / Exa / Brave …）可后续单独做完整 provider 配置页。
struct WebSearchQuickSettings: View {
    @AppStorage("webSearchEnabled") private var enabled = false
    @ObservedObject private var settings = WebSearchSettings.shared

    /// 免费引擎（不需要 API key）
    private let freeEngines: [(kind: WebSearchProviderKind, label: String)] = [
        (.bingLocal, "Bing"),
        (.duckduckgo, "DuckDuckGo"),
    ]

    private var currentKind: WebSearchProviderKind {
        settings.selected?.kind ?? .bingLocal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用联网搜索", isOn: Binding(
                get: { enabled },
                set: { on in
                    enabled = on
                    if on { ensureProvider(currentKind) }
                }
            ))
            .font(.system(size: Theme.SettingsFont.body))

            if enabled {
                Picker("搜索引擎", selection: Binding(
                    get: { currentKind },
                    set: { ensureProvider($0) }
                )) {
                    ForEach(freeEngines, id: \.kind) { engine in
                        Text(engine.label).tag(engine.kind)
                    }
                }
                .pickerStyle(.segmented)

                Text("免费引擎，无需 API key。开启后 AI 遇到实时信息会先搜后答。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    /// 选中指定引擎：已存在则切换，否则新建一份默认 options 再切换。
    private func ensureProvider(_ kind: WebSearchProviderKind) {
        if let existing = settings.providers.first(where: { $0.kind == kind }) {
            settings.select(id: existing.id)
        } else {
            let opt = WebSearchServiceOptions.makeDefault(kind: kind)
            settings.add(opt)
            settings.select(id: opt.id)
        }
    }
}
