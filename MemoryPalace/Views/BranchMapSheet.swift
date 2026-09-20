import SwiftUI
import SwiftData

/// 分支地图 v6 — Tidy Tree + 保拓扑展开 + 可点开折叠 + user/assistant 区分。
/// 详见 docs/plan-branch-map-v6-tidytree.md。
///
/// v6.1 修订（粟粟反馈 #1#2）：
/// 1. ↕N 标签可点 → toggle 该折叠段展开成 N 个独立 dot；再点缩回
/// 2. 每个 dot 代表一个 user/assistant 气泡（system/tool/empty 节点透传不画）；
///    旁边标 HH:mm 时间；user 圆点（实心）/ assistant 圆环（空心）做形状区分
struct BranchMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: ConversationViewModel

    let onNavigateToNode: (String) -> Void

    @State private var expandedChainHeads: Set<String> = []  // head id 在里面 → 整 chain 展开成 N 个独立 dot
    @State private var lastTappedNodeId: String? = nil       // 顶部 sticky 预览卡显示用
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    /// 实时从 viewModel.currentPath 派生 — 切了 currentPath 后 @Observable 触发 body 重渲染，黄高亮自动跟随
    private var currentPathIds: Set<String> {
        Set(viewModel.currentPath.map { $0.id })
    }

    /// 顶部预览卡显示的节点 id：用户最后 tap 的 / 没 tap 则 fallback 到 currentPath 末端
    private var previewNodeId: String? {
        lastTappedNodeId ?? viewModel.currentPath.last?.id
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("分支地图")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.branchMapSnapshot() {
            VStack(spacing: 0) {
                previewCardBar(snapshot: snapshot)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                GeometryReader { geo in
                    let layout = computeLayout(snapshot: snapshot, geometryWidth: geo.size.width)
                    ScrollView([.vertical]) {
                        ZStack(alignment: .topLeading) {
                            Canvas { ctx, _ in
                                drawConnections(ctx: ctx, layout: layout)
                            }
                            .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)

                            ForEach(layout.visibleNodes) { vn in
                                nodeView(vn)
                            }
                        }
                        .frame(
                            width: max(layout.canvasSize.width, geo.size.width),
                            height: max(layout.canvasSize.height + 40, geo.size.height),
                            alignment: .topLeading
                        )
                    }
                    .scrollIndicators(.hidden)
                }
            }
        } else {
            Text("没有对话数据")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 顶部 sticky 预览卡

    @ViewBuilder
    private func previewCardBar(snapshot: ConversationViewModel.BranchMapSnapshot) -> some View {
        let id = previewNodeId
        let node = id.flatMap { snapshot.nodeMap[$0] }

        VStack(alignment: .leading, spacing: 6) {
            if let n = node {
                HStack(spacing: 6) {
                    Text(n.role == "user" ? userName : assistantName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(n.role == "user" ? Theme.branchIndicator : Theme.textSecondary)
                    if let t = n.createTime {
                        Text(t.formatted(.dateTime.month().day().hour().minute()))
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    Button {
                        viewModel.togglePin(n)
                    } label: {
                        Image(systemName: n.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 13))
                            .foregroundColor(n.isPinned ? Theme.favorite : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                let preview = String(ContentCleaner.clean(n.content, cacheKey: n.id).prefix(140))
                    .replacingOccurrences(of: "\n", with: " ")
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("点击下方节点 → 这里显示该气泡预览")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 76, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.mainBg)
        )
    }

    // MARK: - Node view

    @ViewBuilder
    private func nodeView(_ vn: VisibleNode) -> some View {
        let onPath = isOnVisualPath(vn)
        let mainPathIds = viewModel.branchMapSnapshot()?.mainPathIds ?? []
        let onMain = isOnMainline(vn, mainPathIds: mainPathIds)
        let dotColor: Color = onPath ? Theme.favorite : Color.gray.opacity(0.55)
        // v11: mainline dot 大一圈（11 vs 9 for displayable, 10 vs 8 for collapsed）
        let displayableSize: CGFloat = onMain ? 11 : 9
        let collapsedSize: CGFloat = onMain ? 10 : 8

        ZStack {
            // 36pt 透明 hit area
            Circle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 36, height: 36)

            // Dot：folded ↕ / pinned star / user 实心圆 / assistant 空心环
            if vn.isCollapsed {
                Circle()
                    .fill(dotColor)
                    .frame(width: collapsedSize, height: collapsedSize)
            } else if vn.isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: onMain ? 12 : 10))
                    .foregroundColor(dotColor)
            } else if vn.role == "user" {
                Circle()
                    .fill(dotColor)
                    .frame(width: displayableSize, height: displayableSize)
            } else {
                // assistant：空心环
                Circle()
                    .stroke(dotColor, lineWidth: onMain ? 2.2 : 1.8)
                    .frame(width: displayableSize, height: displayableSize)
            }

            // 时间戳（月日时分，小字号在右下）
            if let ts = vn.timestamp, !vn.isCollapsed {
                Text(ts.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted.opacity(0.75))
                    .fixedSize()
                    .offset(x: 24, y: 10)
            }
        }
        .position(x: vn.x, y: vn.y)
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    // 单击 = 设顶部预览卡 + 快切 currentPath（同步 rebuildPath，不重 buildTree）
                    lastTappedNodeId = vn.lastNodeId
                    viewModel.navigateToNodeFast(nodeId: vn.lastNodeId)
                }
        )

        // 折叠段的 ↕N 标签：点 → 整 chain 全展开
        if vn.isCollapsed {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = expandedChainHeads.insert(vn.id)
                }
            }) {
                Text("↕\(vn.foldedCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.mainBg.opacity(0.95)))
                    .overlay(Capsule().stroke(Color.gray.opacity(0.4), lineWidth: 0.6))
                    .frame(minWidth: 44, minHeight: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .position(x: vn.x + 36, y: vn.y)
        }

        // chain head 展开后的 ⇕ 缩回标签：点 → 整 chain 全缩回
        if vn.isExpandedChainHead {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = expandedChainHeads.remove(vn.id)
                }
            }) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.mainBg.opacity(0.95)))
                    .overlay(Capsule().stroke(Color.gray.opacity(0.4), lineWidth: 0.6))
                    .frame(minWidth: 38, minHeight: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .position(x: vn.x + 32, y: vn.y)
        }
    }

    private func isOnVisualPath(_ vn: VisibleNode) -> Bool {
        let pathIds = currentPathIds
        // v9: collapsed 段必须整段在 path 上才算 on path（避免视觉误导：
        // chain 头在 path 但尾不在时，整段黄色会让用户以为尾巴也在）
        return vn.collapsedNodeIds.allSatisfy { pathIds.contains($0) }
    }

    /// v11: 该节点是否在 conversation 永久 mainPath 上（用 snapshot.mainPathIds，跟 currentPath 解耦）
    private func isOnMainline(_ vn: VisibleNode, mainPathIds: Set<String>) -> Bool {
        return vn.collapsedNodeIds.allSatisfy { mainPathIds.contains($0) }
    }

    // MARK: - Connections

    private func drawConnections(ctx: GraphicsContext, layout: TreeLayout) {
        let activeColor = Theme.favorite                 // currentPath 黄
        let mainlineColor = Color.gray.opacity(0.55)     // mainline 深灰
        let branchColor = Color.gray.opacity(0.28)       // branch 淡灰
        let pathIds = currentPathIds
        let mainPathIds = viewModel.branchMapSnapshot()?.mainPathIds ?? []

        for edge in layout.edges {
            var path = Path()
            path.move(to: CGPoint(x: edge.fromX, y: edge.fromY))
            let dy = edge.toY - edge.fromY
            let c1 = CGPoint(x: edge.fromX, y: edge.fromY + dy * 0.55)
            let c2 = CGPoint(x: edge.toX, y: edge.toY - dy * 0.55)
            path.addCurve(to: CGPoint(x: edge.toX, y: edge.toY), control1: c1, control2: c2)

            // v11: 三层视觉 — currentPath active 黄 2.5pt / mainline 深灰 2pt / branch 淡灰 1pt
            let isActive = isEdgeOnPath(edge: edge, pathIds: pathIds, layout: layout)
            let isMainline = isEdgeOnPath(edge: edge, pathIds: mainPathIds, layout: layout)
            let strokeColor: Color
            let strokeWidth: CGFloat
            if isActive {
                strokeColor = activeColor
                strokeWidth = 2.5
            } else if isMainline {
                strokeColor = mainlineColor
                strokeWidth = 2.0
            } else {
                strokeColor = branchColor
                strokeWidth = 1.0
            }
            ctx.stroke(path, with: .color(strokeColor),
                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        }
    }

    /// v9: edge 两端各自的"整段在 pathIds" 才算 on path（用 allSatisfy）
    /// v11: 复用此函数判断 mainline edge（传 mainPathIds 即可）
    private func isEdgeOnPath(edge: TreeEdge, pathIds: Set<String>, layout: TreeLayout) -> Bool {
        guard let from = layout.visibleNodes.first(where: { $0.id == edge.fromNodeId }),
              let to = layout.visibleNodes.first(where: { $0.id == edge.toNodeId }) else {
            return pathIds.contains(edge.fromNodeId) && pathIds.contains(edge.toNodeId)
        }
        let fromOn = from.collapsedNodeIds.allSatisfy { pathIds.contains($0) }
        let toOn = to.collapsedNodeIds.allSatisfy { pathIds.contains($0) }
        return fromOn && toOn
    }

}

// MARK: - TidyNode + Layout

private final class TidyNode {
    let id: String                  // collapsed → chain head id；普通 → 节点自己 id
    let lastNodeId: String          // collapsed → chain 末尾 id；普通 = id
    let originalNode: MessageNode?
    let isCollapsed: Bool
    let foldedCount: Int
    let isPinned: Bool
    let role: String                // "user" / "assistant" / "" (collapsed/unknown)
    let timestamp: Date?
    let collapsedNodeIds: [String]
    let isExpandedChainHead: Bool   // 我是某 expanded chain 的第一个节点（要画 ⇕ 缩回 icon）
    var children: [TidyNode] = []

    var x: Double = 0
    var y: Double = 0
    var subtreeWidth: Double = 0  // v8 banded layout：measure 阶段算出来

    init(id: String, lastNodeId: String, originalNode: MessageNode?, isCollapsed: Bool, foldedCount: Int, isPinned: Bool, role: String, timestamp: Date?, collapsedNodeIds: [String], isExpandedChainHead: Bool = false) {
        self.id = id
        self.lastNodeId = lastNodeId
        self.originalNode = originalNode
        self.isCollapsed = isCollapsed
        self.foldedCount = foldedCount
        self.isPinned = isPinned
        self.role = role
        self.timestamp = timestamp
        self.collapsedNodeIds = collapsedNodeIds
        self.isExpandedChainHead = isExpandedChainHead
    }
}

private struct VisibleNode: Identifiable {
    let id: String
    let lastNodeId: String
    let x: CGFloat
    let y: CGFloat
    let isCollapsed: Bool
    let foldedCount: Int
    let isPinned: Bool
    let role: String
    let timestamp: Date?
    let collapsedNodeIds: [String]
    let previewNode: MessageNode?
    let isExpandedChainHead: Bool
}

private struct TreeEdge {
    let fromNodeId: String
    let toNodeId: String
    let fromX: CGFloat
    let fromY: CGFloat
    let toX: CGFloat
    let toY: CGFloat
}

private struct TreeLayout {
    let visibleNodes: [VisibleNode]
    let edges: [TreeEdge]
    let canvasSize: CGSize
}

// MARK: - 树构造 + 折叠 + 排版

extension BranchMapSheet {
    fileprivate func computeLayout(snapshot: ConversationViewModel.BranchMapSnapshot, geometryWidth: CGFloat) -> TreeLayout {
        let nodeMap = snapshot.nodeMap
        let childrenMap = snapshot.childrenMap
        // v9: 折叠跟 currentPath 解耦 — 不再用 snapshot.currentPathIds 决定折叠。
        // currentPath 只控高亮颜色（isOnVisualPath / isEdgeOnPath 实时读 viewModel.currentPath）。

        func isDisplayable(_ id: String) -> Bool {
            guard let n = nodeMap[id] else { return false }
            return (n.role == "user" || n.role == "assistant") && !n.content.isEmpty && !n.isTrashed
        }

        /// 跳过 system/tool/empty 节点，返回该 id 下"最近 displayable 后代"列表
        func visibleChildren(_ id: String) -> [String] {
            var out: [String] = []
            func walk(_ id: String) {
                for k in (childrenMap[id] ?? []) {
                    if isDisplayable(k) { out.append(k) } else { walk(k) }
                }
            }
            walk(id)
            return out
        }

        /// 找 displayable 节点的"最近 displayable parent"
        func displayableParent(_ id: String) -> String? {
            var current = nodeMap[id]?.parentId
            while let pid = current {
                if isDisplayable(pid) { return pid }
                current = nodeMap[pid]?.parentId
            }
            return nil
        }

        /// 在 displayable 视角下：该 id 是不是其 displayable parent 的 visibleChildren.first
        func isBranchHead(_ id: String) -> Bool {
            guard let pid = displayableParent(id) else { return false }
            return visibleChildren(pid).first != id
        }

        func isFoldable(_ id: String) -> Bool {
            // v9: 任意 single-child + 非 pinned + 非 branchHead chain 都可折叠
            // （之前限定 currentPath 导致切分支时整树重折叠 → 节点乱跳）
            guard let n = nodeMap[id] else { return false }
            let vKids = visibleChildren(id)
            if vKids.count != 1 { return false }
            if n.isPinned { return false }
            if isBranchHead(id) { return false }
            return true
        }

        // 找顶层 displayable 起点
        let topDisplayables: [String] = {
            if isDisplayable(snapshot.rootId) { return [snapshot.rootId] }
            return visibleChildren(snapshot.rootId)
        }()

        guard let firstId = topDisplayables.first else {
            return TreeLayout(visibleNodes: [], edges: [], canvasSize: .zero)
        }

        // 算 forceUnfolded：每个 expandedChainHeads 里的 head 沿 chain 走到底，所有节点都加入
        // 这样 build 时整 chain 都不会再被折叠
        var forceUnfolded: Set<String> = []
        for headId in expandedChainHeads {
            guard isFoldable(headId) else { continue }
            var chain: [String] = [headId]
            var lastKids = visibleChildren(headId)
            while lastKids.count == 1, isFoldable(lastKids[0]) {
                let nextId = lastKids[0]
                chain.append(nextId)
                lastKids = visibleChildren(nextId)
            }
            for cid in chain { forceUnfolded.insert(cid) }
        }

        // build 递归
        func build(_ id: String) -> TidyNode? {
            guard let node = nodeMap[id] else { return nil }

            // 折叠链：自己 foldable 且不在 forceUnfolded 里
            if isFoldable(id), !forceUnfolded.contains(id) {
                var chain: [String] = [id]
                var lastId = id
                var lastKids = visibleChildren(id)
                while lastKids.count == 1, isFoldable(lastKids[0]), !forceUnfolded.contains(lastKids[0]) {
                    let nextId = lastKids[0]
                    chain.append(nextId)
                    lastId = nextId
                    lastKids = visibleChildren(nextId)
                }
                // v9.1: chain 至少 2 个节点才 collapse；孤立 foldable 节点（chain=1）当普通 dot 画
                if chain.count >= 2 {
                    let lastNode = nodeMap[lastId]
                    let collapsed = TidyNode(
                        id: chain.first!,
                        lastNodeId: lastId,
                        originalNode: lastNode,
                        isCollapsed: true,
                        foldedCount: chain.count,
                        isPinned: false,
                        role: "",
                        timestamp: lastNode?.createTime,
                        collapsedNodeIds: chain
                    )
                    for ck in lastKids {
                        if let child = build(ck) {
                            collapsed.children.append(child)
                        }
                    }
                    return collapsed
                }
                // chain.count == 1: fall through 到普通节点构造
            }

            // 普通节点（force unfolded chain 的 head 节点标记 isExpandedChainHead 以画 ⇕ 缩回 icon）
            let tn = TidyNode(
                id: id,
                lastNodeId: id,
                originalNode: node,
                isCollapsed: false,
                foldedCount: 0,
                isPinned: node.isPinned,
                role: node.role,
                timestamp: node.createTime,
                collapsedNodeIds: [id],
                isExpandedChainHead: expandedChainHeads.contains(id)
            )
            for k in visibleChildren(id) {
                if let child = build(k) {
                    tn.children.append(child)
                }
            }
            return tn
        }

        guard let tree = build(firstId) else {
            return TreeLayout(visibleNodes: [], edges: [], canvasSize: .zero)
        }

        // v10 git graph lane assignment：mainPath child 同父 lane，off-path 各 alloc lane（左右交替）
        let leftPad: Double = 24
        let rightPad: Double = 24
        let availableW = max(120, Double(geometryWidth) - leftPad - rightPad)
        layoutGitGraph(
            root: tree,
            mainPathIds: snapshot.mainPathIds,
            centerX: availableW / 2,
            laneSpacing: 44,
            vSpacing: 60
        )

        let topPad: Double = 24
        var nodes: [VisibleNode] = []
        var edges: [TreeEdge] = []
        var maxX: Double = 0
        var maxY: Double = 0
        collectVisible(tree, leftPad: leftPad, topPad: topPad, nodes: &nodes, edges: &edges, maxX: &maxX, maxY: &maxY)

        let canvasW = max(maxX + leftPad, Double(geometryWidth))
        let canvasH = maxY + topPad + 24
        return TreeLayout(visibleNodes: nodes, edges: edges, canvasSize: CGSize(width: canvasW, height: canvasH))
    }

    /// v11: Git Graph Lane Assignment — 修 v10 两个 critical bug。
    /// 详见 docs/research-branch-map-v11-lane-bugs.md（hermes 验证）。
    ///
    /// Bug 修正：
    /// 1. Fork-scope lane release：兄弟 children 处理完才统一 release（避免同 fork 兄弟复用 lane 重叠）
    /// 2. Side stability：子分支继承父侧别 (parentSide)，不跨主线（避免螺旋）
    ///
    /// 规则：
    /// - mainline lane 0 = center
    /// - mainPath child 沿同 lane；off-path child 各 alloc 独立 lane
    /// - 父 lane > 0 → 子 alloc 优先右；< 0 → 优先左；== 0 (mainline) → 左右平衡
    fileprivate func layoutGitGraph(
        root: TidyNode,
        mainPathIds: Set<String>,
        centerX: Double,
        laneSpacing: Double,
        vSpacing: Double
    ) {
        enum Side { case left, right }

        // 左右 lane 池
        final class LaneAlloc {
            var leftFree: [Int] = []
            var rightFree: [Int] = []
            var leftMaxUsed: Int = 0
            var rightMaxUsed: Int = 0
            var activeLeft: Set<Int> = []
            var activeRight: Set<Int> = []

            /// v11: preferredSide nil 时 balance；非 nil 时强制该侧
            func alloc(preferredSide: Side?) -> Int {
                let side: Side
                if let p = preferredSide {
                    side = p
                } else {
                    side = activeLeft.count <= activeRight.count ? .left : .right
                }
                switch side {
                case .left:
                    let idx: Int
                    if !leftFree.isEmpty { idx = leftFree.removeFirst() }
                    else { leftMaxUsed += 1; idx = leftMaxUsed }
                    activeLeft.insert(idx)
                    return -idx
                case .right:
                    let idx: Int
                    if !rightFree.isEmpty { idx = rightFree.removeFirst() }
                    else { rightMaxUsed += 1; idx = rightMaxUsed }
                    activeRight.insert(idx)
                    return idx
                }
            }

            func release(_ lane: Int) {
                if lane == 0 { return }
                if lane < 0 {
                    let absV = -lane
                    activeLeft.remove(absV)
                    leftFree.append(absV)
                    leftFree.sort()
                } else {
                    activeRight.remove(lane)
                    rightFree.append(lane)
                    rightFree.sort()
                }
            }
        }

        let alloc = LaneAlloc()

        // collapsed chain 节点 id = chain head id（chain 整段在/不在 mainPath 一致）
        func isOnMainPath(_ n: TidyNode) -> Bool {
            mainPathIds.contains(n.id)
        }

        // 父 lane 决定子 alloc 的 preferredSide（v11 fix 2: 不跨主线螺旋）
        func sideForLane(_ lane: Int) -> Side? {
            if lane < 0 { return .left }
            if lane > 0 { return .right }
            return nil  // mainline 子 → balance
        }

        func dfs(_ n: TidyNode, lane: Int, depth: Int) {
            n.x = centerX + Double(lane) * laneSpacing
            n.y = Double(depth) * vSpacing

            // lineChild：n 在 mainPath → mainPath child；n 不在 mainPath → children[0]（branch 内连续）
            let lineChild: TidyNode?
            if isOnMainPath(n) {
                lineChild = n.children.first(where: isOnMainPath)
            } else {
                lineChild = n.children.first
            }

            let preferred = sideForLane(lane)

            // v11 fix 1: 先全部 alloc + dfs，所有 siblings 完成后才统一 release
            var siblingLanes: [Int] = []
            for c in n.children {
                let cLane: Int
                if c === lineChild {
                    cLane = lane
                } else {
                    cLane = alloc.alloc(preferredSide: preferred)
                    siblingLanes.append(cLane)
                }
                dfs(c, lane: cLane, depth: depth + 1)
            }
            // fork-scope release
            for l in siblingLanes { alloc.release(l) }
        }

        dfs(root, lane: 0, depth: 0)
    }

    fileprivate func collectVisible(_ node: TidyNode, leftPad: Double, topPad: Double, nodes: inout [VisibleNode], edges: inout [TreeEdge], maxX: inout Double, maxY: inout Double) {
        let absX = node.x + leftPad
        let absY = node.y + topPad
        nodes.append(VisibleNode(
            id: node.id,
            lastNodeId: node.lastNodeId,
            x: CGFloat(absX),
            y: CGFloat(absY),
            isCollapsed: node.isCollapsed,
            foldedCount: node.foldedCount,
            isPinned: node.isPinned,
            role: node.role,
            timestamp: node.timestamp,
            collapsedNodeIds: node.collapsedNodeIds,
            previewNode: node.originalNode,
            isExpandedChainHead: node.isExpandedChainHead
        ))
        if absX > maxX { maxX = absX }
        if absY > maxY { maxY = absY }
        for child in node.children {
            let childAbsX = child.x + leftPad
            let childAbsY = child.y + topPad
            edges.append(TreeEdge(
                fromNodeId: node.id,
                toNodeId: child.id,
                fromX: CGFloat(absX),
                fromY: CGFloat(absY),
                toX: CGFloat(childAbsX),
                toY: CGFloat(childAbsY)
            ))
            collectVisible(child, leftPad: leftPad, topPad: topPad, nodes: &nodes, edges: &edges, maxX: &maxX, maxY: &maxY)
        }
    }
}
