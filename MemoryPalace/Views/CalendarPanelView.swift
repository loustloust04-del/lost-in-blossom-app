import SwiftUI
import SwiftData

// MARK: - Calendar Panel (Right Sidebar)

struct CalendarPanelView: View {
    @Environment(\.modelContext) private var modelContext
    var viewModel: ConversationViewModel
    let profileId: String
    @Query private var allConversations: [Conversation]

    init(viewModel: ConversationViewModel, profileId: String) {
        self.viewModel = viewModel
        self.profileId = profileId
        _allConversations = Query(
            filter: #Predicate<Conversation> { $0.profileId == profileId && !$0.isTrashed },
            sort: \Conversation.createTime,
            order: .forward
        )
    }

    @State private var displayedMonth = Date()
    @State private var selectedDate = Date()

    private let calendar = Calendar.current
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        let conversations = conversationsForSelectedDate

        VStack(spacing: 0) {
            // Calendar card (header + grid combined)
            VStack(spacing: 0) {
                calendarHeader
                calendarGrid
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.mainBg.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.accent.opacity(0.72), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.top, 0)
            .padding(.bottom, 0)

            dayConversationSection(conversations)

            if conversations.isEmpty {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Theme.sidebarBg.ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var calendarHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(monthYearString)
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Button("今天") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    displayedMonth = Date()
                    selectedDate = Date()
                }
            }
            .font(.system(size: Theme.F.secondary, weight: .bold))
            .foregroundColor(Theme.branchIndicator)
            .buttonStyle(.plain)

            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Grid

    private var calendarGrid: some View {
        let daysWithConversations = conversationCountByDay

        return VStack(spacing: 2) {
            // Weekday header
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 4)

            // Day cells
            let cells = generateMonthCells()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(cells, id: \.id) { cell in
                    if let date = cell.date {
                        let day = calendar.component(.day, from: date)
                        let hasConversations = daysWithConversations[day, default: 0] > 0
                        let isToday = calendar.isDateInToday(date)
                        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                            && calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)

                        DayCell(
                            day: day,
                            isToday: isToday,
                            isSelected: isSelected,
                            hasConversations: hasConversations
                        )
                        .onTapGesture {
                            selectedDate = date
                        }
                    } else {
                        Color.clear
                            .frame(height: 36)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Day Conversation List

    @ViewBuilder
    private func dayConversationSection(_ conversations: [Conversation]) -> some View {
        if conversations.isEmpty {
            VStack(spacing: 0) {
                dayConversationHeader(count: 0)

                Rectangle()
                    .fill(Theme.accent.opacity(0.65))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.textMuted.opacity(0.45))
                    Text("这天没有对话")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 160)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .background(dayCardBackground)
            .overlay(dayCardStroke)
            .clipShape(dayCardShape)
            .padding(.horizontal, 8)
            .padding(.top, 0)
            .padding(.bottom, 0)
        } else {
            VStack(spacing: 0) {
                dayConversationHeader(count: conversations.count)

                Rectangle()
                    .fill(Theme.accent.opacity(0.65))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isSelected: viewModel.selectedConversation?.id == conversation.id,
                                isFirst: conversation.id == conversations.first?.id
                            )
                            .onTapGesture {
                                viewModel.loadConversation(conversation, context: modelContext)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxHeight: .infinity)
            .background(dayCardBackground)
            .overlay(dayCardStroke)
            .clipShape(dayCardShape)
            .padding(.horizontal, 8)
            .padding(.top, 0)
            .padding(.bottom, 0)
        }
    }

    private func dayConversationHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selectedDateString)
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            Spacer()

            Text("\(count) 条")
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var dayCardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Theme.mainBg.opacity(0.9))
    }

    private var dayCardStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Theme.accent.opacity(0.72), lineWidth: 1)
    }

    private var dayCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    // MARK: - Data Helpers

    /// Count of conversations per day in the displayed month
    private var conversationCountByDay: [Int: Int] {
        let range = monthRange(for: displayedMonth)
        var counts: [Int: Int] = [:]
        for conv in allConversations {
            if conv.createTime >= range.start && conv.createTime < range.end {
                let day = calendar.component(.day, from: conv.createTime)
                counts[day, default: 0] += 1
            }
        }
        return counts
    }

    /// Conversations created on the selected date
    private var conversationsForSelectedDate: [Conversation] {
        let dayStart = calendar.startOfDay(for: selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return allConversations.filter { conv in
            conv.createTime >= dayStart && conv.createTime < dayEnd
        }
    }

    // MARK: - Calendar Helpers

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: displayedMonth)
    }

    private var selectedDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: selectedDate)
    }

    private func shiftMonth(_ offset: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if let newDate = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
                displayedMonth = newDate
                selectedDate = alignedSelectionDate(for: newDate)
            }
        }
    }

    private func alignedSelectionDate(for month: Date) -> Date {
        let selectedDay = calendar.component(.day, from: selectedDate)
        let targetDay = min(selectedDay, calendar.range(of: .day, in: .month, for: month)?.count ?? selectedDay)
        var comps = calendar.dateComponents([.year, .month], from: month)
        comps.day = targetDay
        return calendar.date(from: comps) ?? month
    }

    private func monthRange(for date: Date) -> (start: Date, end: Date) {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: comps)!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return (start, end)
    }

    private func generateMonthCells() -> [CalendarCell] {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        let firstOfMonth = calendar.date(from: comps)!
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) // 1=Sunday
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count

        var cells: [CalendarCell] = []

        // Leading empty cells
        for i in 0..<(firstWeekday - 1) {
            cells.append(CalendarCell(id: "empty-\(i)", date: nil))
        }

        // Day cells
        for day in 1...daysInMonth {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                cells.append(CalendarCell(id: "day-\(day)", date: date))
            }
        }

        return cells
    }
}

// MARK: - Calendar Cell Model

private struct CalendarCell: Identifiable {
    let id: String
    let date: Date?
}

// MARK: - Day Cell View

private struct DayCell: View {
    let day: Int
    let isToday: Bool
    let isSelected: Bool
    let hasConversations: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text("\(day)")
                .font(.system(size: Theme.F.label, weight: isToday ? .bold : .regular))
                .foregroundColor(isToday ? Theme.branchIndicator : Theme.textPrimary)

            Circle()
                .fill(hasConversations ? Theme.branchIndicator : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(cellBackground)
        )
    }

    private var cellBackground: Color {
        if isSelected {
            return Theme.accent.opacity(0.5)
        } else if isToday {
            return Theme.branchIndicator.opacity(0.15)
        } else {
            return Color.clear
        }
    }
}
