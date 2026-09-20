import SwiftUI

/// 画线数据
struct DrawingLine {
    var points: [CGPoint] = []
    var color: Color = .gray
    var lineWidth: CGFloat = 3
    var isEraser: Bool = false
}

/// 磁性画板 — 画画便签
struct DrawingBoardSheet: View {
    let onSave: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [DrawingLine] = []
    @State private var currentLine = DrawingLine()
    @State private var selectedColor: Color = Color(red: 0.69, green: 0.34, blue: 0.28)
    @State private var lineWidth: CGFloat = 4
    @State private var isErasing = false
    @State private var stickerName = ""
    @State private var showNaming = false
    @State private var sliderOffset: CGFloat = 0
    @State private var isClearing = false
    @State private var showDevPicker = false

    // 开发者选色
    // 粟粟调好的颜色
    @State private var devShellColor = Color(red: 0.80, green: 0.66, blue: 0.73)   // #cca8ba 粉紫壳
    @State private var devFrameColor = Color(red: 0.66, green: 0.82, blue: 0.81)   // #a9d2ce 浅青绿框
    @State private var devScreenColor = Color(red: 0.88, green: 0.89, blue: 0.84)  // #e0e3d7 灰白面
    @State private var devGridColor = Color(red: 0.82, green: 0.83, blue: 0.78)    // #d1d4c7 格纹稍深

    // 磁粉笔触色（参考磁性画板那种暗沉磁粉色）
    // 从粟粟的磁粉色彩参考图吸取的中色（暖→冷）
    private let penColors: [Color] = [
        Color(red: 0.69, green: 0.34, blue: 0.28),  // #b15647 暗砖红
        Color(red: 0.88, green: 0.39, blue: 0.27),  // #e06446 橙红
        Color(red: 0.95, green: 0.69, blue: 0.37),  // #f2af5e 暖橙黄
        Color(red: 0.65, green: 0.53, blue: 0.30),  // #a5874c 黄绿棕
        Color(red: 0.12, green: 0.44, blue: 0.18),  // #1e6f2e 深绿
        Color(red: 0.02, green: 0.41, blue: 0.23),  // #04693a 翠绿
        Color(red: 0.05, green: 0.42, blue: 0.33),  // #0c6a55 蓝绿
        Color(red: 0.03, green: 0.33, blue: 0.30),  // #07544d 暗青
        Color(red: 0.01, green: 0.27, blue: 0.27),  // #034545 深蓝绿
        Color(red: 0.77, green: 0.33, blue: 0.30),  // #c5544d 粉红棕
        Color(red: 0.10, green: 0.10, blue: 0.10),  // 黑色
    ]
    private let widths: [CGFloat] = [2, 5, 10]
    private let canvasSize = CGSize(width: 340, height: 240)
    private let gridSpacing: CGFloat = 5  // 格纹间距

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if showNaming {
                    namingView.padding(20)
                } else {
                    magneticBoard
                }
            }
            .frame(width: canvasSize.width + 60)

            // 开发者选色仪表盘
            if showDevPicker {
                devColorPanel
            }
        }
        .background(Theme.sidebarBg)
    }

    // MARK: - Magnetic Board

    private var magneticBoard: some View {
        VStack(spacing: 0) {
            // 顶部提手区域
            HStack {
                Spacer()
                // 提手
                RoundedRectangle(cornerRadius: 6)
                    .fill(devShellColor.opacity(0.6))
                    .frame(width: 80, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(devShellColor.opacity(0.3))
                            .frame(width: 60, height: 6)
                    )
                Spacer()
                Button { showDevPicker.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 画面区域：蓝色内框 + 灰白磁粉面 + 格纹
            ZStack {
                // 蓝色内框
                RoundedRectangle(cornerRadius: 10)
                    .fill(devFrameColor)
                    .padding(2)

                // 灰白画面
                RoundedRectangle(cornerRadius: 6)
                    .fill(devScreenColor)
                    .padding(8)

                // 画笔内容
                canvasView
                    .padding(8)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                // 格纹点阵（在画笔上面，橡皮擦不会盖住）
                Canvas { context, size in
                    let inset: CGFloat = 8
                    for x in stride(from: inset + gridSpacing, to: size.width - inset, by: gridSpacing) {
                        for y in stride(from: inset + gridSpacing, to: size.height - inset, by: gridSpacing) {
                            let dot = Path(ellipseIn: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
                            context.fill(dot, with: .color(devGridColor))
                        }
                    }
                }
                .padding(8)
                .allowsHitTesting(false)

                // 清除遮罩（opacity 渐变，不用 move 防穿模）
                devScreenColor
                    .padding(8)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(isClearing ? 1 : 0)
            }
            .frame(width: canvasSize.width + 16, height: canvasSize.height + 16)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)

            // 底部拉杆
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(devShellColor.opacity(0.5))
                    .frame(width: canvasSize.width - 20, height: 8)

                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [devFrameColor.opacity(0.9), devFrameColor],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 70, height: 22)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .overlay(
                        HStack(spacing: 3) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(Color.white.opacity(0.3))
                                    .frame(width: 1, height: 12)
                            }
                        }
                    )
                    .offset(x: sliderOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let max = (canvasSize.width - 20) / 2 - 35
                                sliderOffset = min(max, Swift.max(-max, value.location.x - (canvasSize.width - 20) / 2))
                            }
                            .onEnded { _ in
                                let max = (canvasSize.width - 20) / 2 - 35
                                if abs(sliderOffset) > max * 0.7 { clearBoard() }
                                withAnimation(.spring(response: 0.3)) { sliderOffset = 0 }
                            }
                    )
            }
            .padding(.top, 8)

            // 工具栏
            HStack(spacing: 3) {
                ForEach(penColors, id: \.description) { color in
                    Button {
                        selectedColor = color; isErasing = false
                    } label: {
                        Circle().fill(color).frame(width: 14, height: 14)
                            .overlay(
                                Circle().stroke(
                                    !isErasing && selectedColor.description == color.description
                                        ? .white : .clear, lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                ForEach(widths, id: \.self) { w in
                    Button {
                        lineWidth = w; isErasing = false
                    } label: {
                        Circle().fill(.white.opacity(0.7))
                            .frame(width: w + 4, height: w + 4)
                            .background(
                                Circle().fill(!isErasing && lineWidth == w ? .white.opacity(0.25) : .clear)
                                    .frame(width: 20, height: 20)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button { isErasing.toggle() } label: {
                    Image(systemName: "eraser.fill").font(.system(size: 11))
                        .foregroundColor(isErasing ? .yellow : .white.opacity(0.5))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            // 保存
            Button {
                showNaming = true
                stickerName = "画画 \(Date().formatted(.dateTime.hour().minute()))"
            } label: {
                Text("保存为贴纸")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(devShellColor)
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .disabled(lines.isEmpty).opacity(lines.isEmpty ? 0.4 : 1)
            .padding(.top, 8).padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(colors: [devShellColor, devShellColor.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(10)
    }

    // MARK: - Canvas

    private var canvasView: some View {
        Canvas { context, size in
            for line in lines + [currentLine] {
                guard line.points.count > 1 else { continue }
                var path = Path()
                path.move(to: line.points[0])
                for i in 1..<line.points.count {
                    let mid = CGPoint(
                        x: (line.points[i - 1].x + line.points[i].x) / 2,
                        y: (line.points[i - 1].y + line.points[i].y) / 2
                    )
                    path.addQuadCurve(to: mid, control: line.points[i - 1])
                }
                if let last = line.points.last { path.addLine(to: last) }

                if line.isEraser {
                    context.stroke(path, with: .color(devScreenColor),
                                   style: StrokeStyle(lineWidth: line.lineWidth * 3, lineCap: .round, lineJoin: .round))
                } else {
                    context.stroke(path, with: .color(line.color),
                                   style: StrokeStyle(lineWidth: line.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let p = value.location
                    guard p.x >= 0, p.x <= canvasSize.width, p.y >= 0, p.y <= canvasSize.height else { return }
                    if currentLine.points.isEmpty {
                        currentLine.color = selectedColor
                        currentLine.lineWidth = lineWidth
                        currentLine.isEraser = isErasing
                    }
                    currentLine.points.append(p)
                }
                .onEnded { _ in
                    if !currentLine.points.isEmpty { lines.append(currentLine); currentLine = DrawingLine() }
                }
        )
    }

    // MARK: - Dev Color Panel

    private var devColorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🎨 调色板")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Group {
                Text("外壳").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                ColorPicker("", selection: $devShellColor).labelsHidden()

                Text("内框").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                ColorPicker("", selection: $devFrameColor).labelsHidden()

                Text("画面").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                ColorPicker("", selection: $devScreenColor).labelsHidden()

                Text("格纹").font(.system(size: 10)).foregroundColor(Theme.textMuted)
                ColorPicker("", selection: $devGridColor).labelsHidden()
            }
        }
        .padding(12)
        .frame(width: 100)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
    }

    // MARK: - Clear

    private func clearBoard() {
        withAnimation(.easeIn(duration: 0.2)) { isClearing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            lines.removeAll(); currentLine = DrawingLine()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.15)) { isClearing = false }
        }
    }

    // MARK: - Naming

    private var namingView: some View {
        VStack(spacing: 14) {
            Text("给这幅画起个名字")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textSecondary)

            TextField("贴纸名称", text: $stickerName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: Theme.F.body))

            HStack(spacing: 12) {
                Button("返回") { showNaming = false }
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
                    .buttonStyle(.plain)

                Button { exportAndSave() } label: {
                    Text("保存")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Export

    private func exportAndSave() {
        let drawingView = Canvas { context, size in
            for line in lines where !line.isEraser {
                guard line.points.count > 1 else { continue }
                var path = Path()
                path.move(to: line.points[0])
                for i in 1..<line.points.count {
                    let mid = CGPoint(x: (line.points[i-1].x + line.points[i].x)/2, y: (line.points[i-1].y + line.points[i].y)/2)
                    path.addQuadCurve(to: mid, control: line.points[i - 1])
                }
                if let last = line.points.last { path.addLine(to: last) }
                context.stroke(path, with: .color(line.color),
                               style: StrokeStyle(lineWidth: line.lineWidth, lineCap: .round, lineJoin: .round))
            }
        }.frame(width: canvasSize.width, height: canvasSize.height)

        let renderer = ImageRenderer(content: drawingView)
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else { return }
        onSave(pngData); dismiss()
    }
}
