import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 书架视图——文件库 panel 顶部「📚 书架」切换后显示此 view。
/// 顶部「+ 导入书」按钮 + 网格垂直书脊卡片。点击卡片弹 BookReaderSheet。
struct BookshelfView: View {
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [BookEntry]

    @State private var openingBookSafeName: String? = nil
    @State private var showFileImporter = false
    @State private var pendingImportURL: URL? = nil
    @State private var pendingBookName: String = ""
    @State private var pendingBookAuthor: String = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importProgress: String = ""

    @State private var pendingDelete: BookEntry? = nil

    init(profileId: String) {
        self.profileId = profileId
        let pid = profileId
        _entries = Query(
            filter: #Predicate<BookEntry> { $0.profileId == pid },
            sort: [SortDescriptor(\BookEntry.lastReadAt, order: .reverse),
                   SortDescriptor(\BookEntry.addedAt, order: .reverse)]
        )
    }

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                bookGrid
            }
        }
        .background(Theme.mainBg)
        .onAppear {
            // 启动期/进入书架时扫一次文件夹 → 同步 SwiftData 索引
            BookStore.refreshEntries(profileId: profileId, context: modelContext)
        }
        // M5：跨设备同步 — 周期 + 事件驱动 refresh
        // 5s timer：抓 iCloud 异步下载完的远端书；间隔够长不耗 UI
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            BookStore.refreshEntries(profileId: profileId, context: modelContext)
        }
        // 文件库自身变化（CC 工具写文件 / 设置变更）也触发
        .onReceive(NotificationCenter.default.publisher(for: .fileLibraryDidChange)) { _ in
            BookStore.refreshEntries(profileId: profileId, context: modelContext)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.plainText, .pdf, .epub,
                                  UTType(filenameExtension: "txt") ?? .data,
                                  UTType(filenameExtension: "epub") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pendingImportURL = url
                    pendingBookName = url.deletingPathExtension().lastPathComponent
                    pendingBookAuthor = ""
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        .sheet(item: Binding(
            get: { pendingImportURL.map { ImportTarget(url: $0) } },
            set: { if $0 == nil { pendingImportURL = nil } }
        )) { target in
            importInfoSheet(url: target.url)
        }
        // D5：全屏沉浸阅读 sheet——iOS fullScreenCover / macOS sheet 双分支。
        // 不能用 .sheet（iOS partial detent 跟内嵌 NavigationStack 冲突，toolbar/内容被裁）
        .modifier(BookReaderPresenter(
            safeName: Binding(
                get: { openingBookSafeName }, set: { openingBookSafeName = $0 }
            ),
            profileId: profileId
        ))
        .alert("删除这本书？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let entry = pendingDelete {
                    BookStore.deleteBook(safeName: entry.id, profileId: profileId, context: modelContext)
                }
                pendingDelete = nil
            }
        } message: {
            Text("《\(pendingDelete?.name ?? "")》及其所有章节/笔记将被永久删除")
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // SF Symbol 图标 + 文字（对齐 App 其他面板风格，不用 emoji）
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("书架")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(Theme.textPrimary)
            Spacer()
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("导入书")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 32))
                .foregroundColor(Theme.textMuted.opacity(0.5))
            Text("书架还空着")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Text("点右上「+ 导入书」加一本 txt")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(entries.filter { $0.finishedAt == nil }) { entry in
                    BookCard(entry: entry)
                        .onTapGesture {
                            openingBookSafeName = entry.id
                        }
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                pendingDelete = entry
                            }
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // 读完了：折叠在下面，不占在读的位置，但也不让它消失
            let finished = entries.filter { $0.finishedAt != nil }
            if !finished.isEmpty {
                DisclosureGroup {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(finished) { entry in
                            BookCard(entry: entry)
                                .opacity(0.72)
                                .onTapGesture { openingBookSafeName = entry.id }
                                .contextMenu {
                                    Button("重新在读") {
                                        entry.finishedAt = nil
                                        try? modelContext.save()
                                    }
                                    Button("删除", role: .destructive) { pendingDelete = entry }
                                }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("读完了 · \(finished.count)")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Import 信息 sheet

    @ViewBuilder
    private func importInfoSheet(url: URL) -> some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("书名")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("书名", text: $pendingBookName)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            .disabled(isImporting)
                    }
                    HStack {
                        Text("作者")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("可选", text: $pendingBookAuthor)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                            .disabled(isImporting)
                    }
                }
                .listRowBackground(Theme.mainBg)

                if isImporting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(importProgress)
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("导入书籍")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pendingImportURL = nil }
                        .foregroundColor(Theme.textMuted)
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "导入中…" : "导入") { runImport(url: url) }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(isImporting || pendingBookName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 280)
        #endif
    }

    private func runImport(url: URL) {
        isImporting = true
        importProgress = "解析中…"
        let name = pendingBookName.trimmingCharacters(in: .whitespaces)
        let author = pendingBookAuthor.trimmingCharacters(in: .whitespaces)

        Task { @MainActor in
            // 复制文件读权限：fileImporter 给的 URL 是 security-scoped
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                // 按扩展名分流：pdf 保真导入 / epub 解压取章 / 其余走 txt 管线
                let ext = url.pathExtension.lowercased()
                if ext == "epub" {
                    _ = try await BookImporter.importEPUB(
                        url: url,
                        bookName: name,
                        author: author,
                        profileId: profileId,
                        context: modelContext,
                        progress: { @MainActor msg in importProgress = msg }
                    )
                } else if ext == "pdf" {
                    _ = try await BookImporter.importPDF(
                        url: url,
                        bookName: name,
                        author: author,
                        profileId: profileId,
                        context: modelContext,
                        progress: { @MainActor msg in importProgress = msg }
                    )
                } else {
                    _ = try await BookImporter.importTxt(
                        url: url,
                        bookName: name,
                        author: author,
                        profileId: profileId,
                        context: modelContext,
                        progress: { @MainActor msg in importProgress = msg }
                    )
                }
                isImporting = false
                pendingImportURL = nil
            } catch {
                isImporting = false
                importError = error.localizedDescription
            }
        }
    }

    // MARK: - 辅助

    private struct ImportTarget: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private struct OpenBook: Identifiable {
        let safeName: String
        var id: String { safeName }
    }
}

// MARK: - 单本书脊卡片

private struct BookCard: View {
    let entry: BookEntry

    private var progressRatio: Double {
        guard entry.totalChapters > 0 else { return 0 }
        return (Double(entry.currentChapter - 1) + entry.scrollRatio) / Double(entry.totalChapters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !entry.author.isEmpty {
                    Text(entry.author)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                progressBar
            }
        }
        .padding(8)
        .background(Theme.sidebarBg)
        .cornerRadius(8)
    }

    private var cover: some View {
        Group {
            if let data = entry.coverData, let img = platformImage(data) {
                img.resizable().aspectRatio(2.0/3.0, contentMode: .fill)
            } else {
                // Placeholder：薄荷渐变 + 书名首字
                ZStack {
                    LinearGradient(
                        colors: [Theme.branchIndicator.opacity(0.6), Theme.accent],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Text(String(entry.name.prefix(1)))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                }
                .aspectRatio(2.0/3.0, contentMode: .fill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.accent.opacity(0.5))
                Rectangle()
                    .fill(Theme.branchIndicator)
                    .frame(width: geo.size.width * progressRatio)
            }
        }
        .frame(height: 2)
        .clipShape(RoundedRectangle(cornerRadius: 1))
        .padding(.top, 3)
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

// MARK: - 阅读器 sheet 平台分发

/// iOS 用 fullScreenCover（沉浸阅读），macOS 用 sheet（带固定尺寸窗口）
private struct BookReaderPresenter: ViewModifier {
    @Binding var safeName: String?
    let profileId: String

    private struct OpenBook: Identifiable {
        let safeName: String
        var id: String { safeName }
    }

    private var binding: Binding<OpenBook?> {
        Binding(
            get: { safeName.map { OpenBook(safeName: $0) } },
            set: { newValue in safeName = newValue?.safeName }
        )
    }

    /// CR-7：按 format 分流阅读器（pdf → PDFReaderSheet 保真 / 其余 → BookReaderSheet 文本流）
    @ViewBuilder
    private func readerView(_ safeName: String) -> some View {
        if BookStore.loadIndex(safeName: safeName, profileId: profileId)?.format == "pdf" {
            PDFReaderSheet(bookSafeName: safeName, profileId: profileId)
        } else {
            BookReaderSheet(bookSafeName: safeName, profileId: profileId)
        }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: binding) { book in
            readerView(book.safeName)
        }
        #else
        content.sheet(item: binding) { book in
            readerView(book.safeName)
                .frame(minWidth: 700, minHeight: 600)
        }
        #endif
    }
}

