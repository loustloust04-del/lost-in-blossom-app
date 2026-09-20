import SwiftUI
import SwiftData
import Charts
#if canImport(UIKit)
import UIKit
#endif

// MARK: - page2 tool「健康」（plan-health-module §3）
// P0：今日药卡（三态打卡）+ 体重卡（输入 + Charts 7/30 天）+ 最近流水。
// 现行 Theme 风格，等 page2-visual 上皮后统一换装。

/// 漏服/玫瑰态用色——app 已有的玫瑰语言（AI 划线同族），不引 JournalTheme 依赖。
private let healthRose = Color(red: 0xC9 / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0)

struct HealthPanelView: View {
    let profileId: String
    @Environment(\.modelContext) private var modelContext

    @Query private var meds: [Medication]
    @Query private var weights: [WeightEntry]
    @Query private var recentLogs: [MedicationLog]
    @Query private var cycleDays: [CycleDay]
    @Query private var intimacyDays: [IntimacyEntry]

    @State private var editingMed: Medication?
    @State private var restockTarget: Medication?
    @State private var restockInput = ""
    @State private var showNewMed = false
    @State private var activeDetail: HealthDetail? = nil
    @State private var weightInput = ""
    /// 面板里有没有输入框正被编辑——只有编辑时才挂键盘「完成」按钮。
    /// 否则那个按钮会跟着视图层级跑到聊天页去（兔兔实测截图）。
    @FocusState private var panelInputFocused: Bool
    @State private var chartDays = 30
    @State private var intimacyNoteInput = ""
    // 设置-健康页改单位/亲密卡开关后面板即时刷新（⚙ sheet 已退役，改 @AppStorage 订阅）
    @AppStorage(WeightUnit.storageKey) private var weightUnitRaw = ""
    @AppStorage(HealthLogStore.intimacyShowKey) private var intimacyShowFlag = false

    init(profileId: String) {
        self.profileId = profileId
        _meds = Query(
            filter: #Predicate<Medication> { $0.profileId == profileId && !$0.isArchived },
            sort: \Medication.createdAt
        )
        _weights = Query(
            filter: #Predicate<WeightEntry> { $0.profileId == profileId },
            sort: \WeightEntry.date, order: .reverse
        )
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: Date())) ?? Date.distantPast
        _recentLogs = Query(
            filter: #Predicate<MedicationLog> { $0.profileId == profileId && $0.takenAt >= cutoff },
            sort: \MedicationLog.takenAt, order: .reverse
        )
        _cycleDays = Query(
            filter: #Predicate<CycleDay> { $0.profileId == profileId },
            sort: \CycleDay.date, order: .reverse
        )
        _intimacyDays = Query(
            filter: #Predicate<IntimacyEntry> { $0.profileId == profileId },
            sort: \IntimacyEntry.date, order: .reverse
        )
    }

    private var unit: WeightUnit {
        _ = weightUnitRaw
        return WeightUnit.current
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                medsSection
                cycleSection
                weightSection
                if showIntimacy { intimacySection }
                recentSection
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.sidebarBg)
        // 每次进面板都拉一次他写的（他随时可能在亲密卡上留话）。
        // 原本挂在 intimacySection 上：只有开着显示开关才渲染、且 .task 只跑首次 —— 兔兔因此看不见他写的。
        .task(id: profileId) { await IntimacySyncService.pull(context: modelContext, profileId: profileId) }
        // 键盘工具栏挂最外层：挂在里层 List 上会因为外面还包着 VStack+header 而飘在半空（兔兔实测）
        .toolbar {
            // 只在本面板的输入框被编辑时才挂——否则按钮会跟着视图层级跑到聊天页
            if panelInputFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { panelInputFocused = false }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .task {
            // 健康数据双向同步（本地 SwiftData ↔ Gateway 药品柜 ↔ Caelum）
            await HealthSyncService.sync(context: modelContext, profileId: profileId)
        }
        .sheet(item: $editingMed) { med in
            MedEditorSheet(profileId: profileId, med: med)
        }
        .alert("补货", isPresented: Binding(
            get: { restockTarget != nil },
            set: { if !$0 { restockTarget = nil; restockInput = "" } }
        ), presenting: restockTarget) { med in
            TextField("加多少\(med.unit)", text: $restockInput)
                .focused($panelInputFocused)
                .keyboardType(.decimalPad)
            Button("取消", role: .cancel) { restockTarget = nil; restockInput = "" }
            Button("加上") {
                if let add = Double(restockInput.trimmingCharacters(in: .whitespaces)), add > 0 {
                    med.remaining += add
                    try? modelContext.save()
                    // 同步给 Gateway，Caelum 那边库存也跟着涨
                    if let gid = med.gatewayId {
                        Task { await MedsClient.restock(id: gid, count: add) }
                    }
                }
                restockTarget = nil; restockInput = ""
            }
        } message: { med in
            Text("\(med.name) 现在剩 \(HealthPanelView.numText(med.remaining))\(med.unit)")
        }
        .sheet(isPresented: $showNewMed) {
            MedEditorSheet(profileId: profileId, med: nil)
        }
        .sheet(item: $activeDetail) { detail in
            switch detail {
            case .meds: MedDetailSheet(profileId: profileId)
            case .cycle: CycleDetailSheet(profileId: profileId)
            case .weight: WeightDetailSheet(profileId: profileId)
            case .intimacy: IntimacyDetailSheet(profileId: profileId)
            }
        }
    }

    /// 整卡可点（plan-health-card-details §一）：header 带小 chevron 进详情，卡内交互控件优先不受影响。
    private func detailHeader(_ title: String, _ detail: HealthDetail) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textMuted.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture { activeDetail = detail }
    }

    private var header: some View {
        HStack {
            Text("健康")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: 今天的药

    private var medsSection: some View {
        Section {
            if meds.isEmpty {
                Text("还没有药。加一种，到点会提醒你。")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(meds) { med in
                    ForEach(med.timesOfDay.sorted(), id: \.self) { minute in
                        medTimeRow(med: med, minute: minute)
                    }
                }
            }
            Button {
                showNewMed = true
            } label: {
                Label("添加药物", systemImage: "plus.circle")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        } header: {
            detailHeader("今天的药", .meds)
        } footer: {
            if MedReminderScheduler.shared.authorizationDenied {
                Text("通知权限未开启，提醒不会响。到 系统设置 › 通知 里打开。")
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private func medTimeRow(med: Medication, minute: Int) -> some View {
        let state = HealthLogStore.medState(medication: med, minuteOfDay: minute, todayLogs: todayLogs, now: Date())
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 5) {
                    if !med.dosage.isEmpty {
                        Text(med.dosage)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                    if med.remaining > 0 {
                        let low = med.remaining <= med.perDose * 3
                        Text("剩 \(HealthPanelView.numText(med.remaining))\(med.unit)")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(low ? Theme.favorite : Theme.textMuted)
                    }
                }
            }
            Spacer()
            Text(HealthLogStore.timeText(minute))
                .font(.system(size: Theme.F.secondary, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
            stateButton(state: state, med: med, minute: minute)
        }
        .contentShape(Rectangle())
        .onTapGesture { editingMed = med }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                restockTarget = med
            } label: {
                Label("补货", systemImage: "shippingbox")
            }
            .tint(Theme.branchIndicator)
        }
    }

    @ViewBuilder
    private func stateButton(state: MedTimeState, med: Medication, minute: Int) -> some View {
        Button {
            switch state {
            case .taken:
                HealthLogStore.undoIntake(context: modelContext, todayLogs: todayLogs, medication: med, minuteOfDay: minute)
            case .pending, .missed:
                HealthLogStore.logIntake(context: modelContext, profileId: profileId, medication: med, minuteOfDay: minute)
            }
        } label: {
            switch state {
            case .taken:
                Label("已服", systemImage: "checkmark.circle.fill")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            case .pending:
                Label("打卡", systemImage: "circle")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
            case .missed:
                Label("漏服", systemImage: "exclamationmark.circle")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(healthRose)
            }
        }
        .buttonStyle(.plain)
    }

    private var todayLogs: [MedicationLog] {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return recentLogs.filter { $0.takenAt >= dayStart }
    }

    // MARK: 月经（plan-health-cycle：吃药卡下、体重卡上）

    private var cyclePeriods: [CyclePeriod] {
        HealthCycleStore.periods(days: cycleDays)
    }

    private var todayCycleFlow: CycleFlow? {
        let today = Calendar.current.startOfDay(for: Date())
        return cycleDays.first { $0.date == today }.flatMap { CycleFlow(rawValue: $0.flow) }
    }

    private var cycleSection: some View {
        Section {
            Group {
                if cycleDays.isEmpty {
                    Text("记录第一天经期，这里会开始懂你的周期。")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                } else {
                    Text(HealthCycleStore.statusLine(todayFlow: todayCycleFlow, periods: cyclePeriods, now: Date()))
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { activeDetail = .cycle }
            flowPickerRow
        } header: {
            detailHeader("月经", .cycle)
        } footer: {
            Text("预测仅供参考，不作为避孕或医疗依据。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private var flowPickerRow: some View {
        HStack(spacing: 8) {
            Text("今天")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            ForEach(CycleFlow.allCases, id: \.self) { flow in
                let isOn = todayCycleFlow == flow
                Button {
                    HealthCycleStore.toggleToday(context: modelContext, profileId: profileId, flow: flow)
                } label: {
                    Text(flow.label)
                        .font(.system(size: Theme.F.secondary, weight: isOn ? .semibold : .regular))
                        .foregroundColor(isOn ? .white : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(isOn ? healthRose : Theme.sidebarBg))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: 体重

    private var weightSection: some View {
        Section {
            if let latest = weights.first {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", unit.fromKg(latest.weightKg)))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                    Text(unit.label)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Picker("", selection: $chartDays) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
            weightInputRow
            if chartWeights.count >= 2 {
                weightChart
                    .contentShape(Rectangle())
                    .onTapGesture { activeDetail = .weight }
            }
        } header: {
            detailHeader("体重", .weight)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var chartWeights: [WeightEntry] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -chartDays, to: Calendar.current.startOfDay(for: Date())) else { return [] }
        return weights.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    private var weightChart: some View {
        Chart(chartWeights, id: \.id) { entry in
            LineMark(x: .value("日期", entry.date), y: .value("体重", unit.fromKg(entry.weightKg)))
                .foregroundStyle(Theme.branchIndicator)
                .interpolationMethod(.monotone)
            PointMark(x: .value("日期", entry.date), y: .value("体重", unit.fromKg(entry.weightKg)))
                .foregroundStyle(Theme.branchIndicator)
                .symbolSize(18)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 110)
        .padding(.vertical, 4)
    }

    private var weightInputRow: some View {
        HStack(spacing: 8) {
            TextField("今天：\(unit == .kg ? "52.3" : "115.0")", text: $weightInput)
                .focused($panelInputFocused)
                .font(.system(size: Theme.F.body))
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
            Text(unit.label)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            Button("记一笔") {
                saveWeightInput()
            }
            .font(.system(size: Theme.F.secondary, weight: .medium))
            .foregroundColor(parsedInput == nil ? Theme.textMuted : Theme.branchIndicator)
            .buttonStyle(.plain)
            .disabled(parsedInput == nil)
        }
    }

    private var parsedInput: Double? {
        let normalized = weightInput.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0, value < 1000 else { return nil }
        return value
    }

    private func saveWeightInput() {
        guard let value = parsedInput else { return }
        HealthLogStore.upsertWeight(context: modelContext, profileId: profileId, date: Date(), weightKg: unit.toKg(value))
        weightInput = ""
    }

    // MARK: 亲密（plan-health-intimacy：显示开关开才渲染；体重下、流水上）

    private var showIntimacy: Bool { intimacyShowFlag }

    private var todayIntimacy: IntimacyEntry? {
        let today = Calendar.current.startOfDay(for: Date())
        return intimacyDays.first { $0.date == today }
    }

    private var intimacySection: some View {
        Section {
            HStack(spacing: 8) {
                Text("今天")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    let recorded = HealthLogStore.toggleIntimacyToday(context: modelContext, profileId: profileId)
                    if recorded { intimacyNoteInput = "" }
                } label: {
                    Image(systemName: todayIntimacy == nil ? "heart" : "heart.fill")
                        .font(.system(size: 18))
                        .foregroundColor(todayIntimacy == nil ? Theme.textMuted : healthRose)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { activeDetail = .intimacy }
            if todayIntimacy != nil {
                TextField("备注（可选）", text: $intimacyNoteInput)
                    .font(.system(size: Theme.F.secondary))
                    .textFieldStyle(.plain)
                    .onAppear { intimacyNoteInput = todayIntimacy?.note ?? "" }
                    .onSubmit {
                        HealthLogStore.upsertIntimacy(
                            context: modelContext, profileId: profileId, date: Date(),
                            note: intimacyNoteInput.trimmingCharacters(in: .whitespaces)
                        )
                    }
            }
        } header: {
            detailHeader("刻痕", .intimacy)
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: 最近流水（14 天，按日聚合只读；swipe 删当日体重）
    // 亲密记录不进流水（隐私拍板 plan-health-intimacy：只活在自己卡里+AI 注入）——别在这加 IntimacyEntry

    private struct DayFlow: Identifiable {
        let id: Date          // startOfDay
        let weight: WeightEntry?
        let medParts: [String]
    }

    private var dayFlows: [DayFlow] {
        let cal = Calendar.current
        let medName = Dictionary(uniqueKeysWithValues: meds.map { ($0.id, $0.name) })
        var days: [Date: (weight: WeightEntry?, meds: [String])] = [:]
        for w in weights.prefix(30) {
            days[w.date, default: (nil, [])].weight = w
        }
        for log in recentLogs {
            let day = cal.startOfDay(for: log.takenAt)
            days[day, default: (nil, [])].meds.append(medName[log.medicationId] ?? "药")
        }
        return days
            .map { DayFlow(id: $0.key, weight: $0.value.weight, medParts: Array(Set($0.value.meds)).sorted()) }
            .sorted { $0.id > $1.id }
            .prefix(14)
            .map { $0 }
    }

    private var recentSection: some View {
        Section("最近") {
            if dayFlows.isEmpty {
                Text("记录会出现在这里。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(dayFlows) { flow in
                    dayFlowRow(flow)
                }
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private func dayFlowRow(_ flow: DayFlow) -> some View {
        var parts: [String] = []
        if let w = flow.weight {
            parts.append("体重 \(String(format: "%.1f", unit.fromKg(w.weightKg)))")
        }
        if !flow.medParts.isEmpty {
            parts.append(flow.medParts.map { "\($0) ✓" }.joined(separator: " "))
        }
        let f = DateFormatter()
        f.dateFormat = "M-d"
        return HStack(spacing: 8) {
            Text(f.string(from: flow.id))
                .font(.system(size: Theme.F.caption, design: .monospaced))
                .foregroundColor(Theme.textMuted)
                .frame(width: 40, alignment: .leading)
            Text(parts.joined(separator: " · "))
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let w = flow.weight {
                Button(role: .destructive) {
                    HealthLogStore.deleteWeight(context: modelContext, entry: w)
                } label: {
                    Text("删体重")
                }
            }
        }
    }
}

// MARK: - 药物编辑 sheet（原生结构样板：CharacterCardEditor 同款）

extension HealthPanelView {
    /// 库存数字文本：整数不带小数点，小数保留一位
    static func numText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

private struct MedEditorSheet: View {
    let profileId: String
    let med: Medication?          // nil = 新建

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String
    @State private var dosage: String
    @State private var times: [Date]
    @State private var reminderEnabled: Bool
    @State private var remainingInput: String
    @State private var unitInput: String
    /// 库存三格的焦点：此前无焦点管理，单位框("片")紧贴数字框右侧，点数字右半即误落单位框，
    /// 光标停在「片」前敲数字无反应（兔兔实测）。现在单位框改只读展示，点整行进数字框。
    @FocusState private var stockFocus: StockField?
    @State private var showDeleteConfirm = false
    private enum StockField: Hashable { case remaining, perDose }
    @State private var perDoseInput: String

    init(profileId: String, med: Medication?) {
        self.profileId = profileId
        self.med = med
        _name = State(initialValue: med?.name ?? "")
        _dosage = State(initialValue: med?.dosage ?? "")
        _reminderEnabled = State(initialValue: med?.reminderEnabled ?? true)
        _remainingInput = State(initialValue: (med?.remaining ?? 0) > 0 ? HealthPanelView.numText(med!.remaining) : "")
        _unitInput = State(initialValue: med?.unit ?? "片")
        _perDoseInput = State(initialValue: HealthPanelView.numText(med?.perDose ?? 1))
        let minutes = med?.timesOfDay.sorted() ?? [8 * 60]
        _times = State(initialValue: minutes.map {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval($0 * 60))
        })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("药物") {
                    HStack {
                        Text("名称")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("比如：维生素 D", text: $name)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("剂量")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("比如：1 片", text: $dosage)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("单位")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("片", text: $unitInput)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    HStack {
                        Text("剩余")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 8)
                        TextField("0", text: $remainingInput)
                            .font(.system(size: Theme.F.body))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                            .focused($stockFocus, equals: .remaining)
                        Text(unitInput.isEmpty ? "片" : unitInput)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { stockFocus = .remaining }
                    HStack {
                        Text("每次")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("1", text: $perDoseInput)
                            .font(.system(size: Theme.F.body))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($stockFocus, equals: .perDose)
                        Text(unitInput.isEmpty ? "片" : unitInput)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { stockFocus = .perDose }
                    if let m = med, m.remaining > 0, m.perDose > 0 {
                        let doses = Int(m.remaining / m.perDose)
                        Text("按当前用量还能吃 \(doses) 次")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                } header: {
                    Text("库存")
                } footer: {
                    Text("Caelum 也能用工具补货和扣减，两边同步。")
                        .font(.system(size: Theme.F.caption))
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    ForEach(times.indices, id: \.self) { i in
                        HStack {
                            DatePicker("时刻 \(i + 1)", selection: $times[i], displayedComponents: .hourAndMinute)
                                .font(.system(size: Theme.F.body))
                            if times.count > 1 {
                                Button {
                                    times.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundColor(Theme.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if times.count < 4 {
                        Button {
                            times.append(Calendar.current.startOfDay(for: Date()).addingTimeInterval(21 * 3600))
                        } label: {
                            Label("添加时刻", systemImage: "plus.circle")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.branchIndicator)
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle(isOn: $reminderEnabled) {
                        Text("到点提醒")
                            .font(.system(size: Theme.F.body))
                    }
                    .tint(Theme.branchIndicator)
                } header: {
                    Text("每天什么时候吃")
                } footer: {
                    Text("提醒是本地通知，锁屏会显示药名和剂量。")
                }
                .listRowBackground(Theme.mainBg)

                if med != nil {
                    Section {
                        Button {
                            archive()
                        } label: {
                            Text("停药归档")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    } footer: {
                        Text("归档后不再出现在今日列表、不再提醒，历史打卡记录保留。")
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(med == nil ? "添加药物" : "编辑药物")
            .confirmationDialog("彻底删除这条药？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除，包括打卡记录", role: .destructive) { deleteForever() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("找不回来。只是停药的话选「停药归档」，记录会留着。")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 数字键盘没有回车键：给一个「完成」把键盘收掉，否则下半页永远被埋（兔兔实测）
                if stockFocus != nil {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { stockFocus = nil }
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(canSave ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!canSave)
                }
            }
        }

    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !times.isEmpty
    }

    private var minutesOfDay: [Int] {
        let cal = Calendar.current
        let minutes = times.map { cal.component(.hour, from: $0) * 60 + cal.component(.minute, from: $0) }
        return Array(Set(minutes)).sorted()
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let rem = Double(remainingInput.trimmingCharacters(in: .whitespaces)) ?? 0
        let per = max(Double(perDoseInput.trimmingCharacters(in: .whitespaces)) ?? 1, 0.01)
        let u = unitInput.trimmingCharacters(in: .whitespaces).isEmpty ? "片" : unitInput.trimmingCharacters(in: .whitespaces)
        if let med {
            med.name = trimmedName
            med.dosage = dosage.trimmingCharacters(in: .whitespaces)
            med.timesOfDay = minutesOfDay
            med.reminderEnabled = reminderEnabled
            med.remaining = rem
            med.unit = u
            med.perDose = per
            med.localEditedAt = Date()   // 标记本地改动，同步时以本地为准
        } else {
            let m = Medication(
                profileId: profileId,
                name: trimmedName,
                dosage: dosage.trimmingCharacters(in: .whitespaces),
                timesOfDay: minutesOfDay,
                reminderEnabled: reminderEnabled
            )
            m.remaining = rem
            m.unit = u
            m.perDose = per
            modelContext.insert(m)
        }
        modelContext.saveOrReport("药物")
        resyncReminders()
        // 立刻推一次，别等 45 秒节流（否则她会看到数字变回去）
        let pid = profileId
        Task { await HealthSyncService.sync(context: modelContext, profileId: pid, force: true) }
        dismiss()
    }

    /// 彻底删除：这条药和它的打卡记录一起消失
    private func deleteForever() {
        guard let m = med else { return }
        if let gid = m.gatewayId {
            Task { _ = await MedsClient.remove(id: gid) }
        }
        let mid = m.id
        let logDesc = FetchDescriptor<MedicationLog>(
            predicate: #Predicate<MedicationLog> { $0.medicationId == mid })
        for log in ((try? modelContext.fetch(logDesc)) ?? []) { modelContext.delete(log) }
        modelContext.delete(m)
        modelContext.saveOrReport("删除药物")
        resyncReminders()
        dismiss()
    }

    private func archive() {
        med?.isArchived = true
        med?.localEditedAt = Date()
        modelContext.saveOrReport("归档药物")
        resyncReminders()
        let pid = profileId
        Task { await HealthSyncService.sync(context: modelContext, profileId: pid, force: true) }
        dismiss()
    }

    private func resyncReminders() {
        let container = modelContext.container
        Task { @MainActor in
            await MedReminderScheduler.shared.resyncFromStore(container: container, profileId: profileId)
        }
    }
}
