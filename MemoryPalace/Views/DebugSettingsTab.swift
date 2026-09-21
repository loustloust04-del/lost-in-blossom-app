import SwiftUI
import SwiftData

struct IOSDebugPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var stressNotice = ""
    @AppStorage(DebugRenderSettings.themeBackgroundModeKey)
    private var backgroundModeRaw: String = DebugThemeBackgroundMode.original.rawValue

    @AppStorage(DebugRenderSettings.pageIndicatorModeKey)
    private var pageIndicatorModeRaw: String = DebugPageIndicatorMode.proxyInset.rawValue

    private var backgroundMode: DebugThemeBackgroundMode {
        get { DebugThemeBackgroundMode(rawValue: backgroundModeRaw) ?? .original }
    }

    private var pageIndicatorMode: DebugPageIndicatorMode {
        get { DebugPageIndicatorMode(rawValue: pageIndicatorModeRaw) ?? .proxyInset }
    }

    var body: some View {
        List {
            Section {
                ForEach(DebugThemeBackgroundMode.allCases) { mode in
                    Button(action: { backgroundModeRaw = mode.rawValue }) {
                        HStack {
                            Text(mode.displayName)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if backgroundMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: Theme.F.label, weight: .semibold))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Wallpaper 渲染模式")
            } footer: {
                Text("调查：安全区漏白。切换对比 ThemeBackgroundView 在不同挂法下是否真能漫到 status bar / home indicator。")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                ForEach(DebugPageIndicatorMode.allCases) { mode in
                    Button(action: { pageIndicatorModeRaw = mode.rawValue }) {
                        HStack {
                            Text(mode.displayName)
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if pageIndicatorMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: Theme.F.label, weight: .semibold))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("页码点定位模式")
            } footer: {
                Text("调查：页码点飘到列表中。proxy.safeAreaInsets.bottom 在 safe-area 内 GeometryReader 里返回 0，padding 不足；可试 UIApplication 拿真值 / safeAreaInset modifier / VStack flex frame。")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            // 面包屑日志（09-13 兔兔：「面包屑在哪里呢」——原来只有写没有看的地方）
            Section {
                let log = BreadcrumbLog.shared
                if log.entries.isEmpty {
                    Text("还没有记录").font(.caption).foregroundColor(Theme.textMuted)
                } else {
                    ForEach(log.entries.suffix(40).reversed()) { e in
                        HStack(alignment: .top, spacing: 6) {
                            Text(e.icon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textPrimary)
                                Text(e.time.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                }
                Button(action: {
                    UIPasteboard.general.string = log.formattedDump()
                    stressNotice = "面包屑已复制（\(log.entries.count) 条），贴给 Fable"
                }) {
                    Text("复制全部面包屑")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            } header: {
                Text("面包屑日志（最近 40 条，新的在上）")
            } footer: {
                Text("📉 掉帧探针 · 📷📎 附件 · 🖼️ 旧图转述 · 🔔 门铃。说「卡」的时候把这里复制给 Fable。")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            // 弹泡调音台（粟粟原件）：气泡模式新消息「跳出来」的弹性/起点/倾斜/果冻，滑条即调即生效
            Section {
                NavigationLink(destination: BubblePopTunerPage()) {
                    Text("弹泡调音台")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                }
            } footer: {
                Text("气泡模式里新消息弹出来的手感。出厂值是粟粟真机调的。")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            // 深翻基准：机器定速滚 20s，出一份数字（对照粟粟 ChatPerfBench）
            Section {
                ForEach([3000.0, 8000.0], id: \.self) { sp in
                    Button(action: {
                        NotificationCenter.default.post(name: ChatScrollBench.startNotification, object: nil, userInfo: ["speed": sp])
                        stressNotice = "回到聊天页，半秒后开滚；20 秒后看面包屑 📊"
                    }) {
                        Text("深翻基准（\(Int(sp))pt/s × 20s）")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("深翻基准")
            } footer: {
                Text("先打开一条长对话（压力对话 800 条最好），再来按这里，然后马上切回聊天页别碰屏幕。3000 ≈ 真人快速上滑；8000 是粟粟对齐 lody 的口径。结果在面包屑 📊，全量帧间隔在 Documents/perf-bench.json。每刀前后各跑一次。")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            // 压力对话：给白屏/卡顿一个随时能复现的靶子（配面包屑 📉 掉帧探针）
            Section {
                ForEach([300, 800, 1500], id: \.self) { n in
                    Button(action: {
                        let pid = profileManager?.currentProfile.id ?? ""
                        guard !pid.isEmpty else { stressNotice = "没有当前楼层"; return }
                        let conv = StressConversationFactory.make(count: n, profileId: pid, context: modelContext)
                        stressNotice = "已生成「\(conv.title)」，回侧栏打开它"
                    }) {
                        Text("生成压力对话（\(n) 条）")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                if !stressNotice.isEmpty {
                    Text(stressNotice).font(.caption).foregroundColor(Theme.textMuted)
                }
            } header: {
                Text("压力对话")
            } footer: {
                Text("长短消息、彩色字、剧透、代码块、思考链、列表全混在里面。打开它、发消息、上滑，然后看面包屑里的 📉 掉帧记录。标题带 🧪，删掉即可。")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Button(action: {
                    backgroundModeRaw = DebugThemeBackgroundMode.original.rawValue
                    pageIndicatorModeRaw = DebugPageIndicatorMode.proxyInset.rawValue
                }) {
                    Text("重置全部到原版")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.danger)
                }
                .buttonStyle(.plain)
            } footer: {
                Text("相关文档：docs/research-ios-wallpaper-safearea-root-cause-2026-04-19.md")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("开发调试")
        .navigationBarTitleDisplayMode(.inline)
    }
}
