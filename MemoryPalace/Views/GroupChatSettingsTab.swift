import SwiftUI

/// 群聊设置（0906，兔兔点单「群聊要好好做」；机制学自粟粟 Agora 的行为层）。
/// 三档发言模式 / 链深上限 / 最小发言间隔——全部即时生效，无需重启。
struct GroupChatSettingsTab: View {
    /// mention_only | relay | free（与粟粟 speech_mode 同名，将来服务端化好对齐）
    @AppStorage("groupSpeechMode") private var speechMode = "relay"
    @AppStorage("groupMaxChainDepth") private var maxChainDepth = 3
    @AppStorage("groupMinSpeakIntervalSec") private var minSpeakInterval = 0
    @AppStorage("groupIceBreakEnabled") private var iceBreakEnabled = true
    @AppStorage("groupIceBreakMinutes") private var iceBreakMinutes = 30
    @AppStorage("userName") private var userName = "你"
    @AppStorage("userPersona") private var userPersona = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("你的名字")
                    Spacer()
                    TextField("你", text: $userName)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的人设")
                    TextEditor(text: $userPersona)
                        .frame(minHeight: 88)
                        .font(.system(size: 14))
                        .overlay(alignment: .topLeading) {
                            if userPersona.isEmpty {
                                Text("群里的成员会看到这段，用来知道你是谁、该怎么对你说话。例：兔兔，这个群的主人。爱吃甜的、作息颠倒，喜欢被人接话。")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            } header: {
                Text("你")
            } footer: {
                Text("成员名单里你会和大家并排列出——名字后面跟着这段介绍。留空就只给名字。")
            }

            Section {
                Picker("发言模式", selection: $speechMode) {
                    Text("仅 @ 发言").tag("mention_only")
                    Text("@ 接力").tag("relay")
                    Text("自由发言").tag("free")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("发言模式")
            } footer: {
                Text(modeFooter)
            }

            Section {
                Stepper(value: $maxChainDepth, in: 1...8) {
                    HStack {
                        Text("一轮最多接几手")
                        Spacer()
                        Text("\(maxChainDepth)").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("你说一句话之后，成员之间最多接力几次。到顶自动收住，防两个角色互相 @ 对轰。你再说话时重新计数。")
            }

            Section {
                Stepper(value: $minSpeakInterval, in: 0...60, step: 5) {
                    HStack {
                        Text("最小发言间隔")
                        Spacer()
                        Text(minSpeakInterval == 0 ? "关" : "\(minSpeakInterval) 秒")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("刚有人说过话就先别急着接——治「几个角色瞬间刷屏」。你直接 @ 谁，谁不受这个限制。")
            }
            Section {
                Toggle("冷场时有人先开口", isOn: $iceBreakEnabled)
                if iceBreakEnabled {
                    Stepper(value: $iceBreakMinutes, in: 5...240, step: 5) {
                        HStack {
                            Text("安静多久算冷场")
                            Spacer()
                            Text("\(iceBreakMinutes) 分钟").foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("群里安静超过这个时间，你再打开群聊时，会有人主动找你说话（话痨的成员更可能开口）。一次冷场只叫一次，你不理他就不会再追着说。")
            }
        }
        .navigationTitle("群聊")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modeFooter: String {
        switch speechMode {
        case "mention_only":
            return "只有被你 @ 到的成员会说话；他们回复里的 @ 不会继续传下去。最安静。"
        case "free":
            return "群里任何新消息，所有成员都会看到，各自决定要不要插话——不想说就沉默（不留痕迹）。被 @ 到的一定回。最热闹。"
        default:
            return "被你 @ 的成员会说话；他们回复里 @ 到谁，谁就接上，直到没人被 @ 或到达接力上限。"
        }
    }
}
