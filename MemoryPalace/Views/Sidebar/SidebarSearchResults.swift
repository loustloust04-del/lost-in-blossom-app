// 从 SidebarView.swift 拆出：高级搜索面板 + 各类搜索结果行

import SwiftUI
import SwiftData
import UniformTypeIdentifiers


// MARK: - Content Match Row

// MARK: - Sticker Match Row（贴纸搜索结果）

struct StickerMatchRow: View {
    let result: StickerSearchResult

    var body: some View {
        HStack(spacing: 8) {
            // 贴纸图标/缩略图
            if result.isNote {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: 1, green: 0.96, blue: 0.75))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(String((result.noteContent ?? "").prefix(2)))
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textPrimary)
                    )
            } else {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.branchIndicator.opacity(0.6))
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("🎨")
                        .font(.system(size: 9))
                    Text(result.assetName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text(result.conversationTitle)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
        )
        .padding(.horizontal, 8)
    }
}


// MARK: - Character Card Match Row

struct CharacterCardMatchRow: View {
    let result: CharacterCardSearchResult

    var body: some View {
        HStack(spacing: 8) {
            // 头像缩略
            Group {
                if let data = result.imageData {
                    if let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else { Image(systemName: "person.crop.rectangle") }
                } else {
                    Image(systemName: "person.crop.rectangle")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    highlightedText(result.cardName, keyword: result.keyword)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(result.matchedField)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                }
                highlightedText(result.preview, keyword: result.keyword)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}


// MARK: - World Book Entry Match Row

struct WorldBookEntryMatchRow: View {
    let result: WorldBookEntrySearchResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.isGlobal ? "globe" : "book.closed")
                .font(.system(size: 14))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(result.bookName)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Text("›")
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                    highlightedText(result.entryTitle, keyword: result.keyword)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(result.matchedField)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                }
                highlightedText(result.preview, keyword: result.keyword)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}


// MARK: - Memory Match Row

struct MemoryMatchRow: View {
    let result: MemorySearchResult

    private var categoryLabel: String {
        switch result.category {
        case "fact": return "事实"
        case "preference": return "偏好"
        case "relationship": return "关系"
        case "goal": return "目标"
        case "context": return "情境"
        default: return result.category
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 13))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(categoryLabel)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                }
                highlightedText(result.preview, keyword: result.keyword)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}


// MARK: - Content Match Row

struct ContentMatchRow: View {
    let nodeId: String
    let role: String
    let convTitle: String
    let preview: String
    let createTime: Date?
    let userName: String
    let assistantName: String
    var keyword: String = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: Theme.F.badge))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                if !convTitle.isEmpty {
                    Text(convTitle)
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }

                highlightedText(preview, keyword: keyword)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(role == "user" ? userName : assistantName)
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                if let time = createTime {
                    Text(Self.dateFormatter.string(from: time))
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
        )
        .padding(.horizontal, 8)
    }
}

// MARK: - Keyword Highlighting Helper

func highlightedText(_ text: String, keyword: String) -> Text {
    guard !keyword.isEmpty else { return Text(text) }
    var result = Text("")
    var searchStart = text.startIndex

    while let range = text.range(of: keyword, options: .caseInsensitive, range: searchStart..<text.endIndex) {
        let before = text[searchStart..<range.lowerBound]
        if !before.isEmpty {
            result = result + Text(before)
        }
        let matched = text[range]
        result = result + Text(matched)
            .foregroundColor(Theme.branchIndicator)
            .bold()
        searchStart = range.upperBound
    }
    let tail = text[searchStart...]
    if !tail.isEmpty {
        result = result + Text(tail)
    }
    return result
}


// MARK: - Advanced Search Panel

struct AdvancedSearchPanel: View {
    @Binding var filter: SearchFilter
    let userName: String
    let assistantName: String
    /// 是否处于全量内容搜索模式（按过 ➡️）。false = 列表标题过滤模式，角色筛选无意义 → 灰掉
    let isContentSearchActive: Bool
    var onFilterChanged: () -> Void

    /// 资源类型下（角色卡/世界书/记忆），范围/角色筛选无意义 → 灰掉
    private var isResourceSearch: Bool {
        filter.resourceKind == .characterCard ||
        filter.resourceKind == .worldBook ||
        filter.resourceKind == .memory
    }

    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 范围
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                categoryLabel("范围")
                scopeChip("标题", scope: .titleOnly)
                scopeChip("内容", scope: .contentOnly)
                scopeChip("标题+内容", scope: .both)
            }

            // 时间
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    categoryLabel("时间")
                    dateChip("全部", range: .all)
                    dateChip("今天", range: .today)
                    dateChip("7 天", range: .last7Days)
                    dateChip("30 天", range: .last30Days)
                    dateChip("90 天", range: .last90Days)
                    dateChip("自定义", range: .custom(start: customStart, end: customEnd))
                }

                if case .custom = filter.dateRange {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $customStart, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: 110)
                        Text("—")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                        DatePicker("", selection: $customEnd, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: 110)
                    }
                    .onChange(of: customStart) { _, _ in
                        filter.dateRange = .custom(start: customStart, end: customEnd)
                        onFilterChanged()
                    }
                    .onChange(of: customEnd) { _, _ in
                        filter.dateRange = .custom(start: customStart, end: customEnd)
                        onFilterChanged()
                    }
                }
            }

            // 角色
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                categoryLabel("角色")
                roleChip(userName, role: "user")
                roleChip(assistantName, role: "assistant")
            }

            // 排序
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                categoryLabel("排序")
                sortChip("最近", sort: .recent)
                sortChip("最早", sort: .oldest)
                sortChip("A→Z", sort: .titleAZ)
                sortChip("Z→A", sort: .titleZA)
            }

            // 类型 — 6 个 chip 一行塞不下，用 FlowLayout 自动换行（B20 part 2 反馈 Bβ）
            VStack(alignment: .leading, spacing: 6) {
                categoryLabel("类型")
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    typeChip("全部", kind: .conversation)
                    typeChip("🌿 分支", kind: .branchContent)
                    typeChip("🎨 贴纸", kind: .sticker)
                    typeChip("👤 助手模板", kind: .characterCard)
                    typeChip("📚 世界书", kind: .worldBook)
                    typeChip("🧠 记忆", kind: .memory)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 25)
        .padding(.trailing, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    /// 分类名（时间/角色/排序/类型）
    private func categoryLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: Theme.F.badge, weight: .medium))
            .foregroundColor(Theme.textMuted)
    }

    /// 统一的纯文字过滤选项：字号 = tab 栏字号，选中态靠字重+颜色，无背景
    private func filterOption(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Theme.branchIndicator : Theme.textSecondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateChip(_ title: String, range: DateRange) -> some View {
        filterOption(title, isActive: filter.dateRange == range) {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.dateRange = range
            }
            onFilterChanged()
        }
    }

    private func roleChip(_ title: String, role: String) -> some View {
        let isActive = filter.roles.contains(role)
        // 列表标题过滤模式下，角色对 Conversation.title 无意义 → 灰掉 + 禁用
        return Button(action: {
            if isActive && filter.roles.count > 1 {
                filter.roles.remove(role)
            } else if !isActive {
                filter.roles.insert(role)
            }
            onFilterChanged()
        }) {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: isActive && isContentSearchActive ? .semibold : .regular))
                .foregroundColor(
                    isContentSearchActive
                        ? (isActive ? Theme.branchIndicator : Theme.textSecondary)
                        : Theme.textMuted.opacity(0.4)
                )
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isContentSearchActive)
    }

    private func sortChip(_ title: String, sort: SearchSort) -> some View {
        filterOption(title, isActive: filter.sortOrder == sort) {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.sortOrder = sort
            }
            onFilterChanged()
        }
    }

    private func scopeChip(_ title: String, scope: SearchScope) -> some View {
        // 资源搜索（角色卡/世界书/记忆）没"标题 vs 内容"二分 → 灰掉 + 禁用
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.scope = scope
            }
            onFilterChanged()
        }) {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: filter.scope == scope && !isResourceSearch ? .semibold : .regular))
                .foregroundColor(
                    isResourceSearch
                        ? Theme.textMuted.opacity(0.4)
                        : (filter.scope == scope ? Theme.branchIndicator : Theme.textSecondary)
                )
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isResourceSearch)
    }

    private func typeChip(_ title: String, kind: SearchResourceKind) -> some View {
        filterOption(title, isActive: filter.resourceKind == kind) {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.resourceKind = kind
            }
            onFilterChanged()
        }
    }
}
