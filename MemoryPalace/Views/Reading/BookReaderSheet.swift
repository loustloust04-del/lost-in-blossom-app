import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 全屏阅读 sheet（fullScreenCover / macOS .sheet）。MVP：
/// - 顶部 toolbar：关闭 / 书名+章节 / 目录按钮
/// - 中部：BookReaderWebView 渲染当前章节
/// - 底部：上一章 / 进度 / 下一章
/// - 章节目录抽屉（侧滑）
/// - 阅读进度自动保存（scroll debounce 1s 写 index.json + BookEntry）
///
/// M3 会在这里加：选段菜单（复制/高亮/加笔记/问小克）+ 底部抽屉 mini 对话
struct BookReaderSheet: View {
    let bookSafeName: String
    let profileId: String
    /// CR-3：生词出处 chip 跳回用——指定则覆盖存储的阅读进度章节。
    var initialChapter: Int? = nil
    /// 章节内字符 offset（sourceBookRef 第三段），按字符比例近似滚动定位。
    var initialAnchorOffset: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // M3-B：问 AI → 楼层主对话需要的依赖
    // 见 PDFReaderSheet：Page 2 阅读器面板没注入 ConversationViewModel，非 optional 会崩。
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @AppStorage("assistantName") private var assistantName = "助手"

    // M3-B：问完后的反馈 toast
    @State private var askToast: String? = nil

    // M3-B-2：底部抽屉 mini 对话（学 page1 ModelPickerPopover 的 .sheet+presentationDetents）
    @State private var showChatDrawer = false

    // M3.5：点击 AI 划线后高亮抽屉里对应的消息（通过 note.messageId 关联到 user node）
    @State private var highlightedNoteId: String? = nil

    @State private var index: BookStore.BookIndex?
    @State private var currentChapter: Int = 1
    /// loadBook 把 currentChapter 从默认 1 改到续读章 N 会触发 onChange。
    /// 这个标记吞掉那一次 resetScroll，避免用 0 覆盖存档的阅读进度。
    @State private var suppressChapterReset = false
    @State private var chapterText: String = ""
    // 实时陪读（弹幕）：她停稳 1.8s → Caelum 掉一句短评浮在页面上
    @State private var liveComment: String?
    @State private var liveOn: Bool = LiveReadingService.isEnabled
    @State private var showCompanionSheet = false
    @State private var liveCommentAt: Date = .distantPast
    @State private var initialScrollRatio: Double? = nil
    @State private var latestScrollRatio: Double = 0
    @State private var renderedHTML: String = ""
    @State private var loadError: String?

    /// 左侧抽屉互斥（目录 / 批注 只能开一个）
    enum ActiveDrawer { case catalog, annotations }
    @State private var activeDrawer: ActiveDrawer? = nil

    // F1-F3 阅读器体感包
    @AppStorage("readerFontSize") private var readerFontSize = ChapterHTMLRenderer.FontSize.md.rawValue
    @State private var bookmarks: [BookStore.Bookmark] = []
    @State private var bookmarkJumpRatio: Double? = nil
    @State private var catalogQuery = ""
    @State private var searchHits: [BookSearch.Hit] = []
    @State private var searchTask: Task<Void, Never>? = nil

    /// 进度持久化 debounce
    @State private var saveTask: Task<Void, Never>? = nil

    // M3：当前章节的所有笔记（含高亮/笔记/AI 批注 anchor），用于渲染时着色
    @State private var chapterNotes: [BookStore.Note] = []

    // 批注抽屉用：全书所有 notes（含其他章）
    @State private var allNotes: [BookStore.Note] = []

    // CR-1 失锚集合（打开批注抽屉时检测，卡片标「原文已变」）
    @State private var brokenNoteIds: Set<String> = []

    // R4 就地小窗：点正文划线命中的批注 id（非空 = 弹小窗）
    @State private var quickLookNoteIds: [String]? = nil

    // 从批注抽屉跳主对话用——绕过 highlightedNoteId 那条 noteId 路径，直接给 MessageNode.id
    @State private var directHighlightMessageId: String? = nil

    // M3：选段状态——JS 报上来后弹菜单/笔记/问小克
    @State private var selectedRange: SelectedRange?
    @State private var showNoteEditor = false
    @State private var noteEditorContent = ""
    /// 非空 = 编辑模式（改已有 note），空 = 新增模式（从选段加 note）
    @State private var editingNoteId: String? = nil

    struct SelectedRange: Equatable {
        let text: String
        let start: Int
        let end: Int
        let chapter: Int
    }

    var body: some View {
        Group {
            if let err = loadError {
                errorView(err)
            } else if index == nil {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                readerBody
            }
        }
        .overlay(alignment: .bottom) { liveCommentBubble }
        .onReceive(NotificationCenter.default.publisher(for: .bookNoteArrived)) { note in
            // 他递了新批注 → 重载本章批注，让她当场看到
            guard let sn = note.userInfo?["safeName"] as? String, sn == bookSafeName else { return }
            let all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
            allNotes = all
            chapterNotes = all.filter { $0.chapter == currentChapter }
        }
        .sheet(isPresented: $showCompanionSheet) {
            ReadingCompanionSheet(
                bookEntry: bookEntryForCompanion,
                bookName: index?.name ?? bookSafeName,
                currentChapter: currentChapter,
                todayNotes: todayNotesDigest,
                onFinishToday: {
                    if !hasBookmarkHere { toggleBookmarkHere() }
                    saveProgressNow()
                },
                onClose: { showCompanionSheet = false; liveOn = LiveReadingService.isEnabled }
            )
        }
        .onAppear {
            loadBook()
            // 弹幕：收到短评就浮出来，8 秒后自己淡走（不打断阅读、不需要点掉）
            LiveReadingService.shared.onComment = { text in
                withAnimation(.easeOut(duration: 0.28)) {
                    liveComment = text
                    liveCommentAt = Date()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    if Date().timeIntervalSince(liveCommentAt) >= 7.9 {
                        withAnimation(.easeIn(duration: 0.4)) { liveComment = nil }
                    }
                }
            }
        }
        .onDisappear {
            LiveReadingService.shared.stop()
            LiveReadingService.shared.onComment = nil
        }
        .onChange(of: currentChapter) { _, newValue in
            if suppressChapterReset {
                suppressChapterReset = false
                return  // 续读首帧：loadBook 已用存档的 scroll 加载本章，别 reset
            }
            loadChapter(newValue, resetScroll: true)
        }
        // CR-2 阅读打点：sheet 活着 = 在读，60s 一跳（iOS 切后台 Task 挂起，天然不计后台）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, index != nil else { continue }
                ReadingSignals.logTick(
                    bookSafeName: bookSafeName,
                    bookDisplayName: index?.name ?? bookSafeName,
                    chapter: currentChapter,
                    profileId: profileId
                )
            }
        }
        // R4 批注就地小窗
        .sheet(isPresented: Binding(
            get: { quickLookNoteIds != nil },
            set: { if !$0 { quickLookNoteIds = nil } }
        )) {
            NoteQuickLookSheet(
                noteIds: quickLookNoteIds ?? [],
                allNotes: allNotes,
                assistantName: assistantName,
                onReply: { parent, content in
                    let reply = BookStore.Note(
                        id: UUID().uuidString, chapter: parent.chapter,
                        anchorText: parent.anchorText, anchorStart: parent.anchorStart,
                        anchorEnd: parent.anchorEnd, kind: "note", content: content,
                        role: "user", messageId: nil, createdAt: Date(), replyTo: parent.id
                    )
                    appendNote(reply)
                    ReadingSignals.logEvent(type: "reply", book: bookSafeName, chapter: parent.chapter, profileId: profileId)
                },
                onDelete: { note in deleteNote(note) },
                onShowChat: { messageId in
                    directHighlightMessageId = messageId
                    highlightedNoteId = nil
                    showChatDrawer = true
                }
            )
        }
        // CR-1：aiBubble 回填后即时刷新（占位卡→真回答，抽屉和正文虚线都更新）
        .onReceive(NotificationCenter.default.publisher(for: .bookNotesDidChange)) { notif in
            guard (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
            let all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
            allNotes = all
            chapterNotes = all.filter { $0.chapter == currentChapter }
            rerenderCurrentChapter()
        }
    }

    // MARK: - 主体

    private var readerBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BookReaderWebView(
                    html: renderedHTML,
                    chapterNo: currentChapter,
                    initialScrollRatio: initialScrollRatio,
                    assistantName: assistantName,
                    onMessage: handleMessage
                )
                Divider()
                bottomBar
            }
            .background(Theme.mainBg)
            .navigationTitle(index?.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // 用 toolbar(content:) 具名形式：裸 { readerToolbar } 时
            // ViewBuilder / ToolbarContentBuilder 两个重载都能匹配一个 opaque 属性，
            // Swift 报 ambiguous（e10832f7 拆出属性后仍在，2026-08-31 补这一步）。
            .toolbar(content: { readerToolbar })
        }
        .overlay(alignment: .leading) {
            switch activeDrawer {
            case .catalog:
                catalogDrawer.transition(.move(edge: .leading))
            case .annotations:
                annotationsDrawer.transition(.move(edge: .leading))
            case .none:
                EmptyView()
            }
        }
        // M3-B：问小克后的反馈 toast（2.5s 自动消失）
        .overlay(alignment: .bottom) {
            if let msg = askToast {
                Text(msg)
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.branchIndicator.opacity(0.9))
                    .clipShape(Capsule())
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: askToast)
        // 选段菜单：
        // - iOS 走 WKWebView 原生 edit menu（MPReaderWebView 替换系统条目，贴选段浮条不挡正文）
        // - macOS 没有原生浮条概念，维持 confirmationDialog
        #if os(macOS)
        .confirmationDialog(
            "对这段做什么？",
            isPresented: Binding(
                get: { selectedRange != nil },
                set: { if !$0 { selectedRange = nil } }
            ),
            titleVisibility: .visible,
            presenting: selectedRange
        ) { range in
            Button("复制") { copySelection(range.text) }
            Button("高亮") { addHighlight(range) }
            Button("加笔记") { noteEditorContent = ""; showNoteEditor = true }
            Button("问\(assistantName)") { askXiaoke(range) }
            Button("收生词") { addToVocab(range) }
            Button("取消", role: .cancel) { selectedRange = nil }
        } message: { range in
            Text("「\(range.text.prefix(40))\(range.text.count > 40 ? "…" : "")」")
        }
        #endif
        // 笔记输入 sheet
        .sheet(isPresented: $showNoteEditor) {
            noteEditorSheet
        }
        // M3-B-2 底部抽屉 mini 对话（学 page1 ModelPickerPopover 的 .sheet + detents 模式）
        .sheet(isPresented: $showChatDrawer, onDismiss: {
            highlightedNoteId = nil
            directHighlightMessageId = nil
        }) {
            // 真凶（连环 ambiguous 的源头）：本视图的 viewModel 是 Optional
            // （@Environment(ConversationViewModel.self) var viewModel: ConversationViewModel?），
            // BookChatDrawer 的 @Bindable 要非可选。类型错发生在这个 sheet builder 里，
            // Swift 却把诊断劣化成 toolbar 那句 ambiguous——红鲱鱼追了三刀。
            if let vm = viewModel {
                BookChatDrawer(
                    bookSafeName: bookSafeName,
                    bookDisplayName: index?.name ?? bookSafeName,
                    currentChapter: currentChapter,
                    viewModel: vm,
                    highlightMessageId: directHighlightMessageId ?? messageIdForHighlightedNote()
                )
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
        }
    }

    // MARK: - 笔记输入 sheet

    private var noteEditorSheet: some View {
        NavigationStack {
            List {
                if let r = selectedRange {
                    Section("选段") {
                        Text("「\(r.text.prefix(120))\(r.text.count > 120 ? "…" : "")」")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.mainBg)
                }
                Section("笔记") {
                    TextEditor(text: $noteEditorContent)
                        .font(.system(size: Theme.F.body))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(Theme.mainBg)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(editingNoteId == nil ? "加笔记" : "改笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showNoteEditor = false
                        selectedRange = nil
                        editingNoteId = nil
                    }
                    .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveNote() }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(noteEditorContent.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 360)
        #endif
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { jumpChapter(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 14))
                Text("上一章").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(currentChapter > 1 ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
            .disabled(currentChapter <= 1)

            Spacer()

            if let total = index?.totalChapters, total > 0 {
                Text(progressLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
            }

            // M3-B-2：抽屉入口按钮（带消息数 badge）
            Button { showChatDrawer = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 14))
                    if bookMessageCount > 0 {
                        Text("\(bookMessageCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.branchIndicator)
                            .clipShape(Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.textSecondary)

            Spacer()

            Button { jumpChapter(1) } label: {
                Text("下一章").font(.system(size: 12))
                Image(systemName: "chevron.right").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundColor(currentChapter < (index?.totalChapters ?? 0) ? Theme.textPrimary : Theme.textMuted.opacity(0.4))
            .disabled(currentChapter >= (index?.totalChapters ?? 0))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 当前书在主对话里出现过多少条相关 user 消息（用来在按钮上做 badge）
    private var bookMessageCount: Int {
        let prefix = "\(bookSafeName)#"
        return (viewModel?.currentPath ?? []).filter { $0.bookRef?.hasPrefix(prefix) == true }.count
    }

    /// M3.5：把点击的 ai-ul noteId 映射到对应主对话 MessageNode.id
    private func messageIdForHighlightedNote() -> String? {
        guard let noteId = highlightedNoteId else { return nil }
        let allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        return allNotes.first(where: { $0.id == noteId })?.messageId
    }

    /// 弹幕气泡：贴底浮一条，半透明不挡字，点一下收掉
    @ViewBuilder
    private var liveCommentBubble: some View {
        if let c = liveComment {
            Text(c)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.sidebarBg.opacity(0.94))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(ConsoleView.green.opacity(0.28), lineWidth: 0.8)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { liveComment = nil } }
        }
    }

    private var progressLabel: String {
        let total = index?.totalChapters ?? 0
        guard total > 0 else { return "" }
        let pct = (Double(currentChapter - 1) + latestScrollRatio) / Double(total) * 100
        return String(format: "%.1f%%", pct)
    }

    // MARK: - 目录抽屉

    private var catalogDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("目录").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textMuted)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            // F2 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                TextField("搜全书", text: $catalogQuery)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                if !catalogQuery.isEmpty {
                    Button { catalogQuery = ""; searchHits = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .onChange(of: catalogQuery) { _, q in scheduleSearch(q) }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !catalogQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResultRows
                    } else {
                        bookmarkRows
                        chapterRows
                    }
                }
            }
            Divider()
            fontSizeControl   // F3
        }
        .frame(width: 240)
        .background(Theme.sidebarBg)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 2, y: 0)
        .onAppear { bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId) }
    }

    /// 目录抽屉：章节列表（无搜索词时）
    private var chapterRows: some View {
        ForEach(index?.chapters ?? []) { ch in
            Button {
                currentChapter = ch.no
                withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            } label: {
                HStack(spacing: 6) {
                    Text("\(ch.no).")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .frame(width: 28, alignment: .trailing)
                    Text(ch.title)
                        .font(.system(size: 12))
                        .foregroundColor(ch.no == currentChapter ? Theme.branchIndicator : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(ch.no == currentChapter ? Theme.accent : Color.clear)
            }
            .buttonStyle(.plain)
        }
    }

    /// F1 书签行（章节列表上方，有书签才出现）
    @ViewBuilder private var bookmarkRows: some View {
        if !bookmarks.isEmpty {
            HStack {
                Text("Bookmarks")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(bookmarks) { bm in
                HStack(spacing: 6) {
                    Button {
                        jumpToBookmark(bm)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.branchIndicator)
                            Text(bm.title)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        removeBookmark(bm)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider().padding(.vertical, 4)
        }
    }

    /// F2 搜索结果行
    @ViewBuilder private var searchResultRows: some View {
        if searchHits.isEmpty {
            Text("没搜到")
                .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                .padding(12)
        } else {
            ForEach(searchHits) { hit in
                Button {
                    currentChapter = hit.chapter
                    withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.branchIndicator)
                            .lineLimit(1)
                        Text(hit.snippet)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// F3 字号控件（Aa，六档步进）
    private var fontSizeControl: some View {
        let sizes = ChapterHTMLRenderer.FontSize.allCases
        let idx = sizes.firstIndex(of: ChapterHTMLRenderer.FontSize(rawValue: readerFontSize) ?? .md) ?? 2
        return HStack {
            Button {
                if idx > 0 { readerFontSize = sizes[idx - 1].rawValue; rerenderCurrentChapter() }
            } label: {
                Text("A").font(.system(size: 11)).foregroundColor(idx > 0 ? Theme.textSecondary : Theme.textMuted.opacity(0.4))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("字号 · \(sizes[idx].label)")
                .font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
            Spacer()
            Button {
                if idx < sizes.count - 1 { readerFontSize = sizes[idx + 1].rawValue; rerenderCurrentChapter() }
            } label: {
                Text("A").font(.system(size: 16)).foregroundColor(idx < sizes.count - 1 ? Theme.textSecondary : Theme.textMuted.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - F1/F2 动作

    private func jumpToBookmark(_ bm: BookStore.Bookmark) {
        withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
        if bm.chapter == currentChapter {
            bookmarkJumpRatio = bm.scrollRatio
            loadChapter(currentChapter, resetScroll: true)
        } else {
            bookmarkJumpRatio = bm.scrollRatio
            currentChapter = bm.chapter   // onChange → loadChapter(resetScroll: true) 会消费 jumpRatio
        }
    }

    private func removeBookmark(_ bm: BookStore.Bookmark) {
        var bms = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        bms.removeAll { $0.id == bm.id }
        try? BookStore.saveBookmarks(bms, safeName: bookSafeName, profileId: profileId)
        bookmarks = bms
    }

    private func toggleBookmarkHere() {
        let title = index?.chapters.first(where: { $0.no == currentChapter })?.title ?? "第 \(currentChapter) 章"
        let added = BookStore.toggleBookmark(
            safeName: bookSafeName, profileId: profileId,
            chapter: currentChapter, scrollRatio: latestScrollRatio, title: title)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        askToast = added ? "已加书签" : "书签已取消"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if askToast != nil { askToast = nil } }
    }

    private var hasBookmarkHere: Bool {
        bookmarks.contains { $0.chapter == currentChapter }
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchHits = []; return }
        let chapters = index?.chapters ?? []
        let safe = bookSafeName, pid = profileId
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                BookSearch.searchTxt(query: q, safeName: safe, profileId: pid, chapters: chapters)
            }.value
            guard !Task.isCancelled else { return }
            searchHits = result.hits
        }
    }

    // MARK: - 批注抽屉

    private var annotationsDrawer: some View {
        BookAnnotationDrawer(
            allNotes: allNotes,
            chapters: index?.chapters ?? [],
            assistantName: assistantName,
            currentChapter: currentChapter,
            brokenNoteIds: brokenNoteIds,
            isPresented: Binding(
                get: { activeDrawer == .annotations },
                set: { if !$0 { activeDrawer = nil } }
            ),
            onTapNote: { note in
                handleTapNote(note)
            },
            onJumpToChapter: { chapter in
                withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                if chapter != currentChapter { currentChapter = chapter }
            },
            onShowChat: { messageId in
                withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
                directHighlightMessageId = messageId
                highlightedNoteId = nil
                showChatDrawer = true
            },
            onDelete: { note in
                deleteNote(note)
            },
            onReply: { parent, content in
                let reply = BookStore.Note(
                    id: UUID().uuidString,
                    chapter: parent.chapter,
                    anchorText: parent.anchorText,
                    anchorStart: parent.anchorStart,
                    anchorEnd: parent.anchorEnd,
                    kind: "note",
                    content: content,
                    role: "user",
                    messageId: nil,
                    createdAt: Date(),
                    replyTo: parent.id
                )
                appendNote(reply)
                ReadingSignals.logEvent(type: "reply", book: bookSafeName, chapter: parent.chapter, profileId: profileId)
            }
        )
    }

    /// 卡片点击派发：
    /// - note      → 编辑（弹 noteEditor 预填）
    /// - highlight → 升级成笔记（弹 noteEditor 空 content）
    /// - aiBubble  → 跳章（AI 内容不能改）
    private func handleTapNote(_ note: BookStore.Note) {
        switch note.kind {
        case "note", "highlight":
            selectedRange = SelectedRange(
                text: note.anchorText,
                start: note.anchorStart,
                end: note.anchorEnd,
                chapter: note.chapter
            )
            noteEditorContent = note.content
            editingNoteId = note.id
            withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            showNoteEditor = true
        case "aiBubble":
            withAnimation(.spring(response: 0.3)) { activeDrawer = nil }
            if note.chapter != currentChapter { currentChapter = note.chapter }
        default:
            break
        }
    }

    // MARK: - 错误态

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.textMuted)
            Text(msg).font(.system(size: 13)).foregroundColor(Theme.textSecondary)
            Button("关闭") { dismiss() }.buttonStyle(.plain).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 业务

    private func loadBook() {
        guard let idx = BookStore.loadIndex(safeName: bookSafeName, profileId: profileId) else {
            loadError = "找不到《\(bookSafeName)》"
            return
        }
        index = idx
        let targetChapter = max(1, min(idx.totalChapters, initialChapter ?? idx.currentChapter))
        // 只有真的跳章（默认 1 → N）才会触发 onChange，这时才需要吞掉那次 reset
        if targetChapter != currentChapter { suppressChapterReset = true }
        currentChapter = targetChapter
        initialScrollRatio = idx.scrollRatio
        allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        loadChapter(currentChapter, resetScroll: false)
        if initialChapter != nil {
            // 存储的 scrollRatio 属于原进度章节，跳章后按 offset 字符比例近似定位
            let ratio = initialAnchorOffset.map { Double($0) / Double(max(1, chapterText.count)) } ?? 0
            let clamped = min(1, max(0, ratio))
            initialScrollRatio = clamped
            latestScrollRatio = clamped
        }
    }

    private func loadChapter(_ no: Int, resetScroll: Bool) {
        guard let idx = index,
              let meta = idx.chapters.first(where: { $0.no == no }) else { return }
        guard let text = BookStore.loadChapterText(safeName: bookSafeName, chapterNo: no, profileId: profileId) else {
            loadError = "找不到第 \(no) 章文件"
            return
        }
        chapterText = text
        LivelineReporter.report(.reading, "兔兔在读《\(index?.name ?? bookSafeName)》第 \(no) 章")
        // 刷新整书 notes（如果用户在其他章节有过改动）+ 切出本章用于着色
        let all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        allNotes = all
        chapterNotes = all.filter { $0.chapter == no }
        renderedHTML = ChapterHTMLRenderer.render(
            title: meta.title,
            text: text,
            style: readerStyle,
            chapterNo: no,
            totalChapters: idx.totalChapters,
            annotations: chapterNotes.compactMap(annotationFromNote),
            vocabWords: VocabCollector.collectedWords(context: modelContext)
        )
        if resetScroll {
            let target = bookmarkJumpRatio ?? 0
            bookmarkJumpRatio = nil
            initialScrollRatio = target
            latestScrollRatio = target
            scheduleSaveProgress()
        }
        pushReadingContext(chapterNo: no, chapterTitle: meta.title, text: text)
    }

    /// F3 字号：全局档位（FontSize 枚举早已进 CSS，这里只是接上持久化）
    private var readerStyle: ChapterHTMLRenderer.Style {
        var s = ChapterHTMLRenderer.Style()
        s.fontSize = ChapterHTMLRenderer.FontSize(rawValue: readerFontSize) ?? .md
        return s
    }

    /// CR-4 P1：她读到哪，章文本经 WS 缓存到 hub 哪（agent/reading-context.json，单章覆盖）。
    /// AI 自主读书只读「她最近读的那一章」——她没读书 = hub 无材料 = ReaderDaemon 不跑。
    /// userNotes 附本章她的批注（供 AI 回她的话，⧫ 回批注已拍开）。best-effort，断连不重试。
    private func pushReadingContext(chapterNo: Int, chapterTitle: String, text: String) {
        let userNotes = chapterNotes.filter { $0.role == "user" }.map {
            [
                "id": $0.id,
                "anchorText": String($0.anchorText.prefix(120)),
                "content": String($0.content.prefix(200)),
            ]
        }
        // R1：楼层人格+记忆随材料上行（同刻快照），daemon 带着用户的 AI 的人格读书
        var persona = ""
        var userName = "用户"
        if let profile = profileManager?.currentProfile {
            persona = ReadingSignals.buildPersonaPackage(profile: profile, context: modelContext)
            if !profile.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                userName = profile.userName
            }
        }
        CCBridgeWebSocketClient.shared.send([
            "type": "reading_context",
            "floorId": profileId,
            "userName": userName,
            "safeName": bookSafeName,
            "bookName": index?.name ?? bookSafeName,
            "chapter": chapterNo,
            "totalChapters": index?.totalChapters ?? 0,
            "chapterTitle": chapterTitle,
            "text": String(text.prefix(60_000)),
            "userNotes": userNotes,
            "persona": persona,
        ]) { _ in }
    }

    /// 重绘当前章 HTML（保持 scroll 位置）——append/delete 笔记后复用
    private func rerenderCurrentChapter() {
        guard let idx = index,
              let meta = idx.chapters.first(where: { $0.no == currentChapter }) else { return }
        renderedHTML = ChapterHTMLRenderer.render(
            title: meta.title,
            text: chapterText,
            style: readerStyle,
            chapterNo: currentChapter,
            totalChapters: idx.totalChapters,
            annotations: chapterNotes.compactMap(annotationFromNote),
            vocabWords: VocabCollector.collectedWords(context: modelContext)
        )
        initialScrollRatio = latestScrollRatio  // 重渲染后回到当前位置
    }

    private func jumpChapter(_ delta: Int) {
        let target = currentChapter + delta
        guard let total = index?.totalChapters, target >= 1, target <= total else { return }
        currentChapter = target
    }

    private func handleMessage(_ msg: BookReaderMessage) {
        switch msg {
        case .ready: break
        case .scroll(let ratio, let chapter):
            guard chapter == currentChapter else { return }
            latestScrollRatio = ratio
            scheduleSaveProgress()
            // 弹幕：把当前视野那一段（按比例从章节正文里截）交给 LiveReadingService 防抖
            if LiveReadingService.isEnabled, !chapterText.isEmpty {
                let total = chapterText.count
                let center = Int(Double(total) * ratio)
                let lo = chapterText.index(chapterText.startIndex, offsetBy: max(0, center - 200))
                let hi = chapterText.index(chapterText.startIndex, offsetBy: min(total, center + 700))
                LiveReadingService.shared.scrolled(
                    bookName: index?.name ?? bookSafeName,
                    chapter: chapter,
                    visibleText: String(chapterText[lo..<hi]))
            }
        case .select(let text, let start, let end, let chapter):
            guard chapter == currentChapter, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            // iOS 走原生 edit menu，不弹 confirmationDialog——select 只在 macOS 触发卡片
            #if os(macOS)
            selectedRange = SelectedRange(text: text, start: start, end: end, chapter: chapter)
            #else
            _ = (text, start, end)   // 静默，等 .action 路径
            #endif
        case .action(let name, let text, let start, let end, let chapter):
            // iOS 原生菜单点击后回来：name=copy/highlight/addNote/askAI
            guard chapter == currentChapter, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let range = SelectedRange(text: text, start: start, end: end, chapter: chapter)
            switch name {
            case "copy":
                copySelection(text)
            case "highlight":
                addHighlight(range)
            case "addNote":
                selectedRange = range
                noteEditorContent = ""
                showNoteEditor = true
            case "askAI":
                askXiaoke(range)
            case "addVocab":
                addToVocab(range)
            default:
                break
            }
        case .noteTap(let noteIds, let chapter):
            // R4：点任何批注划线 → 就地小窗（批注内容/串/回复；aiBubble 从小窗再进对话抽屉）
            guard chapter == currentChapter, !noteIds.isEmpty else { return }
            let hit = allNotes.filter { noteIds.contains($0.id) }
            guard !hit.isEmpty else { return }
            quickLookNoteIds = noteIds
        case .vocabTap(let word, _):
            // CR-3：点击已收生词 → 打开单词工具定位到该词
            guard !word.isEmpty else { return }
            UserDefaults.standard.set(word, forKey: "pendingVocabJumpWord")
            NotificationCenter.default.post(name: .openVocabTool, object: nil)
            dismiss()
        case .error(let m):
            loadError = m
        }
    }

    // MARK: - 笔记/高亮写入

    private func copySelection(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        selectedRange = nil
    }

    /// CR-3：选段收进生词本（书词打通写入口）。收完 rerender 让虚线立现。
    private func addToVocab(_ range: SelectedRange) {
        let word = VocabCollector.collect(
            rawText: range.text,
            bookSafeName: bookSafeName,
            chapter: range.chapter,
            anchorStart: range.start,
            context: modelContext
        )
        selectedRange = nil
        guard let word else {
            askToast = "选段不适合收词"
            scheduleToastDismiss()
            return
        }
        rerenderCurrentChapter()
        askToast = "已收「\(word)」进生词本"
        scheduleToastDismiss()
        ReadingSignals.logEvent(type: "vocab", book: bookSafeName, chapter: range.chapter, word: word, profileId: profileId)
    }

    private func scheduleToastDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if askToast != nil { askToast = nil }
        }
    }

    /// CR-1 补：同色高亮重叠/相接 → 融合成一条（否则渲染同色无缝合并，
    /// 第二笔看起来"没显示"——粟粟 07-06 踩的）。融合保留最早那条的 id（replies 不悬空），
    /// 其余删除并把它们的 reply 重挂到幸存者。
    private func addHighlight(_ range: SelectedRange) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        let overlapping = all.filter {
            $0.kind == "highlight" && $0.role == "user" && $0.replyTo == nil &&
            $0.chapter == range.chapter &&
            $0.anchorStart <= range.end && $0.anchorEnd >= range.start
        }

        if let survivor = overlapping.min(by: { $0.createdAt < $1.createdAt }) {
            let newStart = min(range.start, overlapping.map(\.anchorStart).min()!)
            let newEnd = max(range.end, overlapping.map(\.anchorEnd).max()!)
            let title = index?.chapters.first(where: { $0.no == range.chapter })?.title ?? ""
            let mergedAnchor = ChapterHTMLRenderer.flowSlice(
                title: title, text: chapterText, start: newStart, end: newEnd
            ) ?? range.text

            let dropped = Set(overlapping.map(\.id)).subtracting([survivor.id])
            for i in all.indices {
                if all[i].id == survivor.id {
                    all[i].anchorStart = newStart
                    all[i].anchorEnd = newEnd
                    all[i].anchorText = mergedAnchor
                } else if let r = all[i].replyTo, dropped.contains(r) {
                    all[i].replyTo = survivor.id   // 被并掉的卡的 reply 重挂幸存者
                }
            }
            all.removeAll { dropped.contains($0.id) }
            try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
            allNotes = all
            chapterNotes = all.filter { $0.chapter == currentChapter }
            rerenderCurrentChapter()
            askToast = "已合并高亮"
        } else {
            let note = BookStore.Note(
                id: UUID().uuidString,
                chapter: range.chapter,
                anchorText: range.text,
                anchorStart: range.start,
                anchorEnd: range.end,
                kind: "highlight",
                content: "",
                role: "user",
                messageId: nil,
                createdAt: Date()
            )
            appendNote(note)
            askToast = "已高亮"
        }
        scheduleToastDismiss()
        selectedRange = nil
        ReadingSignals.logEvent(type: "highlight", book: bookSafeName, chapter: range.chapter, profileId: profileId)
    }

    private func saveNote() {
        guard let range = selectedRange else { showNoteEditor = false; return }
        let content = noteEditorContent.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }

        if let eid = editingNoteId {
            // 编辑模式：原 note 升级/改写 content（kind=highlight 升级为 note）
            var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
            if let i = all.firstIndex(where: { $0.id == eid }) {
                all[i].content = content
                if all[i].kind == "highlight" { all[i].kind = "note" }
                try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
                allNotes = all
                chapterNotes = all.filter { $0.chapter == currentChapter }
                rerenderCurrentChapter()
            }
        } else {
            // 新增模式
            let note = BookStore.Note(
                id: UUID().uuidString,
                chapter: range.chapter,
                anchorText: range.text,
                anchorStart: range.start,
                anchorEnd: range.end,
                kind: "note",
                content: content,
                role: "user",
                messageId: nil,
                createdAt: Date()
            )
            appendNote(note)
            ReadingSignals.logEvent(type: "note", book: bookSafeName, chapter: range.chapter, profileId: profileId)
        }
        showNoteEditor = false
        selectedRange = nil
        noteEditorContent = ""
        editingNoteId = nil
    }

    /// 追加一条笔记到 notes.json，刷新当前章节高亮渲染（保持 scroll 位置）。
    private func appendNote(_ note: BookStore.Note) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        all.append(note)
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        allNotes = all
        chapterNotes = all.filter { $0.chapter == currentChapter }
        rerenderCurrentChapter()
    }

    /// 删一条笔记（批注抽屉里左滑/contextMenu 触发）
    /// 注意：aiBubble 删了**不删**主对话里的 MessageNode——只断书侧锚点，避免误删对话历史
    /// CR-1：删顶层卡级联删它的 reply 串（UI 层已保证含 AI reply 的卡进不到这里）
    private func deleteNote(_ note: BookStore.Note) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        all.removeAll { $0.id == note.id || $0.replyTo == note.id }
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        allNotes = all
        if note.chapter == currentChapter {
            chapterNotes = all.filter { $0.chapter == currentChapter }
            rerenderCurrentChapter()
        }
    }

    // MARK: - M3-B 问小克 → 楼层主对话

    /// 把选段当作 quote 注入楼层主对话；小克回复时 vm 的 sendMessage 路径自然走流式。
    /// 用户消息的 MessageNode 上盖 bookRef，主对话里能看到 "📖 书名·第N章" tag。
    /// 同时 notes.json 写一条 kind=aiBubble 占位锚点（content 暂为空，等 vm 写回填）。
    // 问 AI：真身依赖 startDraftConversation/resolveModel/BookChatDrawer，
    // 均属共读系统。入口（toolbar 按钮 + edit menu 条目）已注释，本函数为编译占位。
    private func askXiaoke(_ range: SelectedRange) {
        selectedRange = nil
    }


    // 拆出 ToolbarContentBuilder：三个异构 ToolbarItem 内联时 Swift 在 View/ToolbarContent
    // 两个 toolbar(content:) 重载间推断失败（defc8121 起报 ambiguous）。显式类型即解。
    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down")
                        }
                        .foregroundColor(Theme.textSecondary)
                    }
                    ToolbarItem(placement: .principal) {
                        if let ch = index?.chapters.first(where: { $0.no == currentChapter }) {
                            Text("第 \(currentChapter)/\(index?.totalChapters ?? 0) 章 · \(ch.title)")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        HStack(spacing: 12) {
                            Button {
                                toggleBookmarkHere()
                            } label: {
                                Image(systemName: hasBookmarkHere ? "bookmark.fill" : "bookmark")
                            }
                            .foregroundColor(hasBookmarkHere ? Theme.branchIndicator : Theme.textSecondary)

                            // 陪读开关：开着他会在你读到的段落旁掉弹幕；关着安静读书
                            Button {
                                LiveReadingService.isEnabled.toggle()
                                liveOn = LiveReadingService.isEnabled
                                if !liveOn { LiveReadingService.shared.stop(); liveComment = nil }
                            } label: {
                                Image(systemName: liveOn ? "bubble.left.fill" : "bubble.left")
                            }
                            .foregroundColor(liveOn ? ConsoleView.greenDeep : Theme.textSecondary)
                            .simultaneousGesture(LongPressGesture().onEnded { _ in showCompanionSheet = true })

                            Button {
                                if activeDrawer != .annotations { detectBrokenAnchors() }
                                withAnimation(.spring(response: 0.3)) {
                                    activeDrawer = (activeDrawer == .annotations) ? nil : .annotations
                                }
                            } label: {
                                Image(systemName: "pencil.tip.crop.circle")
                            }
                            .foregroundColor(Theme.textSecondary)

                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    activeDrawer = (activeDrawer == .catalog) ? nil : .catalog
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .foregroundColor(Theme.textSecondary)
                        }
                    }
    }

    private func annotationFromNote(_ n: BookStore.Note) -> ChapterHTMLRenderer.Annotation? {
        let kind: ChapterHTMLRenderer.Annotation.Kind
        switch n.kind {
        case "highlight": kind = .highlight
        case "aiBubble": kind = .aiUnderline
        case "note": kind = .note
        default: return nil
        }
        return ChapterHTMLRenderer.Annotation(
            id: n.id, kind: kind, start: n.anchorStart, end: n.anchorEnd,
            author: n.role == "ai" ? .ai : .user,
            anchorText: n.anchorText
        )
    }

    /// CR-1 失锚检测：有注章节逐章比对 offset 切片 vs anchorText（宽容：去空白归一化）。
    /// 打开批注抽屉时算一次，结果给卡片标「原文已变」。
    private func detectBrokenAnchors() {
        var broken: Set<String> = []
        for ch in Set(allNotes.map(\.chapter)) {
            guard let meta = index?.chapters.first(where: { $0.no == ch }),
                  let text = BookStore.loadChapterText(safeName: bookSafeName, chapterNo: ch, profileId: profileId)
            else { continue }
            let anns = allNotes.filter { $0.chapter == ch }.compactMap(annotationFromNote)
            broken.formUnion(ChapterHTMLRenderer.brokenAnchorIds(title: meta.title, text: text, annotations: anns))
        }
        brokenNoteIds = broken
    }

    /// debounce 1s 写 index.json + 更新 BookEntry
    /// 陪读 sheet 用：本书的 BookEntry（完成态/补课进度都记在它上面）
    private var bookEntryForCompanion: BookEntry? {
        let sn = bookSafeName
        let desc = FetchDescriptor<BookEntry>(predicate: #Predicate { $0.id == sn })
        return try? modelContext.fetch(desc).first
    }

    /// 今日痕迹摘要（读书日记的素材）：本章她划的线和写的批注
    private var todayNotesDigest: String {
        chapterNotes
            .filter { $0.role == "user" && Calendar.current.isDateInToday($0.createdAt) }
            .map { n in
                let q = n.anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
                let t = n.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return q.isEmpty ? "· \(t)" : (t.isEmpty ? "· 「\(q)」" : "· 「\(q)」→ \(t)")
            }
            .joined(separator: "\n")
    }

    /// 立刻落盘进度（「今天看到这里」用，不等防抖）
    private func saveProgressNow() {
        saveTask?.cancel()
        saveProgress()
    }

    private func scheduleSaveProgress() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveProgress()
        }
    }

    private func saveProgress() {
        guard var idx = index else { return }
        idx.currentChapter = currentChapter
        idx.scrollRatio = latestScrollRatio
        idx.updatedAt = Date()
        try? BookStore.saveIndex(idx, safeName: bookSafeName, profileId: profileId)
        index = idx

        // 同步更新 SwiftData BookEntry（让书架反应式更新进度）
        let safe = bookSafeName
        let pid = profileId
        let desc = FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.id == safe && $0.profileId == pid }
        )
        if let entry = try? modelContext.fetch(desc).first {
            entry.currentChapter = currentChapter
            entry.scrollRatio = latestScrollRatio
            entry.lastReadAt = Date()
            entry.updateTime = Date()
            try? entry.modelContext?.save()
        }
    }
}
