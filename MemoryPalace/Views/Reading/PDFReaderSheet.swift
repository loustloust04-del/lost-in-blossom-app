import SwiftUI
import SwiftData
import PDFKit

/// CR-7 P1：PDF 阅读器（保真第二形态，与 BookReaderSheet 并列，书架按 format 分流）。
/// PDFView 原生渲染（翻页/缩放/滚动系统级）+ outline 目录抽屉 + 进度存续
/// （currentChapter 语义 = 当前页 1-based，totalChapters = 总页数——index.json 零 schema 改动）。
/// 批注/AI 共读归 P2/P3。
struct PDFReaderSheet: View {
    let bookSafeName: String
    let profileId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    // 基础阅读器不需要 ConversationViewModel（共读功能已 stub）；且 Page 2 阅读器面板
    // 环境没注入它——非 optional @Environment 找不到对象会 fatalError → 进书秒崩。改 optional。
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("assistantName") private var assistantName = "助手"

    @State private var index: BookStore.BookIndex?
    @State private var document: PDFDocument?
    @State private var currentPage: Int = 1        // 1-based
    @State private var showCatalog = false
    @State private var loadError: String?
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var contextTask: Task<Void, Never>? = nil

    // F1/F2 书签 + 搜索
    @State private var bookmarks: [BookStore.Bookmark] = []
    @State private var catalogQuery = ""
    @State private var searchResult: BookSearch.Result = .init(hits: [])
    @State private var searchTask: Task<Void, Never>? = nil

    // P2 框选批注
    @State private var allNotes: [BookStore.Note] = []
    @State private var showAnnotationList = false
    @State private var isBoxSelect = false
    @State private var pendingSelection: PDFSelectionResult? = nil
    @State private var showActionMenu = false
    @State private var showNoteEditor = false
    @State private var noteEditorText = ""
    @State private var quickLookNoteIds: [String]? = nil
    @State private var askToast: String? = nil
    @State private var renderedAnnotations: [PDFAnnotation] = []

    struct PDFSelectionResult: Identifiable {
        let id = UUID()
        let page: Int
        let quote: String
        let rects: [[Double]]
    }

    var body: some View {
        Group {
            if let err = loadError {
                errorView(err)
            } else if let document {
                readerBody(document)
            } else {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadBook() }
        // CR-2 阅读打点：sheet 活着 = 在读，60s 一跳（chapter 语义 = 当前页）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, index != nil else { continue }
                ReadingSignals.logTick(
                    bookSafeName: bookSafeName,
                    bookDisplayName: index?.name ?? bookSafeName,
                    chapter: currentPage,
                    profileId: profileId
                )
            }
        }
    }

    private func readerBody(_ document: PDFDocument) -> some View {
        NavigationStack {
            attachInteractions(readerChrome(document))
        }
    }

    /// ZStack + 顶栏 + 目录/批注列表 sheet（与 attachInteractions 拆开，
    /// 否则整条 modifier 链是单个表达式，type-check 超时——本文件实测炸过两次）
    private func readerChrome(_ document: PDFDocument) -> some View {
            ZStack {
                PDFKitView(document: document, initialPage: currentPage, safeName: bookSafeName, assistantName: assistantName, onPageChange: { page in
                    guard page != currentPage else { return }
                    currentPage = page
                    scheduleSaveProgress()
                    schedulePushContext()
                })
                if isBoxSelect {
                    BoxSelectOverlay { rect in
                        NotificationCenter.default.post(
                            name: .pdfBoxSelected, object: nil,
                            userInfo: ["rect": rect, "safeName": bookSafeName])
                    }
                    VStack {
                        Text("拖动框选文字")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.mainBg.opacity(0.92)))
                            .padding(.top, 8)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if let toast = askToast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.accent))
                            .padding(.bottom, 40)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                boxSelectFAB
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Theme.mainBg)
            .navigationTitle(index?.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // PDFView 是 UIKit scrollview，顶栏收不到滚动边缘信号会全透明，
            // 按钮叠在扫描页/封面图上看不见——强制实底
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("\(currentPage) / \(index?.totalChapters ?? document.pageCount)")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        Button {
                            toggleBookmarkHere()
                        } label: {
                            Image(systemName: hasBookmarkHere ? "bookmark.fill" : "bookmark")
                        }
                        .foregroundColor(hasBookmarkHere ? Theme.branchIndicator : Theme.textSecondary)

                        Button {
                            showAnnotationList = true
                        } label: { Image(systemName: "pencil.tip.crop.circle") }
                        .foregroundColor(Theme.textSecondary)

                        Button {
                            showCatalog = true
                        } label: { Image(systemName: "list.bullet") }
                        .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showCatalog) {
                catalogSheet
            }
            .sheet(isPresented: $showAnnotationList) {
                annotationListSheet
            }
    }

    /// 事件订阅 + 选段菜单/笔记编辑/就地小窗。
    /// CI 适配：原单函数修饰符链太长，Swift 类型检查超时（error: unable to type-check
    /// in reasonable time）——一分为二，语义不变。
    private func attachInteractions<V: View>(_ content: V) -> some View {
        attachDialogs(attachEvents(content))
    }

    private func attachEvents<V: View>(_ content: V) -> some View {
        content
            // 框选 → Coordinator 已换算成页坐标 → OCR 相交出 quote/rects → 菜单
            .onReceive(NotificationCenter.default.publisher(for: .pdfBoxResolved)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName,
                      let page = notif.userInfo?["page"] as? Int,
                      let rect = notif.userInfo?["rect"] as? CGRect else { return }
                resolveSelection(page: page, box: rect)
            }
            // tap 命中已有批注 → 就地小窗
            .onReceive(NotificationCenter.default.publisher(for: .pdfPageTapped)) { notif in
                guard !isBoxSelect,
                      (notif.userInfo?["safeName"] as? String) == bookSafeName,
                      let page = notif.userInfo?["page"] as? Int,
                      let point = notif.userInfo?["point"] as? CGPoint else { return }
                handleTap(page: page, point: point)
            }
            // 原生选字菜单（坨坨浮条：文本层就绪的书 + 文字版 PDF）
            .onReceive(NotificationCenter.default.publisher(for: .pdfNativeSelectionAction)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName,
                      let name = notif.userInfo?["name"] as? String,
                      let page = notif.userInfo?["page"] as? Int,
                      let quote = notif.userInfo?["quote"] as? String,
                      let rects = notif.userInfo?["rects"] as? [[Double]] else { return }
                let sel = PDFSelectionResult(page: page, quote: quote, rects: rects)
                switch name {
                case "highlight": addHighlight(sel)
                case "addNote":
                    pendingSelection = sel
                    noteEditorText = ""
                    showNoteEditor = true
                case "askAI": askAI(sel)
                case "addVocab": addVocab(sel)
                default: break
                }
            }
            // 批注变化（含 aiBubble 回填）→ 重渲染划线
            .onReceive(NotificationCenter.default.publisher(for: .bookNotesDidChange)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
                reloadNotes()
            }
            // 全书文本层就绪（后台索引完成）
            .onReceive(NotificationCenter.default.publisher(for: .bookTextLayerReady)) { notif in
                guard (notif.userInfo?["safeName"] as? String) == bookSafeName else { return }
                showToast("全书文字索引好了，重新打开本书就能直接选字")
            }
    }

    private func attachDialogs<V: View>(_ content: V) -> some View {
        content
            .confirmationDialog(
                pendingSelection.map { sel in
                    let head = sel.quote.prefix(40)
                    return "「\(head)\(sel.quote.count > 40 ? "…" : "")」"
                } ?? "",
                isPresented: $showActionMenu,
                titleVisibility: .visible
            ) {
                Button("高亮") { if let s = pendingSelection { addHighlight(s) } }
                Button("写笔记") {
                    noteEditorText = ""
                    showNoteEditor = true
                }
                Button("问\(assistantName)") { if let s = pendingSelection { askAI(s) } }
                Button("收进生词本") { if let s = pendingSelection { addVocab(s) } }
                Button("取消", role: .cancel) { pendingSelection = nil }
            }
            .alert("写笔记", isPresented: $showNoteEditor) {
                TextField("想说点什么…", text: $noteEditorText)
                Button("存") { if let s = pendingSelection { addNote(s, content: noteEditorText) } }
                Button("取消", role: .cancel) { pendingSelection = nil }
            }
            .sheet(isPresented: Binding(get: { quickLookNoteIds != nil },
                                        set: { if !$0 { quickLookNoteIds = nil } })) {
                NoteQuickLookSheet(
                    noteIds: quickLookNoteIds ?? [],
                    allNotes: allNotes,
                    assistantName: assistantName,
                    onReply: { parent, content in
                        let reply = BookStore.Note(
                            id: UUID().uuidString, chapter: parent.chapter,
                            anchorText: parent.anchorText, anchorStart: 0, anchorEnd: 0,
                            kind: "note", content: content, role: "user",
                            messageId: nil, createdAt: Date(), replyTo: parent.id)
                        appendNote(reply)
                        ReadingSignals.logEvent(type: "reply", book: bookSafeName, chapter: parent.chapter, profileId: profileId)
                    },
                    onDelete: { note in deleteNote(note) },
                    onShowChat: { _ in
                        quickLookNoteIds = nil
                        dismiss()   // aiBubble → 回主对话看全文（对话就在主界面）
                    }
                )
            }
    }

    /// 框选 FAB（粟粟点的：右下角单独一个圆）
    private var boxSelectFAB: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isBoxSelect.toggle() }
                } label: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 19))
                        .foregroundColor(isBoxSelect ? .white : Theme.textSecondary)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(isBoxSelect ? Theme.branchIndicator : Theme.mainBg))
                        .overlay(Circle().stroke(Theme.accent, lineWidth: isBoxSelect ? 0 : 1))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 18)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: - 目录（outline 快照：ChapterMeta.no = 页码）

    private var catalogSheet: some View {
        NavigationStack {
            List {
                if !catalogQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        if searchResult.hits.isEmpty {
                            Text("没搜到").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                        }
                        ForEach(searchResult.hits) { hit in
                            Button {
                                showCatalog = false
                                goToPage(hit.chapter)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(hit.title)
                                            .font(.system(size: Theme.F.secondary, weight: .medium))
                                            .foregroundColor(Theme.branchIndicator)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(hit.chapter)")
                                            .font(.system(size: Theme.F.caption))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                    Text(hit.snippet)
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        if let coverage = searchResult.coverage {
                            Text("搜索结果 · \(coverage)")
                        } else {
                            Text("搜索结果")
                        }
                    }
                } else {
                    if !bookmarks.isEmpty {
                        Section("Bookmarks") {
                            ForEach(bookmarks) { bm in
                                Button {
                                    showCatalog = false
                                    goToPage(bm.chapter)
                                } label: {
                                    HStack {
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.branchIndicator)
                                        Text(bm.title).foregroundColor(Theme.textPrimary).lineLimit(1)
                                        Spacer()
                                        Text("\(bm.chapter)")
                                            .font(.system(size: Theme.F.caption))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                var bms = bookmarks
                                bms.remove(atOffsets: offsets)
                                try? BookStore.saveBookmarks(bms, safeName: bookSafeName, profileId: profileId)
                                bookmarks = bms
                            }
                        }
                    }
                    Section {
                        ForEach(index?.chapters ?? [], id: \.no) { ch in
                            Button {
                                showCatalog = false
                                goToPage(ch.no)
                            } label: {
                                HStack {
                                    Text(ch.title)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(ch.no)")
                                        .font(.system(size: Theme.F.caption))
                                        .foregroundColor(Theme.textMuted)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("目录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            #endif
            .searchable(text: $catalogQuery, prompt: "搜全书")
            .onChange(of: catalogQuery) { _, q in scheduleSearch(q) }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - F1/F2 动作

    private var hasBookmarkHere: Bool {
        bookmarks.contains { $0.chapter == currentPage }
    }

    private func toggleBookmarkHere() {
        let title = index?.chapters.last(where: { $0.no <= currentPage })
            .map { "\($0.title) · 第 \(currentPage) 页" } ?? "第 \(currentPage) 页"
        let added = BookStore.toggleBookmark(
            safeName: bookSafeName, profileId: profileId,
            chapter: currentPage, scrollRatio: 0, title: title)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        showToast(added ? "已加书签" : "书签已取消")
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResult = .init(hits: []); return }
        guard let doc = document else { return }
        let hasText = index?.hasTextLayer == true
        let chapters = index?.chapters ?? []
        let safe = bookSafeName, pid = profileId
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                BookSearch.searchPDF(query: q, document: doc, hasTextLayer: hasText,
                                     safeName: safe, profileId: pid, chapters: chapters)
            }.value
            guard !Task.isCancelled else { return }
            searchResult = result
        }
    }

    private func goToPage(_ page: Int) {
        // currentPage 不预设——由 PDFViewPageChanged 回调驱动，页码指示器只报真跳转
        NotificationCenter.default.post(name: .pdfReaderGoToPage, object: nil, userInfo: ["page": page, "safeName": bookSafeName])
    }

    // MARK: - 批注列表（铅笔按钮：全书批注卡片，与 txt 阅读器抽屉同心智）

    private var annotationListSheet: some View {
        let topLevel = allNotes.filter { $0.replyTo == nil && $0.rects != nil }
            .sorted { ($0.chapter, $0.createdAt) < ($1.chapter, $1.createdAt) }
        let pages = Dictionary(grouping: topLevel, by: \.chapter).keys.sorted()
        return NavigationStack {
            Group {
                if topLevel.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 26)).foregroundColor(Theme.textMuted)
                        Text("还没有批注").font(.system(size: 13)).foregroundColor(Theme.textSecondary)
                        Text("点马克笔框选文字试试").font(.system(size: Theme.F.caption)).foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(pages, id: \.self) { page in
                            Section {
                                ForEach(topLevel.filter { $0.chapter == page }) { note in
                                    annotationCard(note)
                                }
                            } header: {
                                Text(pageHeader(page))
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle("批注")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .presentationDetents([.medium, .large])
    }

    private func annotationCard(_ note: BookStore.Note) -> some View {
        let isAI = note.role == "ai"
        let replies = allNotes.filter { $0.replyTo == note.id }
        return Button {
            showAnnotationList = false
            if note.chapter != currentPage { goToPage(note.chapter) }
            quickLookNoteIds = [note.id]
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isAI ? Color(red: 0.788, green: 0.541, blue: 0.541) : Theme.branchIndicator)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("「\(note.anchorText.replacingOccurrences(of: "\n", with: " "))」")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                    if !note.content.isEmpty {
                        Text(note.content)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(isAI ? assistantName : "你")
                        Text(kindLabel(note.kind))
                        if !replies.isEmpty { Text("\(replies.count) 条回复") }
                    }
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func pageHeader(_ page: Int) -> String {
        if let title = index?.chapters.last(where: { $0.no <= page })?.title {
            return "第 \(page) 页 · \(title)"
        }
        return "第 \(page) 页"
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "highlight": return "高亮"
        case "note": return "笔记"
        case "aiBubble": return "回答"
        default: return kind
        }
    }

    // MARK: - 业务

    private func loadBook() {
        guard let idx = BookStore.loadIndex(safeName: bookSafeName, profileId: profileId) else {
            loadError = "找不到《\(bookSafeName)》"
            return
        }
        let url = BookStore.bookDir(safeName: bookSafeName, profileId: profileId).appendingPathComponent("book.pdf")
        guard let doc = PDFDocument(url: url) else {
            loadError = "无法打开 PDF 文件"
            return
        }
        index = idx
        currentPage = max(1, min(doc.pageCount, idx.currentChapter))
        document = doc
        allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        bookmarks = BookStore.loadBookmarks(safeName: bookSafeName, profileId: profileId)
        renderAnnotations(on: doc)
        schedulePushContext()   // 开书即推——她一打开，daemon 就有材料
        if idx.hasTextLayer == false {
            let safe = bookSafeName, pid = profileId
            Task.detached(priority: .utility) {
                await BookOCRIndexer.shared.indexIfNeeded(safeName: safe, profileId: pid)
            }
        }
    }

    // MARK: - P2 框选批注

    /// 框（页坐标）→ 该页 OCR 行相交 → quote + 贴行 rects → 弹菜单。
    /// 文字版 PDF 的 PDFSelection 原生选字路线后置（验收标的是扫描版）。
    private func resolveSelection(page: Int, box: CGRect) {
        guard let doc = document else { return }
        isBoxSelect = false
        Task { @MainActor in
            let lines = await OCRStore.shared.pageLines(
                safeName: bookSafeName, profileId: profileId, page: page, document: doc)
            guard let sel = OCRStore.selection(from: lines, in: box) else {
                showToast("框里没认出文字")
                return
            }
            pendingSelection = PDFSelectionResult(page: page, quote: sel.quote, rects: sel.rects)
            showActionMenu = true
        }
    }

    private func addHighlight(_ sel: PDFSelectionResult) {
        appendNote(fidelityNote(sel, kind: "highlight", content: ""))
        pendingSelection = nil
        ReadingSignals.logEvent(type: "highlight", book: bookSafeName, chapter: sel.page, profileId: profileId)
    }

    private func addNote(_ sel: PDFSelectionResult, content: String) {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { pendingSelection = nil; return }
        appendNote(fidelityNote(sel, kind: "note", content: text))
        pendingSelection = nil
        ReadingSignals.logEvent(type: "note", book: bookSafeName, chapter: sel.page, profileId: profileId)
    }

    // [共读暂缓] 问 AI（PDF 版）：真身依赖 startDraftConversation/resolveModel（共读系统 API）。
    // OCR stub 让框选识别不出文字 → 动作菜单不可达，本函数为编译占位。
    private func askAI(_ sel: PDFSelectionResult) {
        pendingSelection = nil
    }

    private func addVocab(_ sel: PDFSelectionResult) {
        defer { pendingSelection = nil }
        let word = VocabCollector.collect(
            rawText: sel.quote, bookSafeName: bookSafeName,
            chapter: sel.page, anchorStart: 0, context: modelContext)
        guard let word else { showToast("选段不适合收词"); return }
        showToast("已收「\(word)」进生词本")
        ReadingSignals.logEvent(type: "vocab", book: bookSafeName, chapter: sel.page, word: word, profileId: profileId)
    }

    private func fidelityNote(_ sel: PDFSelectionResult, kind: String, content: String) -> BookStore.Note {
        var note = BookStore.Note(
            id: UUID().uuidString, chapter: sel.page,
            anchorText: sel.quote, anchorStart: 0, anchorEnd: 0,
            kind: kind, content: content, role: "user",
            messageId: nil, createdAt: Date())
        note.rects = sel.rects
        return note
    }

    private func appendNote(_ note: BookStore.Note) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        all.append(note)
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        reloadNotes()
    }

    private func deleteNote(_ note: BookStore.Note) {
        var all = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        let dropIds = Set([note.id] + all.filter { $0.replyTo == note.id && $0.role == "user" }.map(\.id))
        all.removeAll { dropIds.contains($0.id) }
        try? BookStore.saveNotes(all, safeName: bookSafeName, profileId: profileId)
        reloadNotes()
    }

    private func reloadNotes() {
        allNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
        if let doc = document { renderAnnotations(on: doc) }
    }

    // MARK: - 划线渲染（PDFAnnotation：user 薄荷 / AI 玫瑰，半透明叠加天然混色）

    private func renderAnnotations(on doc: PDFDocument) {
        for ann in renderedAnnotations { ann.page?.removeAnnotation(ann) }
        renderedAnnotations.removeAll()

        let mint = PlatformColor(red: 0.557, green: 0.741, blue: 0.624, alpha: 0.45)   // #8EBD9F
        let rose = PlatformColor(red: 0.788, green: 0.541, blue: 0.541, alpha: 0.40)   // #C98A8A
        for note in allNotes where note.replyTo == nil {
            guard let rects = note.rects, !rects.isEmpty,
                  note.chapter >= 1, let page = doc.page(at: note.chapter - 1) else { continue }
            for r in rects where r.count == 4 {
                let bounds = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -1.5, dy: -1.5)
                let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                ann.color = note.role == "ai" ? rose : mint
                ann.fieldName = note.id
                page.addAnnotation(ann)
                renderedAnnotations.append(ann)
            }
        }
    }

    /// tap（页坐标）命中批注 rects（扩 6pt 容错）→ 就地小窗
    private func handleTap(page: Int, point: CGPoint) {
        let hitIds = allNotes.filter { note in
            note.replyTo == nil && note.chapter == page &&
            (note.rects ?? []).contains { r in
                r.count == 4 &&
                CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).insetBy(dx: -6, dy: -6).contains(point)
            }
        }.map(\.id)
        guard !hitIds.isEmpty else { return }
        quickLookNoteIds = hitIds
    }

    private func showToast(_ text: String) {
        withAnimation { askToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if askToast == text { withAnimation { askToast = nil } }
        }
    }

    private func scheduleSaveProgress() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, var idx = index else { return }
            idx.currentChapter = currentPage
            idx.updatedAt = Date()
            try? BookStore.saveIndex(idx, safeName: bookSafeName, profileId: profileId)
            index = idx

            let safe = bookSafeName
            let pid = profileId
            let desc = FetchDescriptor<BookEntry>(
                predicate: #Predicate<BookEntry> { $0.id == safe && $0.profileId == pid }
            )
            if let entry = (try? modelContext.fetch(desc))?.first {
                entry.currentChapter = currentPage
                entry.lastReadAt = Date()
                try? modelContext.save()
            }
        }
    }

    // MARK: - CR-4 上行（P1.5：「章」= 页窗口，扫描版文本来自 OCR 缓存）

    /// 翻页停稳 2s 才推（OCR ~5s/页是贵活，翻页中取消重排）。
    private func schedulePushContext() {
        contextTask?.cancel()
        contextTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let doc = document, let idx = index else { return }
            let page = currentPage
            let hasText = idx.hasTextLayer == true

            // 页窗口 = 当前页 ±1，给 daemon 足够的阅读语境
            var texts: [String] = []
            for p in max(1, page - 1)...min(doc.pageCount, page + 1) {
                if hasText {
                    texts.append(doc.page(at: p - 1)?.string ?? "")
                } else {
                    texts.append(await OCRStore.shared.pageText(
                        safeName: bookSafeName, profileId: profileId, page: p, document: doc))
                }
            }
            guard !Task.isCancelled, currentPage == page else { return }
            pushReadingContext(page: page, text: texts.joined(separator: "\n\n"))

            if !hasText {
                let safe = bookSafeName, pid = profileId
                Task.detached(priority: .utility) {
                    await OCRStore.shared.prefetch(safeName: safe, profileId: pid, around: page, document: doc)
                }
            }
        }
    }

    /// 与 BookReaderSheet.pushReadingContext 同构——chapter 语义 = 页码，
    /// chapterTitle = outline 里 ≤ 当前页的最近章名（页窗口的可读定位）。
    private func pushReadingContext(page: Int, text: String) {
        let title = index?.chapters.last(where: { $0.no <= page })?.title ?? "第 \(page) 页"
        let userNotes = BookStore.loadNotes(safeName: bookSafeName, profileId: profileId)
            .filter { $0.role == "user" && $0.chapter == page }
            .map {
                [
                    "id": $0.id,
                    "anchorText": String($0.anchorText.prefix(120)),
                    "content": String($0.content.prefix(200)),
                ]
            }
        var persona = ""
        var userName = "用户"
        if let profile = profileManager?.currentProfile {
            persona = ReadingSignals.buildPersonaPackage(profile: profile, context: modelContext)
            if !profile.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                userName = profile.userName
            }
        }
        // 直播线：txt/epub 那边有，PDF 漏了——所以她读 PDF 时他完全不知道（兔兔实测）
        LivelineReporter.report(.reading, "兔兔在读《\(index?.name ?? bookSafeName)》第 \(page) 页")
        CCBridgeWebSocketClient.shared.send([
            "type": "reading_context",
            "floorId": profileId,
            "userName": userName,
            "safeName": bookSafeName,
            "bookName": index?.name ?? bookSafeName,
            "chapter": page,
            "totalChapters": index?.totalChapters ?? 0,
            "chapterTitle": title,
            "text": String(text.prefix(60_000)),
            "userNotes": userNotes,
            "persona": persona,
        ]) { _ in }
    }

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
}

extension Notification.Name {
    /// PDF 阅读器跳页请求（目录 tap → PDFKitView 桥接）。userInfo: page(Int)/safeName。
    static let pdfReaderGoToPage = Notification.Name("MemoryPalacePDFReaderGoToPage")
    /// 框选完成（overlay → Coordinator，rect 是 PDFView 视图坐标）。userInfo: rect(CGRect)/safeName。
    static let pdfBoxSelected = Notification.Name("MemoryPalacePDFBoxSelected")
    /// 框选已换算页坐标（Coordinator → sheet）。userInfo: page(Int)/rect(CGRect)/safeName。
    static let pdfBoxResolved = Notification.Name("MemoryPalacePDFBoxResolved")
    /// 单击页面（Coordinator → sheet，点已换算页坐标）。userInfo: page(Int)/point(CGPoint)/safeName。
    static let pdfPageTapped = Notification.Name("MemoryPalacePDFPageTapped")
}

#if os(iOS)
typealias PlatformColor = UIColor
#else
typealias PlatformColor = NSColor
#endif

// MARK: - 框选 overlay（虚线框，松手上报）

struct BoxSelectOverlay: View {
    let onDone: (CGRect) -> Void

    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil

    private var rect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)   // 吞手势（VStack 空白穿透教训）
            if let r = rect {
                ZStack {
                    Rectangle().fill(Theme.branchIndicator.opacity(0.12))
                    Rectangle().stroke(Theme.branchIndicator,
                                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if startPoint == nil { startPoint = v.startLocation }
                    currentPoint = v.location
                }
                .onEnded { _ in
                    if let r = rect, r.width > 12, r.height > 8 { onDone(r) }
                    startPoint = nil
                    currentPoint = nil
                }
        )
    }
}

// MARK: - PDFView 桥接（双端）

#if os(iOS)
private typealias PlatformViewRepresentable = UIViewRepresentable
#else
private typealias PlatformViewRepresentable = NSViewRepresentable
#endif

struct PDFKitView: PlatformViewRepresentable {
    let document: PDFDocument
    let initialPage: Int
    var safeName: String = ""
    var assistantName: String = "助手"
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onPageChange: onPageChange)
        c.tapSafeName = safeName
        return c
    }

    private func makePDFView(coordinator: Coordinator) -> PDFView {
        let view = MPPDFView()
        view.bookSafeName = safeName
        view.assistantName = assistantName
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        #if os(iOS)
        view.usePageViewController(false)
        #endif
        coordinator.observe(view)
        if initialPage > 1 {
            coordinator.jump(to: initialPage, initial: true)
        }
        return view
    }

    #if os(iOS)
    func makeUIView(context: Context) -> PDFView { makePDFView(coordinator: context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) {}
    #else
    func makeNSView(context: Context) -> PDFView { makePDFView(coordinator: context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) {}
    #endif

    final class Coordinator: NSObject {
        let onPageChange: (Int) -> Void
        private weak var pdfView: PDFView?
        private var observers: [NSObjectProtocol] = []
        /// 初始进度恢复的目标页：到达前抑制 onPageChange——恢复途中 PDFView 停在
        /// 第 1 页也会发 PageChanged，直接回调会把她的进度反写成 1（645 页书实测踩过）。
        private var initialTarget: Int? = nil

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func observe(_ view: PDFView) {
            pdfView = view
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                guard let self, let v = self.pdfView,
                      let page = v.currentPage,
                      let idx = v.document?.index(for: page) else { return }
                if let target = self.initialTarget {
                    guard idx + 1 == target else { return }
                    self.initialTarget = nil
                }
                self.onPageChange(idx + 1)
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .pdfReaderGoToPage, object: nil, queue: .main
            ) { [weak self] notif in
                guard let page = notif.userInfo?["page"] as? Int else { return }
                self?.jump(to: page)
            })
            // P2 框选：视图坐标 → 页坐标（框中心定页，rect clamp 该页）
            observers.append(NotificationCenter.default.addObserver(
                forName: .pdfBoxSelected, object: nil, queue: .main
            ) { [weak self] notif in
                guard let self, let v = self.pdfView, let doc = v.document,
                      let rect = notif.userInfo?["rect"] as? CGRect,
                      let safeName = notif.userInfo?["safeName"] as? String,
                      let page = v.page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: true)
                else { return }
                let pageRect = v.convert(rect, to: page)
                NotificationCenter.default.post(name: .pdfBoxResolved, object: nil, userInfo: [
                    "page": doc.index(for: page) + 1,
                    "rect": pageRect,
                    "safeName": safeName,
                ])
            })
            // P2 tap 命中批注（与 PDFView 自带手势共存）
            #if os(iOS)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            #else
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
            #endif
        }

        var tapSafeName: String = ""

        #if os(iOS)
        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            postTap(at: g.location(in: pdfView))
        }
        #else
        @objc private func handleClick(_ g: NSClickGestureRecognizer) {
            postTap(at: g.location(in: pdfView))
        }
        #endif

        private func postTap(at point: CGPoint) {
            guard let v = pdfView, let doc = v.document,
                  let page = v.page(for: point, nearest: false) else { return }
            NotificationCenter.default.post(name: .pdfPageTapped, object: nil, userInfo: [
                "page": doc.index(for: page) + 1,
                "point": v.convert(point, to: page),
                "safeName": tapSafeName,
            ])
        }

        /// 大文档 singlePageContinuous 的目标区域是 lazy 布局，首跳会被后续
        /// layout 滚回去——跳后延迟校验，没到就补刀。initial=进度恢复模式
        /// （645 页首开布局慢，重试窗口更长 + 到达前抑制页码回调）。
        func jump(to pageNo: Int, retries: Int = 2, initial: Bool = false) {
            if initial { initialTarget = pageNo }
            guard let v = pdfView, let doc = v.document,
                  let target = doc.page(at: pageNo - 1) else { return }
            let top = CGPoint(x: 0, y: target.bounds(for: .cropBox).height)
            v.go(to: PDFDestination(page: target, at: top))
            let tries = initial ? 8 : retries
            guard tries > 0 else {
                if initialTarget == pageNo { initialTarget = nil }   // 放弃：解除抑制，不反写进度
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, let v = self.pdfView,
                      let cur = v.currentPage, let doc = v.document else { return }
                if doc.index(for: cur) != pageNo - 1 {
                    self.jump(to: pageNo, retries: tries - 1)
                }
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

#if os(iOS)
extension PDFKitView.Coordinator: UIGestureRecognizerDelegate {
    // PDFView 自带 pan/pinch/长按——tap 必须共存否则被内部手势吞
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif

// MARK: - 原生选字菜单（「坨坨」出口：PDFSelection → 批注四项）
// 文本层就绪的书（含文字版 PDF）长按选字后，浮条里出现我们的条目。
// 与 MPReaderWebView（txt 侧）同款：UIMenuController.menuItems 注入 +
// didMoveToWindow 清理；action 读 currentSelection 组 quote + 分行 rects
// （bounds(for:) 是页空间坐标，与 OCR bbox 同系）→ 通知给 sheet 走 P2 动作。

extension Notification.Name {
    /// 原生选字菜单动作。userInfo: name/page(Int)/quote/rects([[Double]])/safeName。
    static let pdfNativeSelectionAction = Notification.Name("MemoryPalacePDFNativeSelectionAction")
}

final class MPPDFView: PDFView {
    var bookSafeName: String = ""
    var assistantName: String = "助手"

    #if os(iOS)
    func installCustomMenuItems() {
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "高亮", action: #selector(mp_highlight(_:))),
            UIMenuItem(title: "加笔记", action: #selector(mp_addNote(_:))),
            UIMenuItem(title: "问\(assistantName)", action: #selector(mp_askAI(_:))),
            UIMenuItem(title: "收生词", action: #selector(mp_addVocab(_:))),
        ]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            UIMenuController.shared.menuItems = nil
        } else {
            installCustomMenuItems()
        }
    }
    #else
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard currentSelection?.string?.isEmpty == false else { return menu }
        menu.addItem(.separator())
        for (title, sel) in [("高亮", #selector(mp_highlight(_:))),
                             ("加笔记", #selector(mp_addNote(_:))),
                             ("问\(assistantName)", #selector(mp_askAI(_:))),
                             ("收生词", #selector(mp_addVocab(_:)))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    #endif

    private func postSelectionAction(_ name: String) {
        guard let selection = currentSelection,
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let page = selection.pages.first,
              let doc = document else { return }
        let rects: [[Double]] = selection.selectionsByLine().compactMap { line in
            guard let p = line.pages.first, p === page else { return nil }
            let b = line.bounds(for: p)
            guard b.width > 0, b.height > 0 else { return nil }
            return [b.origin.x, b.origin.y, b.width, b.height]
        }
        guard !rects.isEmpty else { return }
        NotificationCenter.default.post(name: .pdfNativeSelectionAction, object: nil, userInfo: [
            "name": name,
            "page": doc.index(for: page) + 1,
            "quote": text,
            "rects": rects,
            "safeName": bookSafeName,
        ])
        clearSelection()
    }

    @objc func mp_highlight(_ sender: Any?) { postSelectionAction("highlight") }
    @objc func mp_addNote(_ sender: Any?) { postSelectionAction("addNote") }
    @objc func mp_askAI(_ sender: Any?) { postSelectionAction("askAI") }
    @objc func mp_addVocab(_ sender: Any?) { postSelectionAction("addVocab") }
}
