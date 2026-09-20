import Foundation

/// 主线过滤的分批大小：每批 2 次 IN 查询，内存峰值 = 一批对话的全部节点（B9）
private let mainPathBatchSize = 20
import SwiftData

// MARK: - Search Types

enum SearchSort: String, CaseIterable {
    case recent, oldest, titleAZ, titleZA
}

enum SearchScope: String, CaseIterable {
    /// 只搜对话标题（默认；等价于"列表过滤模式"）
    case titleOnly
    /// 只搜消息内容
    case contentOnly
    /// 标题 + 内容，结果分块显示（标题块在上）
    case both
}

enum SearchResourceKind: String, CaseIterable {
    /// 对话（标题 + 内容；内容仅主线，B20 part 2）
    case conversation
    /// 分支（仅搜每个对话主线之外的分支气泡内容）
    case branchContent
    /// 贴纸（searchPlacedStickers）
    case sticker
    /// 角色卡
    case characterCard
    /// 世界书条目
    case worldBook
    /// 记忆（Memory）
    case memory
}

enum DateRange: Equatable {
    case all
    case today
    case last7Days
    case last30Days
    case last90Days
    case custom(start: Date, end: Date)

    var dateInterval: (start: Date, end: Date)? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .all:
            return nil
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now)
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: now)!
            return (start, now)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now)!
            return (start, now)
        case .last90Days:
            let start = calendar.date(byAdding: .day, value: -90, to: now)!
            return (start, now)
        case .custom(let start, let end):
            return (start, end)
        }
    }
}

struct SearchFilter {
    var keyword: String = ""
    var dateRange: DateRange = .all
    var roles: Set<String> = ["user", "assistant"]
    var sortOrder: SearchSort = .recent
    /// 搜索范围：标题 / 内容 / 标题+内容。默认 .titleOnly（列表过滤模式等价）
    var scope: SearchScope = .titleOnly
    /// 搜索的资源类型（对话 / 贴纸 / 角色卡 / 世界书 / 记忆）
    var resourceKind: SearchResourceKind = .conversation
    /// 当前 tab 对应的对话 id 范围。
    /// nil = 不限（「全部」/「回收站」）；非 nil = 只搜这些 conv（空 Set 表示 tab 没任何对话 → 直接返回空结果）。
    var conversationIdScope: Set<String>? = nil
    /// 回收站模式：搜已删除的对话（`conv.isTrashed == true`）；默认 false 只搜未删除。
    var includeDeletedConversations: Bool = false

    var hasActiveFilters: Bool {
        dateRange != .all || roles != Set(["user", "assistant"])
    }
}

struct MatchedNode: Identifiable {
    let id: String
    let role: String
    let preview: String
    let createTime: Date?
    let conversationId: String
    let keyword: String
}

struct SearchResult: Identifiable {
    /// 行唯一 id（convId + 块标识）。overlap conv 在 both 模式下会出现两次，必须独立 id
    let id: String
    /// 对话 id（跳转 / 选中状态用）
    let convId: String
    let convTitle: String
    let convTime: Date
    let matchedNodes: [MatchedNode]
    let isTitleMatch: Bool
    var isExpanded: Bool

    init(convId: String, convTitle: String, convTime: Date, matchedNodes: [MatchedNode], isTitleMatch: Bool) {
        self.id = "\(convId):\(isTitleMatch ? "t" : "c")"
        self.convId = convId
        self.convTitle = convTitle
        self.convTime = convTime
        self.matchedNodes = matchedNodes
        self.isTitleMatch = isTitleMatch
        self.isExpanded = !matchedNodes.isEmpty
    }
}

// MARK: - Search Service

enum SearchService {

    static func performSearch(filter: SearchFilter, profileId: String, container: ModelContainer) async -> [SearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 当前 tab scope 是明确的空集 → 一定搜不到，直接 short circuit
                if let scope = filter.conversationIdScope, scope.isEmpty {
                    continuation.resume(returning: [])
                    return
                }

                let context = ModelContext(container)
                context.autosaveEnabled = false
                let scopedProfileId = profileId

                let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                let interval = filter.dateRange.dateInterval
                let hasUser = filter.roles.contains("user")
                let hasAssistant = filter.roles.contains("assistant")
                let scope = filter.conversationIdScope  // 局部捕获方便下面使用

                // .branchContent 只搜 content（标题不分主线/分支，混搜没意义）
                let isBranchOnly = filter.resourceKind == .branchContent
                let needsContent = (filter.scope == .contentOnly || filter.scope == .both) || isBranchOnly
                let needsTitle = (filter.scope == .titleOnly || filter.scope == .both) && !isBranchOnly

                // --- 1. Search message content ---
                var contentByConv: [String: [MatchedNode]] = [:]

                if needsContent && !keyword.isEmpty {
                    let search = keyword
                    // 时间过滤不放进 predicate：SwiftData 对 optional `!=nil && !` 拆包
                    // 和 `localizedStandardContains` 组合时会返回空。先按关键词+角色取出，
                    // 再在 Swift 层按 createTime 过滤。关键词已经把结果缩到很少。
                    var contentNodes = fetchContentWithKeyword(
                        context: context, search: search, profileId: scopedProfileId,
                        hasUser: hasUser, hasAssistant: hasAssistant
                    )
                    if let interval = interval {
                        let s = interval.start
                        let e = interval.end
                        contentNodes = contentNodes.filter { node in
                            guard let t = node.createTime else { return false }
                            return t >= s && t <= e
                        }
                    }

                    // B20 part 2: 主线/分支过滤
                    // .conversation → 仅保留主线 node；.branchContent → 仅保留非主线 node
                    let needsMainPathFilter = filter.resourceKind == .conversation || filter.resourceKind == .branchContent
                    if needsMainPathFilter {
                        // B9: 命中对话按批分组 IN 查询（原来每对话 2 次 fetch，几百命中 = 几百次往返）。
                        // 不用 propertiesToFetch 瘦身：computeMainPathSet 的可显判定依赖 content +
                        // segmentsData，漏列属性逐行 fault 反而更慢。
                        let nodesByConv = Dictionary(grouping: contentNodes) { $0.conversationId }
                        var allowedNodeIds = Set<String>()
                        allowedNodeIds.reserveCapacity(contentNodes.count)
                        let hitConvIds = Array(nodesByConv.keys)
                        let pid = scopedProfileId
                        for start in stride(from: 0, to: hitConvIds.count, by: mainPathBatchSize) {
                            let chunk = Array(hitConvIds[start..<min(start + mainPathBatchSize, hitConvIds.count)])
                            let convDesc = FetchDescriptor<Conversation>(
                                predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId == pid }
                            )
                            let convs = (try? context.fetch(convDesc)) ?? []
                            let currentNodeByConv = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0.currentNodeId) })
                            let allNodesDesc = FetchDescriptor<MessageNode>(
                                predicate: #Predicate<MessageNode> { chunk.contains($0.conversationId) && $0.profileId == pid }
                            )
                            let allNodesInChunk = (try? context.fetch(allNodesDesc)) ?? []
                            let allNodesByConv = Dictionary(grouping: allNodesInChunk) { $0.conversationId }
                            for convId in chunk {
                                // 对话行查不到（孤儿节点）→ 整对话排除，与改造前 guard-continue 同语义
                                guard let currentNodeId = currentNodeByConv[convId],
                                      let nodesInConv = nodesByConv[convId] else { continue }
                                let mainPathSet = ConversationViewModel.computeMainPathSet(
                                    nodes: allNodesByConv[convId] ?? [],
                                    currentNodeId: currentNodeId
                                )
                                for node in nodesInConv {
                                    let onMain = mainPathSet.contains(node.id)
                                    if filter.resourceKind == .conversation && onMain {
                                        allowedNodeIds.insert(node.id)
                                    } else if filter.resourceKind == .branchContent && !onMain {
                                        allowedNodeIds.insert(node.id)
                                    }
                                }
                            }
                        }
                        contentNodes = contentNodes.filter { allowedNodeIds.contains($0.id) }
                    }

                    for node in contentNodes {
                        if let scope = scope, !scope.contains(node.conversationId) { continue }
                        let cleaned = ContentCleaner.clean(node.content, cacheKey: node.id)
                        let preview = buildPreview(cleaned, keyword: keyword)
                        let matched = MatchedNode(
                            id: node.id,
                            role: node.role,
                            preview: preview,
                            createTime: node.createTime,
                            conversationId: node.conversationId,
                            keyword: keyword
                        )
                        contentByConv[node.conversationId, default: []].append(matched)
                    }
                }
                // 注：无关键词+有时间+需要内容 这条路径曾经用 fetchNodesDateOnly 收集 conv，
                // 但那个函数依赖 SwiftData optional createTime predicate 会返回空。
                // 场景极边缘（用户没输关键词却搜内容），直接不跑；时间范围内的 conv 由 title
                // 路径负责列出。

                // --- 2. Search conversation titles ---
                var titleConvs: [Conversation] = []
                if needsTitle {
                    titleConvs = fetchFilteredConversations(
                        context: context, keyword: keyword, profileId: scopedProfileId, interval: interval,
                        includeDeleted: filter.includeDeletedConversations
                    )
                }

                // --- 3. 分块构建：titleBucket 与 contentBucket 独立 ---
                var titleBucket: [SearchResult] = []
                var contentBucket: [SearchResult] = []

                // 标题块：纯 title row，不展开内容（matchedNodes 强制空）
                for conv in titleConvs {
                    if let scope = scope, !scope.contains(conv.id) { continue }
                    titleBucket.append(SearchResult(
                        convId: conv.id,
                        convTitle: conv.title,
                        convTime: conv.updateTime,
                        matchedNodes: [],
                        isTitleMatch: true
                    ))
                }

                // 内容块：按 convId group matchedNodes。both 模式下 overlap conv 会在两块都出现（决策 B）
                if !contentByConv.isEmpty {
                    let wantDeleted = filter.includeDeletedConversations
                    let allConvDesc = FetchDescriptor<Conversation>(
                        predicate: #Predicate<Conversation> {
                            conv in conv.profileId == scopedProfileId && conv.isTrashed == wantDeleted
                        }
                    )
                    let allConvs = (try? context.fetch(allConvDesc)) ?? []
                    let convMap = Dictionary(uniqueKeysWithValues: allConvs.map { ($0.id, $0) })
                    for (convId, nodes) in contentByConv {
                        if let conv = convMap[convId] {
                            contentBucket.append(SearchResult(
                                convId: conv.id,
                                convTitle: conv.title,
                                convTime: conv.updateTime,
                                matchedNodes: nodes,
                                isTitleMatch: false
                            ))
                        }
                    }
                }

                // --- 4. 各块分别 sort，标题块恒在上 ---
                let sorter: (SearchResult, SearchResult) -> Bool = {
                    switch filter.sortOrder {
                    case .recent: return { $0.convTime > $1.convTime }
                    case .oldest: return { $0.convTime < $1.convTime }
                    case .titleAZ: return { $0.convTitle.localizedCompare($1.convTitle) == .orderedAscending }
                    case .titleZA: return { $0.convTitle.localizedCompare($1.convTitle) == .orderedDescending }
                    }
                }()
                titleBucket.sort(by: sorter)
                contentBucket.sort(by: sorter)

                continuation.resume(returning: titleBucket + contentBucket)
            }
        }
    }

    // MARK: - Content Search (keyword IN predicate — SQLite filters)

    /// Keyword search, no date range
    private static func fetchContentWithKeyword(
        context: ModelContext, search: String, profileId: String,
        hasUser: Bool, hasAssistant: Bool
    ) -> [MessageNode] {
        let desc: FetchDescriptor<MessageNode>
        let pid = profileId
        if hasUser && hasAssistant {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false &&
                    (node.role == "user" || node.role == "assistant") &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else if hasUser {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false && node.role == "user" &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else if hasAssistant {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false && node.role == "assistant" &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else {
            return []
        }
        return (try? context.fetch(desc)) ?? []
    }

    /// Fetch conversations matching title keyword + date range
    /// - Parameter includeDeleted: true → 只搜已删除对话（回收站模式）；false → 只搜未删除
    private static func fetchFilteredConversations(
        context: ModelContext,
        keyword: String,
        profileId: String,
        interval: (start: Date, end: Date)?,
        includeDeleted: Bool = false
    ) -> [Conversation] {
        let wantDeleted = includeDeleted   // 本地常量，#Predicate 要能捕获
        let pid = profileId
        guard !keyword.isEmpty else {
            guard let interval = interval else { return [] }
            let startDate = interval.start
            let endDate = interval.end
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == wantDeleted &&
                    conv.createTime >= startDate && conv.createTime <= endDate
                }
            )
            return (try? context.fetch(desc)) ?? []
        }

        let search = keyword
        if let interval = interval {
            let startDate = interval.start
            let endDate = interval.end
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == wantDeleted &&
                    conv.title.localizedStandardContains(search) &&
                    conv.createTime >= startDate && conv.createTime <= endDate
                }
            )
            return (try? context.fetch(desc)) ?? []
        } else {
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == wantDeleted && conv.title.localizedStandardContains(search)
                }
            )
            return (try? context.fetch(desc)) ?? []
        }
    }

    // MARK: - Preview Builder

    /// Extract ~80 chars around the first occurrence of keyword
    static func buildPreview(_ text: String, keyword: String) -> String {
        let lower = text.lowercased()
        let keyLower = keyword.lowercased()
        guard let range = lower.range(of: keyLower) else {
            return String(text.prefix(80))
        }

        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let contextStart = max(0, matchStart - 30)
        let startIndex = text.index(text.startIndex, offsetBy: contextStart)
        let endIndex = text.index(startIndex, offsetBy: min(80, text.distance(from: startIndex, to: text.endIndex)))

        var preview = String(text[startIndex..<endIndex])
            .replacingOccurrences(of: "\n", with: " ")
        if contextStart > 0 { preview = "..." + preview }
        if endIndex < text.endIndex { preview = preview + "..." }
        return preview
    }

    // MARK: - Sticker Search

    /// 搜索贴纸库（按 name + tags）
    static func searchStickers(keyword: String, profileId: String, container: ModelContainer) async -> [StickerAsset] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                context.autosaveEnabled = false

                let search = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !search.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                let pid = profileId
                let desc = FetchDescriptor<StickerAsset>(
                    predicate: #Predicate<StickerAsset> { asset in
                        asset.profileId == pid &&
                        asset.name.localizedStandardContains(search)
                    },
                    sortBy: [SortDescriptor(\StickerAsset.createdAt, order: .reverse)]
                )
                let nameMatches = (try? context.fetch(desc)) ?? []

                // 也搜 tags（SwiftData 不支持 array contains predicate，所以全量过滤）
                let allDesc = FetchDescriptor<StickerAsset>(
                    predicate: #Predicate<StickerAsset> { asset in asset.profileId == pid }
                )
                let allAssets = (try? context.fetch(allDesc)) ?? []
                let tagMatches = allAssets.filter { asset in
                    asset.tags.contains(where: { $0.localizedStandardContains(search) })
                }

                // 合并去重
                var seen = Set<UUID>()
                var results: [StickerAsset] = []
                for asset in nameMatches + tagMatches {
                    if seen.insert(asset.id).inserted {
                        results.append(asset)
                    }
                }

                continuation.resume(returning: results)
            }
        }
    }

    /// 搜索画布上的贴纸（左栏用）——按贴纸名 + 便签内容搜索，返回带对话信息的结果
    static func searchPlacedStickers(keyword: String, profileId: String, container: ModelContainer) async -> [StickerSearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let search = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !search.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let pid = profileId

                // 1. 搜 asset name 匹配的
                let assetDesc = FetchDescriptor<StickerAsset>(
                    predicate: #Predicate<StickerAsset> { a in
                        a.profileId == pid && a.name.localizedStandardContains(search)
                    }
                )
                let matchedAssets = (try? context.fetch(assetDesc)) ?? []
                let matchedAssetIds = Set(matchedAssets.map(\.id))

                // 2. 查所有 PlacedSticker
                let placedDesc = FetchDescriptor<PlacedSticker>(
                    predicate: #Predicate<PlacedSticker> { s in s.profileId == pid }
                )
                let allPlaced = (try? context.fetch(placedDesc)) ?? []

                // 3. 过滤：asset name 匹配 or noteContent 匹配
                let matched = allPlaced.filter { s in
                    if let assetId = s.stickerAssetId, matchedAssetIds.contains(assetId) { return true }
                    if let content = s.noteContent, content.localizedStandardContains(search) { return true }
                    return false
                }

                // 4. 关联对话标题
                let convIds = Set(matched.map(\.conversationId))
                let convDesc = FetchDescriptor<Conversation>(
                    predicate: #Predicate<Conversation> { c in c.profileId == pid && c.isTrashed == false }
                )
                let allConvs = (try? context.fetch(convDesc)) ?? []
                let convMap = Dictionary(uniqueKeysWithValues: allConvs.filter { convIds.contains($0.id) }.map { ($0.id, $0) })

                // 5. 构建结果
                let assetMap = Dictionary(uniqueKeysWithValues: matchedAssets.map { ($0.id, $0) })
                // 也查非名字匹配的 asset（便签内容匹配的可能没在 matchedAssets 里）
                let allAssetDesc = FetchDescriptor<StickerAsset>(
                    predicate: #Predicate<StickerAsset> { a in a.profileId == pid }
                )
                let allAssets = (try? context.fetch(allAssetDesc)) ?? []
                let fullAssetMap = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.id, $0) })

                var results: [StickerSearchResult] = []
                for s in matched {
                    let asset = s.stickerAssetId.flatMap { fullAssetMap[$0] }
                    let conv = convMap[s.conversationId]
                    results.append(StickerSearchResult(
                        placedStickerId: s.id,
                        assetName: asset?.name ?? (s.noteContent.map { String($0.prefix(20)) } ?? "贴纸"),
                        isNote: s.isNote,
                        thumbnailPath: asset?.thumbnailPath,
                        noteContent: s.noteContent,
                        noteStyle: s.noteStyle,
                        conversationId: s.conversationId,
                        conversationTitle: conv?.title ?? "未知对话",
                        nearestMessageId: s.nearestMessageId,
                        profileId: pid
                    ))
                }

                continuation.resume(returning: results)
            }
        }
    }

    /// 查找某个消息附近的贴纸（通过 nearestMessageId）
    static func findStickersNearMessage(messageId: String, profileId: String, container: ModelContainer) -> [PlacedSticker] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let mid = messageId
        let pid = profileId
        let desc = FetchDescriptor<PlacedSticker>(
            predicate: #Predicate<PlacedSticker> { s in
                s.nearestMessageId == mid && s.profileId == pid
            }
        )
        return (try? context.fetch(desc)) ?? []
    }

    // MARK: - Character Card Search

    /// 搜索角色卡。caller 在 MainActor 端取 manager.cards 的 snapshot 传入（避免跨 actor）
    static func searchCharacterCards(
        keyword: String,
        cards: [CharacterCard],
        filter: SearchFilter
    ) -> [CharacterCardSearchResult] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let interval = filter.dateRange.dateInterval

        var results: [CharacterCardSearchResult] = []
        for card in cards {
            if let interval = interval {
                if card.createdAt < interval.start || card.createdAt > interval.end { continue }
            }
            // 优先级从高到低
            let fields: [(String, String)] = [
                ("名字", card.name),
                ("简介", card.description),
                ("补充设定", card.personality),
                ("背景设定", card.scenario),
                ("开场", card.firstMes),
                ("对话示例", card.mesExample),
                ("System prompt", card.systemPrompt),
                ("Post-history", card.postHistoryInstructions),
                ("创作者备注", card.creatorNotes),
            ]
            var matchedField: String? = nil
            var preview = ""
            for (fname, fvalue) in fields where fvalue.localizedStandardContains(kw) {
                matchedField = fname
                preview = buildPreview(fvalue, keyword: kw)
                break
            }
            if matchedField == nil {
                for greeting in card.alternateGreetings where greeting.localizedStandardContains(kw) {
                    matchedField = "开场"
                    preview = buildPreview(greeting, keyword: kw)
                    break
                }
            }
            guard let field = matchedField else { continue }
            results.append(CharacterCardSearchResult(
                id: card.id,
                cardId: card.id,
                cardName: card.name,
                imageData: card.imageData,
                createdAt: card.createdAt,
                matchedField: field,
                preview: preview,
                keyword: kw
            ))
        }

        switch filter.sortOrder {
        case .recent: results.sort { $0.createdAt > $1.createdAt }
        case .oldest: results.sort { $0.createdAt < $1.createdAt }
        case .titleAZ: results.sort { $0.cardName.localizedCompare($1.cardName) == .orderedAscending }
        case .titleZA: results.sort { $0.cardName.localizedCompare($1.cardName) == .orderedDescending }
        }
        return results
    }

    // MARK: - World Book Search

    /// 搜索世界书条目：楼层 WorldBook（SwiftData） + 全局世界书（内存 snapshot）
    static func searchWorldBookEntries(
        keyword: String,
        globalBooks: [GlobalWorldBook],
        profileId: String,
        container: ModelContainer,
        filter: SearchFilter
    ) async -> [WorldBookEntrySearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kw.isEmpty else { continuation.resume(returning: []); return }
                let interval = filter.dateRange.dateInterval

                var results: [WorldBookEntrySearchResult] = []

                // --- 1. 全局世界书（内存 snapshot） ---
                for book in globalBooks {
                    let bookNameMatch = book.name.localizedStandardContains(kw)
                    for entry in book.entries {
                        if let hit = matchWorldBookEntry(entry, keyword: kw, bookNameMatch: bookNameMatch, bookName: book.name) {
                            results.append(WorldBookEntrySearchResult(
                                id: "global:\(book.id):\(entry.id)",
                                isGlobal: true,
                                bookId: book.id,
                                bookName: book.name,
                                entryId: entry.id,
                                entryTitle: entryDisplayTitle(entry),
                                createdAt: book.updatedAt,
                                matchedField: hit.field,
                                preview: hit.preview,
                                keyword: kw
                            ))
                        }
                    }
                }

                // --- 2. 楼层 WorldBook（SwiftData） ---
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let pid = profileId
                let wbDesc = FetchDescriptor<WorldBook>(
                    predicate: #Predicate<WorldBook> { wb in wb.profileId == pid }
                )
                let books = (try? context.fetch(wbDesc)) ?? []
                for book in books {
                    let bookNameMatch = book.name.localizedStandardContains(kw)
                    for entry in book.entries {
                        if let hit = matchWorldBookEntry(entry, keyword: kw, bookNameMatch: bookNameMatch, bookName: book.name) {
                            results.append(WorldBookEntrySearchResult(
                                id: "floor:\(book.id.uuidString):\(entry.id)",
                                isGlobal: false,
                                bookId: book.id.uuidString,
                                bookName: book.name,
                                entryId: entry.id,
                                entryTitle: entryDisplayTitle(entry),
                                createdAt: book.updatedAt,
                                matchedField: hit.field,
                                preview: hit.preview,
                                keyword: kw
                            ))
                        }
                    }
                }

                // --- 时间过滤 ---
                if let interval = interval {
                    results = results.filter { $0.createdAt >= interval.start && $0.createdAt <= interval.end }
                }

                // --- 排序 ---
                switch filter.sortOrder {
                case .recent: results.sort { $0.createdAt > $1.createdAt }
                case .oldest: results.sort { $0.createdAt < $1.createdAt }
                case .titleAZ: results.sort { $0.entryTitle.localizedCompare($1.entryTitle) == .orderedAscending }
                case .titleZA: results.sort { $0.entryTitle.localizedCompare($1.entryTitle) == .orderedDescending }
                }
                continuation.resume(returning: results)
            }
        }
    }

    private static func matchWorldBookEntry(_ entry: WorldBookEntry, keyword: String, bookNameMatch: Bool, bookName: String) -> (field: String, preview: String)? {
        // 优先级：comment > content > keys > secondaryKeys > bookName
        if entry.comment.localizedStandardContains(keyword) {
            return ("备注", buildPreview(entry.comment, keyword: keyword))
        }
        if entry.content.localizedStandardContains(keyword) {
            return ("内容", buildPreview(entry.content, keyword: keyword))
        }
        if let hit = entry.keys.first(where: { $0.localizedStandardContains(keyword) }) {
            return ("关键词", hit)
        }
        if let hit = entry.secondaryKeys.first(where: { $0.localizedStandardContains(keyword) }) {
            return ("次关键词", hit)
        }
        if bookNameMatch {
            return ("书名", buildPreview(bookName, keyword: keyword))
        }
        return nil
    }

    private static func entryDisplayTitle(_ entry: WorldBookEntry) -> String {
        if !entry.comment.isEmpty { return entry.comment }
        if let first = entry.keys.first { return first }
        return String(entry.content.prefix(20))
    }

    // MARK: - Memory Search

    /// 搜索记忆（Memory），按 profileId 楼层隔离。MemoryNote 目前无 UI 展示，暂不搜。
    static func searchMemories(
        keyword: String,
        profileId: String,
        container: ModelContainer,
        filter: SearchFilter
    ) async -> [MemorySearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kw.isEmpty else { continuation.resume(returning: []); return }
                let interval = filter.dateRange.dateInterval

                let context = ModelContext(container)
                context.autosaveEnabled = false
                let pid = profileId
                let search = kw

                let desc = FetchDescriptor<Memory>(
                    predicate: #Predicate<Memory> { mem in
                        mem.profileId == pid && mem.content.localizedStandardContains(search)
                    }
                )
                var memories = (try? context.fetch(desc)) ?? []

                // keywords 数组 predicate 不好写，内存二次过滤（只补漏，content 已 match 的跳过）
                // 这里先只按 content 匹。若 keywords 需要，再加一个 fetch 所有 memories + filter。
                // 保守：先把 keywords 匹的也加入 — 需要取所有 profile 下 memory，量不大
                let allDesc = FetchDescriptor<Memory>(
                    predicate: #Predicate<Memory> { mem in mem.profileId == pid }
                )
                let all = (try? context.fetch(allDesc)) ?? []
                let existing = Set(memories.map { $0.id })
                for mem in all where !existing.contains(mem.id) {
                    if mem.keywords.contains(where: { $0.localizedStandardContains(search) }) {
                        memories.append(mem)
                    }
                }

                // 时间过滤
                if let interval = interval {
                    memories = memories.filter { $0.createdAt >= interval.start && $0.createdAt <= interval.end }
                }

                var results = memories.map { mem -> MemorySearchResult in
                    let previewSource = mem.content.localizedStandardContains(kw) ? mem.content : mem.keywords.joined(separator: " ")
                    return MemorySearchResult(
                        id: mem.id.uuidString,
                        memoryId: mem.id,
                        category: mem.category,
                        preview: buildPreview(previewSource, keyword: kw),
                        createdAt: mem.createdAt,
                        keyword: kw
                    )
                }

                switch filter.sortOrder {
                case .recent: results.sort { $0.createdAt > $1.createdAt }
                case .oldest: results.sort { $0.createdAt < $1.createdAt }
                case .titleAZ: results.sort { $0.preview.localizedCompare($1.preview) == .orderedAscending }
                case .titleZA: results.sort { $0.preview.localizedCompare($1.preview) == .orderedDescending }
                }
                continuation.resume(returning: results)
            }
        }
    }
}

// MARK: - Resource Search Result Structs

struct CharacterCardSearchResult: Identifiable {
    let id: String
    let cardId: String
    let cardName: String
    let imageData: Data?
    let createdAt: Date
    let matchedField: String
    let preview: String
    let keyword: String
}

struct WorldBookEntrySearchResult: Identifiable {
    let id: String
    let isGlobal: Bool
    let bookId: String         // global UUID string 或 floor UUID string
    let bookName: String
    let entryId: UUID
    let entryTitle: String
    let createdAt: Date
    let matchedField: String
    let preview: String
    let keyword: String
}

struct MemorySearchResult: Identifiable {
    let id: String
    let memoryId: UUID
    let category: String
    let preview: String
    let createdAt: Date
    let keyword: String
}

// MARK: - Sticker Search Result

struct StickerSearchResult: Identifiable {
    let id: UUID
    let assetName: String
    let isNote: Bool
    let thumbnailPath: String?
    let noteContent: String?
    let noteStyle: String?
    let conversationId: String
    let conversationTitle: String
    let nearestMessageId: String?
    let profileId: String

    init(placedStickerId: UUID, assetName: String, isNote: Bool, thumbnailPath: String?,
         noteContent: String?, noteStyle: String?, conversationId: String,
         conversationTitle: String, nearestMessageId: String?, profileId: String) {
        self.id = placedStickerId
        self.assetName = assetName
        self.isNote = isNote
        self.thumbnailPath = thumbnailPath
        self.noteContent = noteContent
        self.noteStyle = noteStyle
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.nearestMessageId = nearestMessageId
        self.profileId = profileId
    }
}
