import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 记忆分区过滤：Chats（本地新建）/ Almond（Claude导入）/ Amber（ChatGPT导入）
fileprivate enum SidebarFilter: Equatable {
    case chats
    case almond
    case amber
}

/// 左栏 tab 标识 —— 模块内可见（Sidebar/SidebarChrome.swift 的 SidebarCardShape 等引用）。
enum SidebarTab: Hashable {
    case all
    case favorites
    case trash
    case tag(id: String)

    var displayTitle: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .trash: return "回收站"
        case .tag: return ""
        }
    }

    var isCustom: Bool {
        if case .tag = self { return true }
        return false
    }
}

struct SidebarView: View {
    @Binding var searchText: String
    @State private var searchDebounceTask: Task<Void, Never>?
    @Binding var showFavoritesOnly: Bool
    @Binding var showTrash: Bool
    @Binding var showImporter: Bool
    @Binding var showSettings: Bool
    var viewModel: ConversationViewModel
    /// 路线 B 必填：@Query ConversationTag 用 init(profileId:) 构造 predicate。
    /// Parent (ContentView 在 App.body 层 `.id(profile.id)` 保证 profile 变化时 SidebarView
    /// 整个 re-init，@Query 带新 profileId predicate 自动 refetch。
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Query private var tags: [ConversationTag]

    init(
        searchText: Binding<String>,
        showFavoritesOnly: Binding<Bool>,
        showTrash: Binding<Bool>,
        showImporter: Binding<Bool>,
        showSettings: Binding<Bool>,
        viewModel: ConversationViewModel,
        profileId: String
    ) {
        self._searchText = searchText
        self._showFavoritesOnly = showFavoritesOnly
        self._showTrash = showTrash
        self._showImporter = showImporter
        self._showSettings = showSettings
        self.viewModel = viewModel
        self.profileId = profileId
        _tags = Query(
            filter: #Predicate<ConversationTag> { $0.profileId == profileId },
            sort: \ConversationTag.order
        )
    }
    @State private var conversations: [Conversation] = []
    @State private var totalCount: Int = 0
    @State private var lastNavTapTime: Date = .distantPast
    @State private var isLoadingMore = false
    @State private var showNewTagSheet = false
    @State private var showCreateGroup = false
    @State private var selectedTagId: String? = nil
    @State private var favoritedNodes: [(node: MessageNode, convTitle: String)] = []
    @State private var deletedNodes: [(node: MessageNode, convTitle: String)] = []
    @State private var renamingConversationId: String? = nil
    @State private var renameText: String = ""
    @State private var exportingConversation: Conversation? = nil
    @State private var pendingExportURL: URL? = nil        // 导出选项 sheet 生成、待关闭后分享
    @State private var exportShareItem: ExportShareItem? = nil
    @State private var searchResults: [SearchResult] = []
    @State private var stickerSearchResults: [StickerSearchResult] = []
    @State private var characterCardResults: [CharacterCardSearchResult] = []
    @State private var worldBookEntryResults: [WorldBookEntrySearchResult] = []
    @State private var memoryResults: [MemorySearchResult] = []
    @State private var isSearchActive = false
    @State private var searchBarExpanded = false
    @State private var searchFilter = SearchFilter()
    @State private var showAdvancedFilter = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var currentMatchIndex: Int = -1
    @State private var showSortPopover = false
    @State private var showProjectsPage = false
    @State private var memoryFilter: SidebarFilter = .chats
    @State private var moveToProjectConversation: Conversation? = nil
    @State private var showAllChats = false
    @AppStorage("exportMode") private var exportMode = "lightweight"
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "Caelum"
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(GlobalWorldBookManager.self) private var globalWBManager: GlobalWorldBookManager?
    @Environment(RightPanelNavigator.self) private var rightPanelNavigator: RightPanelNavigator?
    private let pageSize = 100

    var body: some View {
        VStack(spacing: 0) {
            // ── App 标题行 ──────────────────────────────────────────────────
            HStack {
                Text("Lost in Blossom")
                    .font(.custom("CormorantGaramondLight-SemiBold", size: 22))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, screenSafeAreaTop + 8)
            .padding(.bottom, 12)

            // ── 搜索栏 ──────────────────────────────────────────────────────
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.95)) {
                                if searchBarExpanded && searchText.isEmpty {
                                    searchBarExpanded = false
                                } else if !searchBarExpanded {
                                    searchBarExpanded = true
                                }
                            }
                        }

                    if searchBarExpanded {
                        TextField("搜索对话...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .onSubmit { triggerSearch() }
                            .transition(.opacity)

                        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button(action: { triggerSearch() }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAdvancedFilter.toggle()
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(searchFilter.hasActiveFilters ? Theme.branchIndicator : Theme.textMuted)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, searchBarExpanded ? 16 : 0)
                .frame(width: searchBarExpanded ? nil : 44, height: 44)
                .frame(maxWidth: searchBarExpanded ? .infinity : nil)
                .clipShape(Capsule())
                .glassEffectCompat(tint: Color.white.opacity(0.15), in: Capsule())
                .animation(.spring(response: 0.35, dampingFraction: 0.95), value: searchBarExpanded)

                if !searchBarExpanded { Spacer() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // ── 导航入口 ─────────────────────────────────────────────────────
            VStack(spacing: 0) {
                sidebarNavEntryAsset(
                    icon: "anthropicons-chats",
                    title: "Chats",
                    isSelected: !showProjectsPage && memoryFilter == .chats
                ) {
                    debouncedNavAction {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showProjectsPage = false
                            memoryFilter = .chats
                        }
                    }
                }
                sidebarNavEntryAsset(
                    icon: "anthropicons-projects",
                    title: "Projects",
                    isSelected: showProjectsPage
                ) {
                    debouncedNavAction {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showProjectsPage = true
                        }
                    }
                }
                sidebarNavEntryAsset(icon: "icon-almond", title: "Almond", isSelected: !showProjectsPage && memoryFilter == .almond) {
                    debouncedNavAction {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showProjectsPage = false
                            memoryFilter = .almond
                        }
                    }
                }
                sidebarNavEntryAsset(icon: "icon-amber", title: "Amber", isSelected: !showProjectsPage && memoryFilter == .amber) {
                    debouncedNavAction {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showProjectsPage = false
                            memoryFilter = .amber
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            // Advanced filter panel
            if showAdvancedFilter {
                AdvancedSearchPanel(
                    filter: $searchFilter,
                    userName: userName,
                    assistantName: assistantName,
                    // 角色筛选只在「对话 + 搜 content + 已按➡️」场景有意义
                    isContentSearchActive: isSearchActive && searchFilter.resourceKind == .conversation && searchFilter.scope != .titleOnly,
                    onFilterChanged: { triggerSearchIfActive() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── 标签列表（iOS 模式，支持 swipe-to-delete）─────────────────
            if !tags.isEmpty {
                List {
                    ForEach(tags) { tag in
                        Button {
                            if selectedTagId == tag.id {
                                selectTab(.all)
                            } else {
                                selectTab(.tag(id: tag.id))
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(tag.emoji)
                                    .font(.system(size: 16))
                                Text(tag.name)
                                    .font(.system(size: 15))
                                    .foregroundColor(selectedTagId == tag.id ? Theme.textPrimary : Theme.textSecondary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedTagId == tag.id
                                ? Theme.accent.opacity(0.3)
                                : Color.clear
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTag(id: tag.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(0)
                .frame(height: min(CGFloat(tags.count) * 44 + 8, 176))
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            // Chrome-style tab bar + content card
            // iOS 简化模式：隐藏 tab bar，只显示对话列表（固定「全部」视图）
            VStack(spacing: 0) {

            if isSearchActive {
                // MARK: - Search Results View
                if isSearching {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("搜索中...")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                } else {
                    let allEmpty = searchResults.isEmpty && stickerSearchResults.isEmpty && characterCardResults.isEmpty && worldBookEntryResults.isEmpty && memoryResults.isEmpty
                    if allEmpty {
                        compactEmptyCard(
                            icon: "magnifyingglass",
                            title: "没有找到结果",
                            subtitle: "换个关键词试试"
                        )
                        .sidebarCardShape(for: currentTab)

                        Spacer(minLength: 0)
                    } else if searchFilter.resourceKind == .sticker {
                        // 贴纸搜索结果
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                Color.clear.frame(height: 4)
                                ForEach(stickerSearchResults) { result in
                                    StickerMatchRow(result: result)
                                        .onTapGesture {
                                            navigateToStickerResult(result)
                                        }
                                }
                                if stickerSearchResults.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "star.circle")
                                            .font(.system(size: 28))
                                            .foregroundColor(Theme.textMuted.opacity(0.3))
                                        Text("没有找到贴纸")
                                            .font(.caption)
                                            .foregroundColor(Theme.textMuted)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.immediately)
                        .refreshable {
                            viewModel.flushPendingRefresh()
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        .sidebarCardShape(for: currentTab)
                    } else if searchFilter.resourceKind == .characterCard {
                        resourceResultsView(kind: .characterCard)
                    } else if searchFilter.resourceKind == .worldBook {
                        resourceResultsView(kind: .worldBook)
                    } else if searchFilter.resourceKind == .memory {
                        resourceResultsView(kind: .memory)
                    } else {
                        let titleCount = searchResults.filter { $0.isTitleMatch }.count
                        let contentCount = searchResults.count - titleCount
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                Color.clear.frame(height: 4)

                                // 标题块
                                if titleCount > 0 {
                                    searchBucketLabel("标题 · \(titleCount)")
                                    ForEach($searchResults) { $group in
                                        if group.isTitleMatch {
                                            searchTitleRow(group: group)
                                        }
                                    }
                                }

                                // 分隔（两块都存在时）
                                if titleCount > 0 && contentCount > 0 {
                                    Divider()
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                }

                                // 内容块
                                if contentCount > 0 {
                                    searchBucketLabel("内容 · \(contentCount)")
                                    ForEach($searchResults) { $group in
                                        if !group.isTitleMatch {
                                            searchContentRow(group: $group)
                                        }
                                    }
                                }

                                if searchResults.isEmpty {
                                    VStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: Theme.F.sectionHeader))
                                            .foregroundColor(Theme.textMuted.opacity(0.5))
                                        Text("没有找到结果")
                                            .font(.system(size: Theme.F.secondary))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.immediately)
                        .refreshable {
                            viewModel.flushPendingRefresh()
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        .sidebarCardShape(for: currentTab)
                    }
                }
            } else if showProjectsPage {
                // MARK: - Projects
                ProjectsView(profileId: profileId, viewModel: viewModel)
                Spacer(minLength: 0)
            } else {
                // MARK: - Normal Conversation List
                if shouldShowCompactListEmptyState {
                    compactEmptyCard(
                        icon: compactListEmptyStateIcon,
                        title: compactListEmptyStateTitle,
                        subtitle: compactListEmptyStateSubtitle
                    )
                    .sidebarCardShape(for: currentTab)

                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear.frame(height: 4)
                            let sourceFiltered = filteredConversations
                            let displayedConversations = showAllChats ? sourceFiltered : Array(sourceFiltered.prefix(8))
                            let hasMoreChats = !showAllChats && sourceFiltered.count > 8
                            ForEach(displayedConversations, id: \.id) { conversation in
                                if renamingConversationId == conversation.id {
                                    TextField("对话名称", text: $renameText)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: Theme.F.label, weight: .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Theme.accent.opacity(0.5))
                                        .onSubmit {
                                            let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            if !newTitle.isEmpty {
                                                conversation.title = newTitle
                                                conversation.updateTime = Date()
                                                viewModel.markConversationDirty()
                                            }
                                            renamingConversationId = nil
                                        }
                                } else {
                                    conversationRowView(conversation)
                                    .contextMenu {
                                        if showTrash {
                                            Button(action: {
                                                viewModel.restoreConversation(conversation)
                                                refreshList()
                                            }) {
                                                Label("恢复", systemImage: "arrow.uturn.backward")
                                            }

                                            Button(role: .destructive, action: {
                                                viewModel.permanentlyDeleteConversation(conversation, context: modelContext)
                                                refreshList()
                                            }) {
                                                Label("永久删除", systemImage: "trash.slash")
                                            }
                                        } else {
                                            Button(action: {
                                                renameText = conversation.title
                                                renamingConversationId = conversation.id
                                            }) {
                                                Label("重命名", systemImage: "pencil")
                                            }

                                            Button(action: { conversation.isFavorite.toggle() }) {
                                                Label(conversation.isFavorite ? "取消收藏" : "收藏整个对话", systemImage: conversation.isFavorite ? "star.slash" : "star")
                                            }

                                            Button(action: { conversation.memoryEnabled.toggle() }) {
                                                Label(conversation.memoryEnabled ? "关闭记忆参与" : "开启记忆参与", systemImage: conversation.memoryEnabled ? "brain" : "brain.head.profile")
                                            }

                                            if !tags.isEmpty {
                                                Menu("加标签") {
                                                    ForEach(tags) { tag in
                                                        Button(action: {
                                                            let item = FavoriteItem(
                                                                conversationId: conversation.id,
                                                                tagId: tag.id,
                                                                contentPreview: conversation.title,
                                                                profileId: profileId
                                                            )
                                                            ConversationListStore.insertFavorite(item, context: modelContext)
                                                        }) {
                                                            Label("\(tag.emoji) \(tag.name)", systemImage: "tag")
                                                        }
                                                    }
                                                }
                                            }

                                            Divider()

                                            Button("新建标签...") {
                                                showNewTagSheet = true
                                            }

                                            Divider()

                                            Button(action: {
                                                exportConversation(conversation)
                                            }) {
                                                Label("导出为 Markdown", systemImage: "doc.text")
                                            }

                                            Button(action: {
                                                moveToProjectConversation = conversation
                                            }) {
                                                Label("移动到项目", systemImage: "folder")
                                            }

                                            Divider()

                                            Button(role: .destructive, action: {
                                                viewModel.softDeleteConversation(conversation)
                                                refreshList()
                                            }) {
                                                Label("删除", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                if showAllChats && conversation.id == conversations.last?.id {
                                    Color.clear.frame(height: 0)
                                        .onAppear { loadMore() }
                                }
                            }

                            // "All Chats ›" footer — 仅在超过 8 条时显示
                            if hasMoreChats {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showAllChats = true
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("All Chats")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(Theme.textMuted)
                                        Spacer()
                                        Text("\(totalCount)")
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.textMuted.opacity(0.7))
                                            .monospacedDigit()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(Theme.textMuted.opacity(0.5))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }

                            // Favorited individual bubbles section
                            if showFavoritesOnly && !favoritedNodes.isEmpty {
                                Divider().opacity(0.3).padding(.horizontal, 12).padding(.vertical, 6)

                                HStack {
                                    Image(systemName: "text.bubble")
                                        .font(.caption2)
                                        .foregroundColor(Theme.textMuted)
                                    Text("收藏的气泡")
                                        .font(.caption)
                                        .foregroundColor(Theme.textMuted)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 2)

                                ForEach(favoritedNodes, id: \.node.id) { item in
                                    FavoritedBubbleRow(
                                        node: item.node,
                                        convTitle: item.convTitle,
                                        isSelected: viewModel.selectedConversation?.id == item.node.conversationId
                                    )
                                    .onTapGesture {
                                        navigateToNode(item.node)
                                    }
                                    .contextMenu {
                                        Button(action: {
                                            item.node.isFavorite = false
                                            fetchFavoritedNodes()
                                        }) {
                                            Label("取消收藏", systemImage: "star.slash")
                                        }
                                    }
                                }
                            }

                            // Deleted individual bubbles section (in trash mode)
                            if showTrash && !deletedNodes.isEmpty {
                                Divider().opacity(0.3).padding(.horizontal, 12).padding(.vertical, 6)

                                HStack {
                                    Image(systemName: "text.bubble")
                                        .font(.caption2)
                                        .foregroundColor(Theme.textMuted)
                                    Text("已删除的气泡")
                                        .font(.caption)
                                        .foregroundColor(Theme.textMuted)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 2)

                                ForEach(deletedNodes, id: \.node.id) { item in
                                    DeletedBubbleRow(
                                        node: item.node,
                                        convTitle: item.convTitle
                                    )
                                    .contextMenu {
                                        Button(action: {
                                            viewModel.restore(item.node)
                                            fetchDeletedNodes()
                                        }) {
                                            Label("恢复", systemImage: "arrow.uturn.backward")
                                        }

                                        Button(role: .destructive, action: {
                                            viewModel.permanentlyDeleteNode(item.node, context: modelContext)
                                            fetchDeletedNodes()
                                        }) {
                                            Label("永久删除", systemImage: "trash.slash")
                                        }
                                    }
                                }
                            }

                            // Empty state for trash
                            if showTrash && conversations.isEmpty && deletedNodes.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "trash")
                                        .font(.system(size: Theme.F.sectionHeader))
                                        .foregroundColor(Theme.textMuted.opacity(0.5))
                                    Text("回收站是空的")
                                        .font(.system(size: Theme.F.secondary))
                                        .foregroundColor(Theme.textMuted)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                            }

                            if isLoadingMore {
                                ProgressView()
                                    .padding()
                            }

                            // Bottom breathing room
                            Color.clear.frame(height: 4)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                    .refreshable {
                        viewModel.flushPendingRefresh()
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                    .sidebarCardShape(for: currentTab)
                }
            }
            } // end card container
            .frame(maxHeight: .infinity)

            // Stats footer + settings
            HStack(spacing: 8) {
                if isSearchActive {
                    Button(action: { clearSearch() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: Theme.F.caption))
                            Text("清除搜索")
                                .font(.caption2)
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(.plain)

                    // 搜索结果计数
                    if !isSearching {
                        resultCountLabel()
                            .font(.caption2)
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer()

                    // 匹配索引 + 上下快速翻页
                    if !flatMatches.isEmpty {
                        Text("\(currentMatchIndex + 1)/\(flatMatches.count)")
                            .font(.caption2)
                            .foregroundColor(Theme.textMuted)
                            .monospacedDigit()
                        Button(action: { navigatePrev() }) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: Theme.F.caption, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                        }
                        .buttonStyle(.plain)
                        Button(action: { navigateNext() }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: Theme.F.caption, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                        }
                        .buttonStyle(.plain)
                    }
                } else if showTrash {
                    Text("回收站中 \(totalCount) 条对话")
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                } else {
                    Text("显示 \(conversations.count) / \(totalCount) 条对话")
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            // 单击 = 新对话（手感不变）；长按 = 菜单（新对话 / 新建群聊）
            Menu {
                Button {
                    createNewConversation()
                } label: {
                    Label("新对话", systemImage: "plus.bubble")
                }
                Button {
                    createInheritedConversation()
                } label: {
                    Label("接着聊（继承上文）", systemImage: "arrow.turn.down.right")
                }
                Button {
                    showCreateGroup = true
                } label: {
                    Label("新建群聊", systemImage: "person.2")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("New chat")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(Capsule().fill(Color.black))
            } primaryAction: {
                createNewConversation()
            }
            .padding(.trailing, 20)
            .padding(.bottom, 32)
        }

        .background {
            Theme.sidebarBg.ignoresSafeArea()
        }
        .onAppear { refreshList() }
        // 路线 B 下 ContentView.id(profileId) 已经让 SidebarView 在 profile 切换时
        // 整棵 re-init，@State 自然清空。保留此 observer 作为 defense-in-depth：
        // 若 SidebarView 恰好处于某个 edge case 不 re-init（比如外层 sheet 直接调 switchTo），
        // 这里也能兜底清理 @State 里的 @Model ref。
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            conversations = []
            exportingConversation = nil
            favoritedNodes = []
            deletedNodes = []
            searchResults = []
            stickerSearchResults = []
            characterCardResults = []
            worldBookEntryResults = []
            memoryResults = []
            totalCount = 0
            renamingConversationId = nil
            selectedTagId = nil
            searchText = ""
            showAllChats = false
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { clearSearch(); refreshList(); return }
            // debounce 300ms：每次按键重置计时器，停止输入后才真正搜索
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshList()
            }
        }
        .onChange(of: selectedTagId) { _, _ in
            // B9：标签快速连点防抖（与搜索共用 task——后触发者胜，语义就是"以最新过滤为准"）
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshList()
            }
        }
        .onChange(of: memoryFilter) { _, _ in showAllChats = false; refreshList() }
        .onChange(of: showImporter) { _, showing in if !showing { refreshList() } }
        .onChange(of: showSettings) { _, showing in if !showing { refreshList() } }
        .onChange(of: viewModel.sidebarRefreshTrigger) { _, _ in refreshList() }
        .onReceive(NotificationCenter.default.publisher(for: .syncDidImport)) { _ in refreshList() }
        .sheet(isPresented: $showNewTagSheet) {
            NewTagSheet(profileId: profileId)
        }
        .sheet(isPresented: $showCreateGroup) {
            CreateGroupChatView { participants, title in
                handleCreateGroup(participants, title: title)
            }
        }
        // Settings sheet is presented from ContentView for proper centering
        .sheet(item: $exportingConversation, onDismiss: {
            // 导出选项 sheet 完全关闭后再呈现分享面板（SwiftUI 顺序 sheet 的标准做法，
            // 避免"关一个立刻开另一个"被吞）。
            if let u = pendingExportURL {
                pendingExportURL = nil
                exportShareItem = ExportShareItem(url: u)
            }
        }) { conversation in
            ExportOptionsSheet(
                conversation: conversation,
                viewModel: viewModel,
                userName: userName,
                assistantName: assistantName,
                onExported: { url in pendingExportURL = url }
            )
        }
        .sheet(item: $exportShareItem) { item in
            ExportActivityView(items: [item.url])
        }
        .sheet(item: $moveToProjectConversation) { conversation in
            ProjectPickerSheet(conversation: conversation, profileId: profileId)
        }
    }

    @ViewBuilder
    private func conversationRowView(_ conversation: Conversation) -> some View {
        let row = ConversationRow(
            conversation: conversation,
            isSelected: viewModel.selectedConversation?.id == conversation.id,
            isFirst: conversation.id == conversations.first?.id
        )
        row.onTapGesture {
            viewModel.loadConversation(conversation, context: modelContext)
        }
    }

    private func exportConversation(_ conversation: Conversation) {
        // Both modes present the export options sheet. Previously the default
        // ("lightweight") mode fell through to an empty else and the menu button
        // did nothing. Delay lets the context menu dismiss first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exportingConversation = conversation
        }
    }

    private var shouldShowCompactListEmptyState: Bool {
        if showTrash {
            return conversations.isEmpty && deletedNodes.isEmpty
        }
        if showFavoritesOnly {
            return conversations.isEmpty && favoritedNodes.isEmpty
        }
        return conversations.isEmpty
    }

    private var compactListEmptyStateIcon: String {
        if showTrash { return "trash" }
        if showFavoritesOnly { return "star" }
        if selectedTagId != nil { return "tag" }
        return "bubble.left.and.bubble.right"
    }

    private var compactListEmptyStateTitle: String {
        if showTrash { return "回收站是空的" }
        if showFavoritesOnly { return "还没有收藏" }
        if selectedTagId != nil { return "这个标签还没有对话" }
        return "还没有对话"
    }

    private var compactListEmptyStateSubtitle: String {
        if showTrash { return "删除的对话和气泡会出现在这里" }
        if showFavoritesOnly { return "收藏的对话和气泡会出现在这里" }
        if selectedTagId != nil { return "在对话上右键/长按可以加标签" }
        return "导入或新建后会出现在这里"
    }

    @ViewBuilder
    private func compactEmptyCard(icon: String, title: String, subtitle: String) -> some View {
        let cardBody = VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: Theme.F.sectionHeader))
                .foregroundColor(Theme.textMuted.opacity(0.45))

            Text(title)
                .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            Text(subtitle)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 170)

        // iOS 空态：ScrollView + 系统 .refreshable，和大卡下拉动画一致
        // （卡片跟手指下移 + 顶部 spinner 滑进）。frame(height: 170) 锁死小卡高度。
        // .scrollBounceBehavior(.always) 让没内容也能 bounce → refresh 可触发。
        // .scrollIndicators(.hidden) 去掉滚动条。
        ScrollView {
            cardBody
        }
        .frame(height: 170)
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .refreshable {
            viewModel.flushPendingRefresh()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var sortLabel: String {
        switch searchFilter.sortOrder {
        case .recent: return "最近"
        case .oldest: return "最早"
        case .titleAZ: return "A→Z"
        case .titleZA: return "Z→A"
        }
    }

    @ViewBuilder
    /// 自定义 asset 图标版本（Anthropicons）
    private func sidebarNavEntryAsset(icon: String, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textMuted)
                    .frame(width: 24, alignment: .center)
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func sidebarNavEntry(icon: String, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textMuted)
                    .frame(width: 24, alignment: .center)
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sidebarMemoryEntry(emoji: String, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(emoji)
                    .font(.system(size: 16))
                    .frame(width: 24, alignment: .center)
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textMuted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textMuted.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var filteredConversations: [Conversation] {
        switch memoryFilter {
        case .chats:   return conversations.filter { $0.source == nil }
        case .almond:  return conversations.filter { $0.source == "claude" }
        case .amber:   return conversations.filter { $0.source == "chatgpt" }
        }
    }

    /// 从 UIKit window 读取真实的状态栏 / notch 高度。
    /// SidebarView 所在的 ZStack 使用 .ignoresSafeArea()，SwiftUI 环境里
    /// safeAreaInsets 归零，必须走 UIKit 层获取正确值。
    private var screenSafeAreaTop: CGFloat {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else { return 59 }   // iPhone 常见 fallback
        return max(0, window.safeAreaInsets.top)
    }

    // MARK: - Chrome-style Tab Bar

    private var currentTab: SidebarTab {
        if showTrash { return .trash }
        if showFavoritesOnly { return .favorites }
        if let id = selectedTagId { return .tag(id: id) }
        return .all
    }

    private var allTabs: [SidebarTab] {
        var result: [SidebarTab] = [.all, .favorites, .trash]
        result.append(contentsOf: tags.map { .tag(id: $0.id) })
        return result
    }

    private func debouncedNavAction(_ action: @escaping () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastNavTapTime) > 0.3 else { return }
        lastNavTapTime = now
        action()
    }

    private func selectTab(_ tab: SidebarTab) {
        HapticService.shared.navigation()
        switch tab {
        case .all:
            showFavoritesOnly = false
            showTrash = false
            selectedTagId = nil
        case .favorites:
            showFavoritesOnly = true
            showTrash = false
            selectedTagId = nil
        case .trash:
            showTrash = true
            showFavoritesOnly = false
            selectedTagId = nil
        case .tag(let id):
            selectedTagId = id
            showFavoritesOnly = false
            showTrash = false
        }
        refreshList()
        // 如果正在搜索，切 tab 后用新 scope 重跑搜索
        triggerSearchIfActive()
    }

    private let tabCornerRadius: CGFloat = 16

    @State private var draggingTagId: String? = nil
    @State private var snappedTabId: SidebarTab? = nil

    private var sidebarTabBar: some View {
        // iOS：包一层 TabBarGestureContainer（UIHostingController wrapper），
        // 在容器 view 上挂 pan gesture，配合 TabView(.page) 的
        // require(toFail:) 屏蔽翻页
        return TabBarGestureContainer { sidebarTabBarBody }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sidebarTabBarBody: some View {
        let tabs = allTabs
        let hasCustomTags = !self.tags.isEmpty

        if hasCustomTags {
            // 有自定义 tag：「全部」锁定在左，其余进 ScrollView 横滚
            HStack(spacing: 0) {
                // 锁定的「全部」tab
                tabButton(tabs[0], index: 0, total: tabs.count, fillWidth: false)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(Array(tabs.dropFirst().enumerated()), id: \.element) { offset, tab in
                                    tabButton(tab, index: offset + 1, total: tabs.count, fillWidth: false)
                                        .id(tab)
                                }
                            }
                            .scrollTargetLayout()  // 只有 tab 是 snap 目标，加号不是
                            plusButton.id("plusButton")
                        }
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollPosition(id: $snappedTabId)
                    // 两侧都 clip 会切掉第一个 tab 的反向圆角（offset -8pt），
                    // 两侧都 clip off（scrollClipDisabled）又会让 tab 横滑时盖到「全部」上。
                    // 用 mask 自定义：leading 只延伸 8pt 给反向圆角，trailing 正常 clip。
                    .scrollClipDisabled()
                    .mask(
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width + 8, height: geo.size.height)
                                .offset(x: -8)
                        }
                    )
                    .onChange(of: snappedTabId) { oldTab, newTab in
                        // Clock 齿轮手感：划过每个 tab 都震一下
                        if oldTab != nil && newTab != nil && oldTab != newTab {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onChange(of: currentTab) { _, newTab in
                        guard newTab != .all else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newTab, anchor: .center)
                        }
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
        } else {
            // 只有内置 tab：平分宽度铺满
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    tabButton(tab, index: index, total: tabs.count, fillWidth: true)
                }
                plusButton
            }
            .padding(.horizontal, 20)
        }
    }

    private var plusButton: some View {
        Menu {
            Button {
                showNewTagSheet = true
            } label: {
                Label("新建标签", systemImage: "tag")
            }
            Button {
                showCreateGroup = true
            } label: {
                Label("新建群聊", systemImage: "person.2")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.textMuted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func tabButton(_ tab: SidebarTab, index: Int, total: Int, fillWidth: Bool) -> some View {
        let isSelected = currentTab == tab
        let isFirst = index == 0

        let label = tab.isCustom ? tagLabel(for: tab) : tab.displayTitle

        Button { selectTab(tab) } label: {
            Text(label)
                .font(.system(size: Theme.F.secondary, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .if(!fillWidth) { $0.fixedSize() }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .if(fillWidth) { $0.frame(maxWidth: .infinity) }
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: tabCornerRadius,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: tabCornerRadius
                    )
                    .fill(isSelected ? Theme.mainBg : Color.clear)
                )
                .overlay(alignment: .bottomLeading) {
                    if isSelected && !isFirst {
                        InverseTabCorner(radius: 8, flipped: true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // 选中即显示右凹弧 — 最后一个 tab 右边是 "+" 按钮（sidebarBg），也需要过渡
                    if isSelected {
                        InverseTabCorner(radius: 8, flipped: false)
                    }
                }
                .contentShape(Rectangle())   // 整个 frame 都响应点击，不只是 Text 区域
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .if(tab.isCustom) { view in
            view
                .onDrag {
                    if case .tag(let id) = tab {
                        draggingTagId = id
                        return NSItemProvider(object: id as NSString)
                    }
                    return NSItemProvider()
                }
                .onDrop(of: [UTType.text], delegate: TagReorderDropDelegate(
                    targetTagId: tagIdOf(tab) ?? "",
                    tags: tags,
                    modelContext: modelContext,
                    draggingTagId: $draggingTagId
                ))
                .contextMenu {
                    if case .tag(let id) = tab {
                        Button(role: .destructive) {
                            deleteTag(id: id)
                        } label: {
                            Label("删除标签", systemImage: "trash")
                        }
                    }
                }
        }
    }

    private func tagIdOf(_ tab: SidebarTab) -> String? {
        if case .tag(let id) = tab { return id }
        return nil
    }

    private func tagLabel(for tab: SidebarTab) -> String {
        guard case .tag(let id) = tab,
              let t = tags.first(where: { $0.id == id }) else { return "" }
        return "\(t.emoji) \(t.name)"
    }

    private func deleteTag(id: String) {
        HapticService.shared.deleteAction()
        guard let tag = tags.first(where: { $0.id == id }) else { return }
        let pid = profileManager?.currentProfile.id ?? ""
        ConversationListStore.deleteTag(tag, profileId: pid, context: modelContext)
        // 如果当前选中的就是被删的，回落
        if selectedTagId == id {
            selectedTagId = nil
            refreshList()
        }
    }

    private func navigateToNode(_ node: MessageNode) {
        // Find the conversation for this node
        let pid = profileManager?.currentProfile.id ?? ""
        guard let conversation = ConversationListStore.conversation(id: node.conversationId, profileId: pid, context: modelContext) else { return }

        // Set pending scroll BEFORE loadConversation — it fires after tree loads
        viewModel.pendingScrollNodeId = node.id
        viewModel.loadConversation(conversation, context: modelContext)
    }

    private func fetchFavoritedNodes() {
        let pid = profileManager?.currentProfile.id ?? ""
        favoritedNodes = ConversationListStore.favoritedNodes(profileId: pid, context: modelContext)
    }

    private func fetchDeletedNodes() {
        let pid = profileManager?.currentProfile.id ?? ""
        deletedNodes = ConversationListStore.deletedNodes(profileId: pid, context: modelContext)
    }

    private func conversationSortDescriptors() -> [SortDescriptor<Conversation>] {
        switch searchFilter.sortOrder {
        case .recent:
            return [SortDescriptor(\Conversation.updateTime, order: .reverse)]
        case .oldest:
            return [SortDescriptor(\Conversation.updateTime, order: .forward)]
        case .titleAZ:
            return [SortDescriptor(\Conversation.title, order: .forward)]
        case .titleZA:
            return [SortDescriptor(\Conversation.title, order: .reverse)]
        }
    }

    private func sortOptionButton(_ title: String, sort: SearchSort) -> some View {
        Button(action: {
            searchFilter.sortOrder = sort
            showSortPopover = false
            if isSearchActive { triggerSearch() }
            refreshList()
        }) {
            HStack(spacing: 6) {
                Image(systemName: searchFilter.sortOrder == sort ? "checkmark" : "")
                    .font(.system(size: Theme.F.secondary))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: Theme.F.secondary))
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var flatMatches: [MatchedNode] {
        searchResults.flatMap { $0.matchedNodes }
    }

    private func clearSearch() {
        isSearchActive = false
        isSearching = false
        searchResults = []
        stickerSearchResults = []
        characterCardResults = []
        worldBookEntryResults = []
        memoryResults = []
        currentMatchIndex = -1
        searchTask?.cancel()
    }

    private func triggerSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchFilter.keyword = keyword
        guard !keyword.isEmpty || searchFilter.dateRange != .all else {
            clearSearch()
            return
        }
        isSearchActive = true
        isSearching = true
        currentMatchIndex = -1

        // 根据当前 tab 限定搜索范围：切到空 tag 时 scope 是空 Set → 直接没结果
        searchFilter.conversationIdScope = scopeForCurrentTab()
        // 回收站 tab 下：搜的是已删除的对话
        searchFilter.includeDeletedConversations = (currentTab == .trash)

        searchTask?.cancel()
        let filter = searchFilter
        let container = modelContext.container
        let pid = profileManager?.currentProfile.id ?? ""
        let kind = filter.resourceKind

        // MainActor 取 snapshot（避免跨 actor 访问 @Observable）
        let cardsSnapshot = cardManager?.cards ?? []
        let globalBooksSnapshot = globalWBManager?.books ?? []

        searchTask = Task {
            switch kind {
            case .conversation:
                async let msgResults = SearchService.performSearch(filter: filter, profileId: pid, container: container)
                async let stickerResults = SearchService.searchPlacedStickers(keyword: keyword, profileId: pid, container: container)
                let (msgs, stickers) = await (msgResults, stickerResults)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = msgs
                    stickerSearchResults = stickers
                    characterCardResults = []
                    worldBookEntryResults = []
                    memoryResults = []
                    isSearching = false
                }
            case .branchContent:
                let msgs = await SearchService.performSearch(filter: filter, profileId: pid, container: container)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = msgs
                    stickerSearchResults = []
                    characterCardResults = []
                    worldBookEntryResults = []
                    memoryResults = []
                    isSearching = false
                }
            case .sticker:
                let stickers = await SearchService.searchPlacedStickers(keyword: keyword, profileId: pid, container: container)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    stickerSearchResults = stickers
                    searchResults = []
                    characterCardResults = []
                    worldBookEntryResults = []
                    memoryResults = []
                    isSearching = false
                }
            case .characterCard:
                let cards = SearchService.searchCharacterCards(keyword: keyword, cards: cardsSnapshot, filter: filter)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    characterCardResults = cards
                    searchResults = []
                    stickerSearchResults = []
                    worldBookEntryResults = []
                    memoryResults = []
                    isSearching = false
                }
            case .worldBook:
                let entries = await SearchService.searchWorldBookEntries(
                    keyword: keyword, globalBooks: globalBooksSnapshot,
                    profileId: pid, container: container, filter: filter
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    worldBookEntryResults = entries
                    searchResults = []
                    stickerSearchResults = []
                    characterCardResults = []
                    memoryResults = []
                    isSearching = false
                }
            case .memory:
                let mems = await SearchService.searchMemories(
                    keyword: keyword, profileId: pid, container: container, filter: filter
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    memoryResults = mems
                    searchResults = []
                    stickerSearchResults = []
                    characterCardResults = []
                    worldBookEntryResults = []
                    isSearching = false
                }
            }
        }
    }

    /// 把当前 tab 翻译成搜索范围。
    /// - 「全部」/「回收站」：nil（不限；回收站搜索仍受 performSearch 里 isTrashed==false 的约束）
    /// - 「收藏」：所有 isFavorite 的 conv id
    /// - 自定义 tag：这个 tag 的 FavoriteItem 里对应的 conv id（空 tag 返回空 Set → 搜不到任何东西）
    private func scopeForCurrentTab() -> Set<String>? {
        let pid = profileManager?.currentProfile.id ?? ""
        switch currentTab {
        case .all, .trash:
            return nil
        case .favorites:
            return ConversationListStore.favoriteConversationIds(profileId: pid, context: modelContext)
        case .tag(let id):
            return ConversationListStore.taggedConversationIds(tagId: id, profileId: pid, context: modelContext)
        }
    }

    private func navigateNext() {
        let matches = flatMatches
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        let match = matches[currentMatchIndex]
        navigateToNodeById(match.id, conversationId: match.conversationId)
    }

    private func navigatePrev() {
        let matches = flatMatches
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        let match = matches[currentMatchIndex]
        navigateToNodeById(match.id, conversationId: match.conversationId)
    }

    /// Re-trigger search when filter changes.
    /// - 资源类型（非对话）：没有"列表过滤"对应概念 → 有关键词就直接进全量搜索，否则清空
    /// - 对话类型：已按 ➡️ → 重新跑全量；未按 → 只刷新列表
    private func triggerSearchIfActive() {
        if searchFilter.resourceKind != .conversation {
            let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kw.isEmpty {
                triggerSearch()
            } else {
                clearSearch()
            }
            return
        }
        if isSearchActive {
            triggerSearch()
        } else {
            refreshList()
        }
    }

    private func navigateToNodeById(_ nodeId: String, conversationId: String) {
        let pid = profileManager?.currentProfile.id ?? ""
        guard let conversation = ConversationListStore.conversation(id: conversationId, profileId: pid, context: modelContext) else { return }
        // B20 part 2: 走 ViewModel 统一入口（去抖 + 主线/分支判断 + page 切换通知 + toast）
        viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conversation, context: modelContext)
    }

    // MARK: - Resource Result Navigation
    // 只发请求，ContentView 监听 pendingTarget 决定 iOS/macOS 怎么显示右栏

    private func navigateToCardResult(_ result: CharacterCardSearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "cardLibrary", id: result.cardId)
    }

    private func navigateToWorldBookResult(_ result: WorldBookEntrySearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "worldBook", id: result.id)
    }

    private func navigateToMemoryResult(_ result: MemorySearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "memory", id: result.id)
    }

    private func navigateToStickerResult(_ result: StickerSearchResult) {
        if let nearestId = result.nearestMessageId {
            // 同一对话不重载，只滚动（延迟让 UI 更新完成）
            if viewModel.selectedConversation?.id == result.conversationId {
                viewModel.highlightedNodeId = nearestId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    viewModel.scrollToNodeId = nearestId
                }
            } else {
                navigateToNodeById(nearestId, conversationId: result.conversationId)
            }
        } else {
            // 没有 nearestMessageId，至少跳到对话
            let pid = profileManager?.currentProfile.id ?? ""
            if let conv = ConversationListStore.conversation(id: result.conversationId, profileId: pid, context: modelContext) {
                viewModel.loadConversation(conv, context: modelContext)
            }
        }
    }

    private func createNewConversation() {
        let profileId = profileManager?.currentProfile.id ?? ""
        let conversation = viewModel.createNewConversation(title: "新对话", profileId: profileId, context: modelContext)
        refreshList()
        viewModel.loadConversation(conversation, context: modelContext)
    }

    /// P3-11 无缝上下文：继承当前对话的脉络+最近原文开新对话
    private func createInheritedConversation() {
        guard let source = viewModel.selectedConversation, source.kind != "group" else {
            createNewConversation()
            return
        }
        let profileId = profileManager?.currentProfile.id ?? ""
        let title = "↳ " + String(source.title.prefix(14))
        let conversation = viewModel.createNewConversation(title: title, profileId: profileId, context: modelContext)
        ContextInheritance.inherit(from: source, to: conversation, context: modelContext)
        refreshList()
        viewModel.loadConversation(conversation, context: modelContext)
    }

    private func handleCreateGroup(_ participants: [GroupParticipant], title: String) {
        let profileId = profileManager?.currentProfile.id ?? ""
        let cards = cardManager?.cards ?? []
        let fallback = participants.map(\.name).joined(separator: "\u{3001}")
        let finalTitle = title.isEmpty ? (fallback.isEmpty ? "新群聊" : fallback) : title
        let conversation = viewModel.createGroupConversation(participants: participants, cards: cards, title: finalTitle, profileId: profileId, context: modelContext)
        refreshList()
        viewModel.loadConversation(conversation, context: modelContext)
    }

    private func refreshList() {
        conversations.removeAll()
        fetchPage(offset: 0)
        if showFavoritesOnly {
            fetchFavoritedNodes()
        } else {
            favoritedNodes = []
        }
        if showTrash {
            fetchDeletedNodes()
        } else {
            deletedNodes = []
        }
    }

    private func loadMore() {
        guard !isLoadingMore else { return }
        fetchPage(offset: conversations.count)
    }

    private func fetchPage(offset: Int) {
        isLoadingMore = true
        let pid = profileManager?.currentProfile.id ?? ""
        let interval = searchFilter.dateRange.dateInterval
        let usingFilters = !searchText.isEmpty || searchFilter.dateRange != .all || searchFilter.sortOrder != .recent
        let sortBy = usingFilters ? conversationSortDescriptors() : [SortDescriptor(\Conversation.updateTime, order: .reverse)]

        let sourceFilter: String?
        switch memoryFilter {
        case .chats:  sourceFilter = nil
        case .almond: sourceFilter = "claude"
        case .amber:  sourceFilter = "chatgpt"
        }

        let page = ConversationListStore.fetchPage(
            offset: offset,
            pageSize: pageSize,
            profileId: pid,
            showTrash: showTrash,
            selectedTagId: selectedTagId,
            sourceFilter: sourceFilter,
            searchText: searchText,
            sortDescriptors: sortBy,
            favoritesOnly: showFavoritesOnly,
            dateInterval: interval,
            context: modelContext
        )

        totalCount = page.totalCount
        if offset == 0 {
            conversations = page.conversations
        } else {
            conversations.append(contentsOf: page.conversations)
        }
        isLoadingMore = false
    }

    // MARK: - Footer Result Count

    private func resultCountLabel() -> Text {
        switch searchFilter.resourceKind {
        case .conversation:
            let totalMatches = searchResults.reduce(0) { $0 + max(1, $1.matchedNodes.count) }
            return Text("\(searchResults.count) 个对话，\(totalMatches) 条结果")
        case .branchContent:
            let totalMatches = searchResults.reduce(0) { $0 + max(1, $1.matchedNodes.count) }
            return Text("\(searchResults.count) 个对话，\(totalMatches) 条分支结果")
        case .sticker:
            return Text("\(stickerSearchResults.count) 个贴纸")
        case .characterCard:
            return Text("\(characterCardResults.count) 个助手模板")
        case .worldBook:
            return Text("\(worldBookEntryResults.count) 条世界书")
        case .memory:
            return Text("\(memoryResults.count) 条记忆")
        }
    }

    // MARK: - Resource Results View

    @ViewBuilder
    private func resourceResultsView(kind: SearchResourceKind) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                Color.clear.frame(height: 4)
                switch kind {
                case .characterCard:
                    if characterCardResults.isEmpty {
                        resourceEmptyState(icon: "person.crop.rectangle", text: "没有找到助手模板")
                    } else {
                        ForEach(characterCardResults) { result in
                            CharacterCardMatchRow(result: result)
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToCardResult(result) }
                        }
                    }
                case .worldBook:
                    if worldBookEntryResults.isEmpty {
                        resourceEmptyState(icon: "book.closed", text: "没有找到世界书条目")
                    } else {
                        ForEach(worldBookEntryResults) { result in
                            WorldBookEntryMatchRow(result: result)
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToWorldBookResult(result) }
                        }
                    }
                case .memory:
                    if memoryResults.isEmpty {
                        resourceEmptyState(icon: "brain", text: "没有找到记忆")
                    } else {
                        ForEach(memoryResults) { result in
                            MemoryMatchRow(result: result)
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToMemoryResult(result) }
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .sidebarCardShape(for: currentTab)
    }

    @ViewBuilder
    private func resourceEmptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(Theme.textMuted.opacity(0.3))
            Text(text)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Search Result Rendering Helpers

    /// 搜索结果块的分隔标签（"标题 · 5" / "内容 · 12"）
    @ViewBuilder
    private func searchBucketLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.badge, weight: .medium))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 标题块的 row：纯标题，无 chevron、无展开
    @ViewBuilder
    private func searchTitleRow(group: SearchResult) -> some View {
        HStack(spacing: 6) {
            highlightedText(group.convTitle, keyword: searchFilter.keyword)
                .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(viewModel.selectedConversation?.id == group.convId ? Theme.accent.opacity(0.5) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            let pid = profileManager?.currentProfile.id ?? ""
            if let conv = ConversationListStore.conversation(id: group.convId, profileId: pid, context: modelContext) {
                viewModel.loadConversation(conv, context: modelContext)
            }
        }
    }

    /// 内容块的 row：可展开的 conv header + matchedNodes 列表
    @ViewBuilder
    private func searchContentRow(group: Binding<SearchResult>) -> some View {
        let g = group.wrappedValue
        Button(action: { group.isExpanded.wrappedValue.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: g.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 10)

                highlightedText(g.convTitle, keyword: searchFilter.keyword)
                    .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if g.matchedNodes.count > 0 {
                    Text("\(g.matchedNodes.count)")
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.selectedConversation?.id == g.convId ? Theme.accent.opacity(0.5) : Color.clear)
            )
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .onTapGesture {
            let pid = profileManager?.currentProfile.id ?? ""
            if let conv = ConversationListStore.conversation(id: g.convId, profileId: pid, context: modelContext) {
                viewModel.loadConversation(conv, context: modelContext)
            }
        }

        if g.isExpanded {
            let isBranch = searchFilter.resourceKind == .branchContent
            ForEach(g.matchedNodes) { match in
                ContentMatchRow(
                    nodeId: match.id,
                    role: match.role,
                    convTitle: "",
                    preview: match.preview,
                    createTime: match.createTime,
                    userName: userName,
                    assistantName: assistantName,
                    keyword: match.keyword
                )
                .padding(.leading, isBranch ? 32 : 16)
                .overlay(alignment: .topLeading) {
                    if isBranch {
                        Text("🌿")
                            .font(.system(size: 11))
                            .padding(.leading, 10)
                            .padding(.top, 6)
                            .opacity(0.7)
                    }
                }
                .onTapGesture {
                    if let idx = flatMatches.firstIndex(where: { $0.id == match.id }) {
                        currentMatchIndex = idx
                    }
                    navigateToNodeById(match.id, conversationId: match.conversationId)
                }
            }
        }
    }
}
