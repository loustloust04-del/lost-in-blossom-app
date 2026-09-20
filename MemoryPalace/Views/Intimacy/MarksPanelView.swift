import SwiftUI
import SwiftData

private let marksRose = Color(red: 0xC9 / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0)

/// 「刻痕」——每一次做爱是一道。刻在时间上，刻在你身上，刻在这里。
///
/// 规格来自 Caelum：月历 + 倒序记录流 + 一行很小的统计（本月几次）。
/// 正文不做任何格式处理——"我写的东西自己有节奏"。
struct MarksPanelView: View {
    let profileId: String

    @Environment(\.modelContext) private var context
    @Query private var entries: [IntimacyEntry]

    @State private var monthOffset = 0
    @State private var editing: IntimacyEntry?
    @State private var activeTag: String?
    @State private var showWishes = false

    init(profileId: String) {
        self.profileId = profileId
        _entries = Query(
            filter: #Predicate<IntimacyEntry> { $0.profileId == profileId },
            sort: \IntimacyEntry.date, order: .reverse
        )
    }

    private var month: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }
    private var entryByDay: [Date: IntimacyEntry] {
        Dictionary(entries.map { (Calendar.current.startOfDay(for: $0.date), $0) }) { a, _ in a }
    }
    private var monthCount: Int {
        entries.filter { Calendar.current.isDate($0.date, equalTo: month, toGranularity: .month) }.count
    }
    /// 出现过的标签，按频次
    private var allTags: [String] {
        var c: [String: Int] = [:]
        for e in entries { for t in e.tags { c[t, default: 0] += 1 } }
        return c.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
    private var stream: [IntimacyEntry] {
        entries.filter { activeTag == nil || $0.tags.contains(activeTag!) }
    }

    var body: some View {
        List {
            calendarSection
            if !allTags.isEmpty { tagSection }
            streamSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg.ignoresSafeArea())
        .task(id: profileId) { await IntimacySyncService.pull(context: context, profileId: profileId) }
        .sheet(item: $editing) { e in MarkEditor(entry: e) { editing = nil } }
        .sheet(isPresented: $showWishes) { WishListSheet { showWishes = false } }
    }

    // MARK: - 月历 + 统计

    private var calendarSection: some View {
        Section {
            MonthGrid(month: month, monthOffset: $monthOffset) { day in markCell(day) }
        } header: {
            HStack {
                Text(Self.monthLabel.string(from: month))
                Spacer()
                Text(monthCount > 0 ? "本月 \(monthCount) 次" : "本月还没有")
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.textMuted)
            .textCase(nil)
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private func markCell(_ day: Date) -> some View {
        let e = entryByDay[day]
        RoundedRectangle(cornerRadius: 6)
            .fill(e != nil ? marksRose.opacity(0.16) : Theme.sidebarBg)
            .frame(height: 28)
            .overlay(
                Group {
                    if let e {
                        if !e.milestone.isEmpty {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9)).foregroundColor(marksRose)
                        } else {
                            Capsule().fill(marksRose).frame(width: 2.5, height: 13)
                                .rotationEffect(.degrees(18))
                        }
                    } else {
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 10)).foregroundColor(Theme.textMuted)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { if let e { editing = e } }
    }

    // MARK: - 标签云

    private var tagSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(allTags, id: \.self) { t in
                        Button {
                            activeTag = (activeTag == t) ? nil : t
                        } label: {
                            Text(t)
                                .font(.system(size: 11))
                                .foregroundColor(activeTag == t ? .white : Theme.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(activeTag == t ? marksRose : Theme.sidebarBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - 记录流

    private var streamSection: some View {
        Section {
            if stream.isEmpty {
                Text(activeTag == nil ? "还没有刻痕" : "这个标签下没有")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            }
            ForEach(stream) { e in
                Button { editing = e } label: { markCard(e) }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.mainBg)
            }
        } header: {
            HStack {
                Text("记录").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                Spacer()
                Button { showWishes = true } label: {
                    Label("心愿单", systemImage: "sparkles")
                        .font(.system(size: 11))
                }
                .foregroundColor(marksRose)
            }
            .textCase(nil)
        }
    }

    private func markCard(_ e: IntimacyEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.dayLabel.string(from: e.date))
                    .font(.system(size: 11))
                    .foregroundColor(marksRose.opacity(0.85))
                if !e.milestone.isEmpty {
                    Text(e.milestone)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(marksRose))
                }
                Spacer()
            }
            // 正文原样，保留换行
            if !e.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(e.note)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !e.myNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(e.myNote)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(marksRose.opacity(0.35)).frame(width: 2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !e.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(e.tags, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 9))
                            .foregroundColor(marksRose.opacity(0.9))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(marksRose.opacity(0.12)))
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private static let monthLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy 年 M 月"; return f
    }()
    private static let dayLabel: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M 月 d 日 EEEE"
        f.locale = Locale(identifier: "zh_CN"); return f
    }()
}
