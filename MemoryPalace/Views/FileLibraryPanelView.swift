import SwiftUI
import MarkdownUI

// MARK: - File Library Panel (右栏文件库 tab)

struct FileLibraryPanelView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    // 统一到服务器笔记本（架构审计：文件库唯一真相源 = Gateway /api/notebook）。
    // 你在 app 编辑的、API Caelum 写的、CC Caelum 写的，全是同一本。
    // 本地 FileLibraryStore 保留给附件存储（AttachmentStore），不再作为笔记本。
    @State private var remoteFiles: [NotebookRemoteStore.FileMeta] = []
    @State private var remoteError: String? = nil
    @State private var isLoadingRemote = false
    @State private var showNewFileAlert = false
    @State private var newFileName = ""
    @State private var deletingPath: String? = nil
    @State private var editingFile: EditingFile? = nil
    /// 外部改动冲突（学粟粟 FileEditorSheet 的 external-change 守护，做在 Panel 层）：
    /// 这本笔记本是三方共写的（她在 app 编辑、API Caelum fs_*、CC Caelum fs_*）。
    /// 原保存是盲写 last-write-wins——她编辑期间他 append 的日记会被无声抹掉。
    /// 保存前重读远端指纹比对，撞了弹三选。
    @State private var saveConflict: SaveConflict? = nil
    /// 重命名（文件库菜单第二件；NotebookRemoteStore.rename 网关早就支持，一直没 UI）
    @State private var renamingPath: String? = nil
    @State private var renameText: String = ""
    @State private var previews: [String: String] = [:]

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var isEmpty: Bool { remoteFiles.isEmpty }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    struct EditingFile: Identifiable { let id = UUID(); let path: String; let content: String }
    struct SaveConflict: Identifiable {
        let id = UUID()
        let path: String
        let mine: String      // 她编辑后的版本
        let theirs: String    // 保存瞬间的远端版本（他改过的）
    }

    /// 视图模式：卡片网格（带预览，默认）/ 树形（按目录层级，长文档分章时更清楚）
    @AppStorage("fileLibTreeMode") private var treeMode = false
    @State private var expandedFolders: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if let remoteError {
                errorState(remoteError)
            } else if isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .fileLibraryDidChange)) { _ in reload() }
        // CC 在服务器上写完笔记，hub 会广播一帧过来。收到就重拉，省掉手动下拉。
        .onReceive(NotificationCenter.default.publisher(for: .ccNotebookChanged)) { _ in reload() }
        .alert("新建文件", isPresented: $showNewFileAlert) {
            TextField("文件名（可含 / 子目录）", text: $newFileName)
            Button("创建") { createFile() }
            Button("取消", role: .cancel) { newFileName = "" }
        } message: {
            Text("会自动补 .md 后缀")
        }
        .confirmationDialog(
            "删除文件",
            isPresented: Binding(get: { deletingPath != nil }, set: { if !$0 { deletingPath = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { deletingPath = nil }
        } message: {
            Text(deletingPath.map { "确定删除「\($0)」吗？不可恢复。" } ?? "")
        }
        .alert("他也改过这个文件", isPresented: Binding(
            get: { saveConflict != nil },
            set: { if !$0 { saveConflict = nil } }
        )) {
            Button("我的接在他的后面（都保住）") {
                guard let c = saveConflict else { return }
                let merged = c.theirs + "\n\n---\n\n" + c.mine
                Task {
                    try? await NotebookRemoteStore.write(c.path, content: merged)
                    await WikiLinkIndex.shared.invalidate()
                    await MainActor.run {
                        previews[c.path] = String(merged.prefix(280))
                        GatewayCache.save("notebook-previews", previews)
                        saveConflict = nil; editingFile = nil; reload()
                    }
                }
            }
            Button("用我的覆盖他的", role: .destructive) {
                guard let c = saveConflict else { return }
                Task {
                    try? await NotebookRemoteStore.write(c.path, content: c.mine)
                    await WikiLinkIndex.shared.invalidate()
                    await MainActor.run {
                        previews[c.path] = String(c.mine.prefix(280))
                        GatewayCache.save("notebook-previews", previews)
                        saveConflict = nil; editingFile = nil; reload()
                    }
                }
            }
            Button("先看他的版本", role: .cancel) {
                guard let c = saveConflict else { return }
                // 换成远端最新版重新打开；她的版本进剪贴板兜底，一个字不丢
                UIPasteboard.general.string = c.mine
                saveConflict = nil
                editingFile = EditingFile(path: c.path, content: c.theirs)
            }
        } message: {
            Text("你编辑期间 Caelum 也写了这个文件。直接保存会抹掉他写的。你的版本已备好，选一个处理方式（选「先看」时你的版本会复制到剪贴板）。")
        }
        .alert("重命名 / 移动", isPresented: Binding(
            get: { renamingPath != nil },
            set: { if !$0 { renamingPath = nil } }
        )) {
            TextField("新路径（含目录，如 diary/2026-09.md）", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("确定") {
                guard let old = renamingPath else { return }
                let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !new.isEmpty, new != old else { renamingPath = nil; return }
                Task {
                    try? await NotebookRemoteStore.rename(old, to: new)
                    await WikiLinkIndex.shared.invalidate()
                    await MainActor.run {
                        previews[new] = previews[old]          // 预览跟着改名走
                        previews[old] = nil
                        GatewayCache.save("notebook-previews", previews)
                        renamingPath = nil; reload()
                    }
                }
            }
            Button("取消", role: .cancel) { renamingPath = nil }
        } message: {
            Text("改名或换目录都在这里；指向它的 [[双链]] 不会自动跟，改完自己核一眼。")
        }
        .sheet(item: $editingFile) { f in
            FileEditorSheet(path: f.path, initialContent: f.content,
                onSave: { newContent in
                    Task {
                        // 冲突守护：保存前重读远端。和「打开时的版本」不一样 = 他也改过
                        let remote = (try? await NotebookRemoteStore.read(f.path)) ?? f.content
                        if remote != f.content && remote != newContent {
                            await MainActor.run {
                                saveConflict = SaveConflict(path: f.path, mine: newContent, theirs: remote)
                            }
                            return
                        }
                        try? await NotebookRemoteStore.write(f.path, content: newContent)
                        // 内容变了，双链索引失效重建
                        await WikiLinkIndex.shared.invalidate()
                        await MainActor.run {
                            // 兔兔 0904 报：保存成功但列表仍显示空/旧内容——预览缓存
                            // 只给「没预览的文件」补，改过的老路径永远命中旧值。
                            // 落地即刷：本地先写成新预览，再 reload 兜底。
                            previews[f.path] = String(newContent.prefix(280))
                            GatewayCache.save("notebook-previews", previews)
                            editingFile = nil
                            reload()
                        }
                    }
                },
                onCancel: { editingFile = nil },
                onOpenWikiLink: { raw in
                    // 解析 [[目标]] → 真实路径 → 换文件继续看（保持在同一个 sheet 里）。
                    // Obsidian 工作流补全（学粟粟 846039a6）：点了不存在的 [[链接]] 不再装死——
                    // 直接建这个文件并打开，先链接后落笔本来就是双链笔记的正统写法。
                    Task {
                        if let target = await WikiLinkIndex.shared.resolveTarget(raw),
                           let body = try? await NotebookRemoteStore.read(target) {
                            await MainActor.run { editingFile = EditingFile(path: target, content: body) }
                            return
                        }
                        var newPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newPath.isEmpty else { return }
                        if URL(fileURLWithPath: newPath).pathExtension.isEmpty { newPath += ".md" }
                        let seed = "# " + URL(fileURLWithPath: newPath).deletingPathExtension().lastPathComponent + "\n\n"
                        try? await NotebookRemoteStore.write(newPath, content: seed)
                        await WikiLinkIndex.shared.invalidate()
                        await MainActor.run {
                            editingFile = EditingFile(path: newPath, content: seed)
                            reload()
                        }
                    }
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(isLoadingRemote ? "读取中…" : "\(remoteFiles.count) 个文件")
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
            Spacer()
            // 网格 / 树 切换。长文档分章（如 Y_N 中文翻译/ 下的各章）时树形更清楚。
            Button {
                withAnimation(.easeOut(duration: 0.18)) { treeMode.toggle() }
            } label: {
                Image(systemName: treeMode ? "list.bullet.indent" : "square.grid.2x2")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { newFileName = ""; showNewFileAlert = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("新建")
                        .font(.system(size: Theme.F.secondary))
                }
                .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var fileList: some View {
        ScrollView {
            if treeMode {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 递归 @ViewBuilder 会撞 opaque type 自指（CI 4c19275c 报错），
                    // 改为先把「展开可见」的节点拍平成 (node, depth) 数组再平铺渲染
                    ForEach(flattenVisibleTree(buildFileTree(from: remoteFiles)), id: \.node.id) { pair in
                        treeRow(pair.node, depth: pair.depth)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(remoteFiles) { meta in
                        fileCard(CardMeta(path: meta.path, subtitle: byteText(meta.bytes)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    /// 把树按当前展开状态拍平成可见行（递归留在纯数据层，视图层零递归）
    private func flattenVisibleTree(_ nodes: [FileTreeNode], depth: Int = 0) -> [(node: FileTreeNode, depth: Int)] {
        var out: [(node: FileTreeNode, depth: Int)] = []
        for node in nodes {
            out.append((node, depth))
            if node.kind == .folder, expandedFolders.contains(node.path) {
                out.append(contentsOf: flattenVisibleTree(node.children, depth: depth + 1))
            }
        }
        return out
    }

    private func treeRow(_ node: FileTreeNode, depth: Int) -> some View {
        let isFolder = node.kind == .folder
        let expanded = expandedFolders.contains(node.path)
        return Button {
            if isFolder {
                withAnimation(.easeOut(duration: 0.18)) {
                    if expanded { expandedFolders.remove(node.path) }
                    else { expandedFolders.insert(node.path) }
                }
            } else {
                openFile(node.path)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFolder ? (expanded ? "chevron.down" : "chevron.right") : "doc.text")
                    .font(.system(size: isFolder ? 10 : 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let m = node.meta {
                    Text(byteText(m.bytes))
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.vertical, 7)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct CardMeta { let path: String; let subtitle: String }

    // MARK: - 树形

    /// 目录树节点。2026-08-31 自粟粟 FileLibraryPanelView:601 搬入，
    /// 数据源换成我们的 NotebookRemoteStore.FileMeta。
    struct FileTreeNode: Identifiable {
        enum Kind { case folder, file }
        let id = UUID()
        let name: String
        let path: String
        let kind: Kind
        let meta: NotebookRemoteStore.FileMeta?
        var children: [FileTreeNode]
    }

    /// 把「第十三章」里的中文数字换成阿拉伯数字，供排序用（不改显示名）。
    /// 支持到「九十九」，够章节用。
    static func chapterSortKey(_ name: String) -> String {
        let digits: [Character: Int] = ["零":0,"一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        guard let re = try? NSRegularExpression(pattern: "[零一二三四五六七八九十]+") else { return name }
        let ns = name as NSString
        var out = "", last = 0
        re.enumerateMatches(in: name, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let cn = ns.substring(with: m.range)
            var v = 0, section = 0, hasTen = false
            for ch in cn {
                if ch == "十" {
                    hasTen = true
                    section = section == 0 ? 10 : section * 10
                } else if let d = digits[ch] {
                    section = hasTen ? section + d : d
                }
            }
            v = section
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += String(format: "%03d", v)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// 按 "/" 拆路径建树。排序规则同她：文件夹在前，同类按自然序（第2章排在第10章前）。
    private func buildFileTree(from files: [NotebookRemoteStore.FileMeta]) -> [FileTreeNode] {
        final class Builder {
            let name: String, path: String
            var meta: NotebookRemoteStore.FileMeta?
            var children: [String: Builder] = [:]
            init(name: String, path: String, meta: NotebookRemoteStore.FileMeta? = nil) {
                self.name = name; self.path = path; self.meta = meta
            }
        }
        let root = Builder(name: "", path: "")
        for meta in files {
            let parts = meta.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var cur = root, curPath = ""
            for (i, part) in parts.enumerated() {
                curPath = curPath.isEmpty ? part : curPath + "/" + part
                if i == parts.count - 1 {
                    cur.children[part] = Builder(name: part, path: curPath, meta: meta)
                } else {
                    if cur.children[part] == nil { cur.children[part] = Builder(name: part, path: curPath) }
                    cur = cur.children[part]!
                }
            }
        }
        func sortNodes(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
            if a.kind != b.kind { return a.kind == .folder }
            // 中文数字归一化后再比：否则「第一章/第三章/第二章」会按字面排错
            // （粟粟那版直接 localizedStandardCompare，兔兔的 Y_N 翻译正好踩到）
            return Self.chapterSortKey(a.name)
                .localizedStandardCompare(Self.chapterSortKey(b.name)) == .orderedAscending
        }
        func convert(_ b: Builder) -> FileTreeNode {
            FileTreeNode(name: b.name, path: b.path,
                         kind: b.meta == nil ? .folder : .file, meta: b.meta,
                         children: b.children.values.map(convert).sorted(by: sortNodes))
        }
        return root.children.values.map(convert).sorted(by: sortNodes)
    }

    private func fileCard(_ meta: CardMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accent.opacity(0.4))
                Text((previews[meta.path]?.isEmpty == false) ? previews[meta.path]! : "（空文件）")
                    .font(.system(size: 8.5))
                    .foregroundColor(Theme.textSecondary.opacity(0.7))
                    .lineLimit(9)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(9)
                    .frame(height: 118, alignment: .top)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white)
                    )
                    .padding(.horizontal, 12)
                    .offset(y: 16)
            }
            .frame(height: 122)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent.opacity(0.72), lineWidth: 1)
            )

            Text(meta.path)
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 2)

            Text(meta.subtitle)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 2)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { openFile(meta.path) }
        .contextMenu {
            Button {
                renamingPath = meta.path
                renameText = meta.path
            } label: { Label("重命名 / 移动", systemImage: "pencil") }
            Button("删除", role: .destructive) { deletingPath = meta.path }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text("笔记本还是空的")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
            Text("新建一个 .md，或让 Caelum 用 fs_write 写进来")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ops

    private func reload() {
        reloadRemote()
    }

    /// 服务器那本要走网络，逐个拉正文做预览。笔记本一般只有几个文件，
    /// 串行拉够用；真多起来再考虑并发或者让网关直接返回摘要。
    private func reloadRemote() {
        guard NotebookRemoteStore.isConfigured else {
            remoteFiles = []
            remoteError = "还没配网关 token，连不上服务器笔记本"
            return
        }
        // 先亮出上次的列表（秒开），再去拉新的
        if let cached: [NotebookRemoteStore.FileMeta] = GatewayCache.load("notebook-list", as: [NotebookRemoteStore.FileMeta].self) {
            remoteFiles = cached
            if let cachedPreviews: [String: String] = GatewayCache.load("notebook-previews", as: [String: String].self) {
                previews = cachedPreviews
            }
        }
        isLoadingRemote = remoteFiles.isEmpty
        Task {
            do {
                let list = try await NotebookRemoteStore.list()
                await MainActor.run {
                    remoteFiles = list
                    remoteError = nil
                    isLoadingRemote = false
                    GatewayCache.save("notebook-list", list)
                }
                // 预览改成后台慢慢补：原来是进页面就把每个文件全文读一遍，
                // 文件多了就是几十次串行网络请求，这才是「点进去要等一会儿」的真凶
                var p: [String: String] = GatewayCache.load("notebook-previews", as: [String: String].self) ?? [:]
                // 陈旧校验：文件大小和预览长度对不上（Caelum 在别处写过、或本地漏刷）
                // 就丢掉旧预览重拉——短文件按全文比，长文件只看有没有预览。
                for meta in list {
                    if let cached = p[meta.path], meta.bytes < 280,
                       cached.utf8.count != meta.bytes {
                        p[meta.path] = nil
                    }
                }
                for meta in list where p[meta.path] == nil {
                    if let content = try? await NotebookRemoteStore.read(meta.path) {
                        p[meta.path] = String(content.prefix(280))
                        await MainActor.run { previews = p }
                    }
                }
                GatewayCache.save("notebook-previews", p)
            } catch {
                await MainActor.run {
                    remoteError = error.localizedDescription
                    isLoadingRemote = false
                }
            }
        }
    }

    private func openFile(_ path: String) {
        Task {
            let content = (try? await NotebookRemoteStore.read(path)) ?? ""
            await MainActor.run {
                editingFile = EditingFile(path: path, content: content)
            }
        }
    }

    private func createFile() {
        var name = newFileName.trimmingCharacters(in: .whitespaces)
        newFileName = ""
        guard !name.isEmpty else { return }
        if !name.hasSuffix(".md") { name += ".md" }
        Task {
            try? await NotebookRemoteStore.write(name, content: "")
            await MainActor.run { reload() }
        }
    }

    private func confirmDelete() {
        guard let p = deletingPath else { return }
        deletingPath = nil
        Task {
            try? await NotebookRemoteStore.delete(p)
            await MainActor.run { reload() }
        }
    }

    private func byteText(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 24))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text(msg)
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("重试") { reload() }
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.branchIndicator)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct FileEditorSheet: View {
    let path: String
    let initialContent: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    /// 预览里点 [[双链]]——由 Panel 解析成真实路径后跳转
    var onOpenWikiLink: ((String) -> Void)? = nil

    @State private var content: String
    @State private var isPreview: Bool = true

    init(path: String, initialContent: String, onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void, onOpenWikiLink: ((String) -> Void)? = nil) {
        self.path = path
        self.initialContent = initialContent
        self.onSave = onSave
        self.onCancel = onCancel
        self.onOpenWikiLink = onOpenWikiLink
        _content = State(initialValue: initialContent)
    }

    /// markdown 格式栏。原生实现——粟粟那版走 WebView（MarkdownWebEditorCommand），
    /// 我们用原生 TextEditor，直接拼字符串更轻。
    /// 没有选区 API 的限制：一律追加到末尾/整行处理，不做「包裹选中文字」。
    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                mdButton("H1", tip: "一级标题") { prependLine("# ") }
                mdButton("H2", tip: "二级标题") { prependLine("## ") }
                mdButton("H3", tip: "三级标题") { prependLine("### ") }
                Divider().frame(height: 16)
                mdIcon("bold", tip: "加粗") { wrapAtEnd("**", "**") }
                mdIcon("italic", tip: "斜体") { wrapAtEnd("*", "*") }
                mdIcon("chevron.left.forwardslash.chevron.right", tip: "行内代码") { wrapAtEnd("`", "`") }
                Divider().frame(height: 16)
                mdIcon("list.bullet", tip: "列表") { prependLine("- ") }
                mdIcon("text.quote", tip: "引用") { prependLine("> ") }
                mdIcon("link", tip: "双链") { wrapAtEnd("[[", "]]") }
                mdIcon("minus", tip: "分隔线") { appendBlock("\n---\n") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Theme.sidebarBg.opacity(0.5))
    }

    private func mdButton(_ label: String, tip: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(minWidth: 26, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mdIcon(_ systemName: String, tip: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 在最后一行行首加前缀（标题/列表/引用用）。已有同类前缀则替换。
    private func prependLine(_ prefix: String) {
        var lines = content.components(separatedBy: "\n")
        guard var last = lines.popLast() else { content = prefix; return }
        for p in ["# ", "## ", "### ", "- ", "> "] where last.hasPrefix(p) {
            last = String(last.dropFirst(p.count)); break
        }
        lines.append(prefix + last)
        content = lines.joined(separator: "\n")
    }

    /// 在末尾插入一对标记，光标位置留给用户手填（加粗/斜体/双链用）
    private func wrapAtEnd(_ open: String, _ close: String) {
        content += open + close
    }

    private func appendBlock(_ block: String) {
        content += block
    }

    /// [[目标]] → [目标](wikilink://目标)，供 Markdown 渲染成可点链接。
    /// 代码围栏内不转换——否则示例代码里的 [[ ]] 会变成链接（粟粟那版的已知局限，这里补上）。
    static func linkifyWikiLinks(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); out.append(line); continue }
            if inFence { out.append(line); continue }
            var l = line
            if let re = try? NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+)\\]\\]") {
                let ns = l as NSString
                var result = ""
                var last = 0
                re.enumerateMatches(in: l, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                    guard let m, m.numberOfRanges > 1 else { return }
                    let target = ns.substring(with: m.range(at: 1))
                    let enc = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? target
                    result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    result += "[\(target)](wikilink://\(enc))"
                    last = m.range.location + m.range.length
                }
                result += ns.substring(from: last)
                l = result
            }
            out.append(l)
        }
        return out.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $isPreview) {
                    Text("预览").tag(true)
                    Text("编辑").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .tint(Theme.branchIndicator)

                Divider()

                if isPreview {
                    ScrollView {
                        // [[双链]] → markdown 链接，点击走 wikilink:// 拦截
                        Markdown(Self.linkifyWikiLinks(content))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == "wikilink",
                                      let raw = url.host?.removingPercentEncoding
                                            ?? url.path.removingPercentEncoding
                                else { return .systemAction }
                                onOpenWikiLink?(raw)
                                return .handled
                            })
                    }
                } else {
                    VStack(spacing: 0) {
                        markdownToolbar
                        Divider().opacity(0.4)
                        TextEditor(text: $content)
                            .font(.system(size: Theme.F.body))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                    }
                }
            }
            .background(Theme.mainBg)
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onCancel() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(content) }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(content == initialContent)
                }
            }
        }
    }
}
