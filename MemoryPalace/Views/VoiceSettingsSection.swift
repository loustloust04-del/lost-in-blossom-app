import SwiftUI
import AVFoundation

// MARK: - 语音条设置（设置-朗读 内）

/// iOS 朗读页里的「语音条」两个 Section
struct VoiceMessageSettingsIOSSections: View {
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage(VoiceTuning.proactiveKey) private var proactiveEnabled = false
    @AppStorage(VoiceTuning.providerKey) private var providerRaw = TTSProvider.elevenLabs.rawValue
    private var currentProvider: TTSProvider { TTSProvider(rawValue: providerRaw) ?? .elevenLabs }

    var body: some View {
        Section {
            Picker("语音服务", selection: $providerRaw) {
                ForEach(TTSProvider.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }
            VoiceKeyField()
            Toggle("AI 主动发语音", isOn: $proactiveEnabled)
                .tint(Theme.branchIndicator)
        } header: {
            Text("语音条")
        } footer: {
            Text("\(currentProvider.blurb)\n两家的 key 分开保存，换回来不用重填。开启后 \(assistantName) 会在想让你听见语气的时刻发语音条——还需在「通用」里给楼层选声音。")
        }
        Section {
            DisclosureGroup("声音效果") {
                VoiceEffectControls()
            }
        }
    }
}

/// ElevenLabs API Key 输入（Keychain account "elevenlabs"，回车/离开时保存）
struct VoiceKeyField: View {
    @State private var key = ""
    @State private var loaded = false
    @AppStorage(VoiceTuning.providerKey) private var providerRaw = TTSProvider.elevenLabs.rawValue
    private var provider: TTSProvider { TTSProvider(rawValue: providerRaw) ?? .elevenLabs }

    var body: some View {
        HStack(spacing: 8) {
            SecureField("\(provider.displayName) API Key", text: $key)
                .textFieldStyle(.plain)
                .onSubmit { save() }
            if !key.isEmpty {
                Button {
                    key = ""
                    save()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            guard !loaded else { return }
            key = KeychainStore.get(account: provider.keychainAccount) ?? ""
            loaded = true
        }
        .onChange(of: providerRaw) { _, _ in
            // 切后端：先存回原来那家，再载入新家的（两家 key 各存各的）
            key = KeychainStore.get(account: provider.keychainAccount) ?? ""
        }
        .onDisappear { save() }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(trimmed.isEmpty ? nil : trimmed, account: provider.keychainAccount, sync: false)
    }
}

/// 声音效果三控件 + 恢复默认（双端共用）
struct VoiceEffectControls: View {
    @AppStorage(VoiceTuning.stabilityKey) private var stability = VoiceTuning.defaultStability
    @AppStorage(VoiceTuning.styleKey) private var style = VoiceTuning.defaultStyle
    @AppStorage(VoiceTuning.speedKey) private var speed = VoiceTuning.defaultSpeed

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("表演感", selection: $stability) {
                Text("奔放").tag(0.0)
                Text("自然").tag(0.5)
                Text("沉稳").tag(1.0)
            }
            .pickerStyle(.segmented)
            Text("越奔放标签响应越强、越随机；越沉稳越平稳。")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))

            VStack(alignment: .leading, spacing: 4) {
                Text("风格强度：\(style, specifier: "%.2f")")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textMuted)
                Slider(value: $style, in: 0...1, step: 0.01)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("语速：\(speed, specifier: "%.2f")")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textMuted)
                Slider(value: $speed, in: 0.7...1.5, step: 0.01)
            }

            Button("恢复默认") {
                VoiceTuning.resetToDefaults()
            }
            .font(.system(size: Theme.SettingsFont.secondary))
            .buttonStyle(.plain)
            .foregroundColor(Theme.branchIndicator)
        }
        .onAppear {
            // 历史脏值（非三档）钳回最近档，防 segmented 无选中
            if ![0.0, 0.5, 1.0].contains(stability) {
                stability = stability < 0.25 ? 0.0 : (stability < 0.75 ? 0.5 : 1.0)
            }
        }
    }
}

// MARK: - 楼层声音选择（设置-通用 内）

/// 「声音」行：显示当前楼层选的 voice，点开选择器
struct VoicePickRow: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack {
                Text("声音")
                    .font(.system(size: Theme.SettingsFont.label))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(profileManager?.currentProfile.elevenVoiceName ?? "未选择")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) { VoicePickerSheet() }
    }
}

/// voice 列表选择器：拉 /v1/voices + 试听 + 选中存楼层
struct VoicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var voices: [ElevenVoice] = []
    @State private var loading = false
    @State private var errorPhrase: String? = nil
    @State private var hasKey = true
    @State private var previewPlayer: AVPlayer? = nil
    @State private var previewingId: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if !hasKey {
                    VStack(spacing: 8) {
                        Image(systemName: "key")
                            .font(.system(size: 28))
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                        Text("先在 设置-朗读 里填 ElevenLabs API Key")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorPhrase {
                    VStack(spacing: 12) {
                        Text("拉不到声音列表（\(errorPhrase)）")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.textMuted)
                        Button("重试") { Task { await load() } }
                            .foregroundColor(Theme.branchIndicator)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    voiceList
                }
            }
            .navigationTitle("选声音")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
        .task { await load() }
        .onDisappear { previewPlayer?.pause() }
    }

    private var voiceList: some View {
        List {
            ForEach(voices) { voice in
                HStack(spacing: 10) {
                    Button {
                        select(voice)
                    } label: {
                        HStack {
                            Text(voice.name)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if profileManager?.currentProfile.elevenVoiceId == voice.voiceId {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if let url = voice.previewURL {
                        Button {
                            preview(url: url, id: voice.voiceId)
                        } label: {
                            Image(systemName: previewingId == voice.voiceId ? "speaker.wave.2.fill" : "play.circle")
                                .foregroundColor(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func load() async {
        guard let key = KeychainStore.get(account: VoiceTuning.keychainAccount), !key.isEmpty else {
            hasKey = false
            return
        }
        hasKey = true
        loading = true
        errorPhrase = nil
        do {
            // 跟随当前后端：EL 拉账号音色列表，MiniMax 用系统音色常量表
            let backend: TTSBackend = VoiceTuning.provider == .miniMax ? MiniMaxClient() : ElevenLabsClient()
            voices = try await backend.fetchVoices(apiKey: key)
        } catch {
            errorPhrase = (error as? ElevenLabsError)?.shortPhrase ?? "出了点问题"
        }
        loading = false
    }

    private func select(_ voice: ElevenVoice) {
        guard let pm = profileManager else { return }
        var p = pm.currentProfile
        p.elevenVoiceId = voice.voiceId
        p.elevenVoiceName = voice.name
        pm.updateProfile(p)
        dismiss()
    }

    private func preview(url: URL, id: String) {
        if previewingId == id {
            previewPlayer?.pause()
            previewingId = nil
            return
        }
        previewPlayer?.pause()
        // 声明媒体播放身份：不然裸 AVPlayer 跟随侧边静音拨片，静音模式下试听无声（正式语音条的 VoiceMessagePlayer 已自带同款声明）
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        previewPlayer = AVPlayer(url: url)
        previewPlayer?.play()
        previewingId = id
    }
}
