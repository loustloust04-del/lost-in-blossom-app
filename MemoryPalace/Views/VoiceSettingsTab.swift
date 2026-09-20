#if os(iOS)
import SwiftUI

/// 语音设置页（iOS-only）。ElevenLabs key + 主动语音开关 + 声音效果 + 选音色。
///
/// 之前 VoiceSettingsSection.swift 里的组件全是孤儿 View——语音条整套代码
/// （writer/player/胶囊/turn 收口）都接好了，唯独没有地方填 key，功能等于废的。
struct VoiceSettingsTab: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        List {
            // key + 主动语音开关 + 声音效果（复用现成组件）
            VoiceMessageSettingsIOSSections()

            // 音色选择：按楼层存，每个楼层的 AI 可以有不同声音
            if let profile = profileManager?.currentProfile {
                Section {
                    VoicePickRow()
                } header: {
                    Text("音色")
                } footer: {
                    Text("按楼层保存。当前楼层：\(profile.name)")
                        .font(.system(size: Theme.F.caption))
                }
                .listRowBackground(Theme.mainBg)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("怎么用")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("""
                    填好 key、选好音色之后，\(assistantName) 在想让你听见语气的时刻会自己发语音条——\
                    先出现一行「🎤 语音条生成中…」，生成好就变成可播放的胶囊。

                    你也可以直接说「用语音跟我说」。

                    额度用完或者网络不通时会退回文字，脚本原文不会丢。
                    """)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("语音")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
