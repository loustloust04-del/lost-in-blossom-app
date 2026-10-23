import SwiftUI
import UIKit

/// 设置 → 数据 →「导出全局数据」：原样整包备份入口（BunnyPalace-Next Phase A）。
final class RawBackupController: ObservableObject {
    @Published var running = false
    @Published var done = 0
    @Published var total = 0
    @Published var label = ""
    @Published var result: RawBackupExporter.Result?
    @Published var errorText: String?
    @Published var shareItem: ExportShareItem?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func start() {
        guard !running else { return }
        running = true
        result = nil
        errorText = nil
        done = 0
        total = 0
        label = "准备中"
        UIApplication.shared.isIdleTimerDisabled = true
        // 切到后台时向系统申请一小段宽限时间（通常约 30 秒），短暂切走不至于中断
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "RawBackup") { [weak self] in
            self?.endBackgroundTask()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let r = try RawBackupExporter.run { d, t, l in
                    DispatchQueue.main.async {
                        self?.done = d
                        self?.total = t
                        self?.label = l
                    }
                }
                DispatchQueue.main.async {
                    self?.finish()
                    self?.result = r
                    self?.shareItem = ExportShareItem(url: r.zipURL)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finish()
                    self?.errorText = error.localizedDescription
                }
            }
        }
    }

    private func finish() {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}

struct RawBackupSection: View {
    @StateObject private var controller = RawBackupController()

    private static let bytes = ByteCountFormatter()

    var body: some View {
        Section {
            if controller.running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(controller.done), total: Double(max(controller.total, 1)))
                        .tint(Theme.branchIndicator)
                    Text("打包中 \(controller.done)/\(controller.total) · \(controller.label)")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Text("请尽量留在本页面；短暂切走约 30 秒内回来不会中断")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            } else {
                Button(action: { controller.start() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.badge.checkmark")
                        Text("原样整包备份（迁移用）")
                        Spacer()
                    }
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let r = controller.result, !controller.running {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已打包 \(r.fileCount) 个文件 · 原始 \(Self.bytes.string(fromByteCount: r.totalBytes)) · 备份包 \(Self.bytes.string(fromByteCount: r.zipSize))")
                    Text("校验值 \(String(r.zipSHA256.prefix(16)))")
                        .textSelection(.enabled)
                    if !r.integrityProblems.isEmpty {
                        Text("⚠️ 数据库自检有异常 \(r.integrityProblems.count) 项，备份仍已保存，请把包交给工程核对")
                    }
                    if !r.skipped.isEmpty {
                        Text("⚠️ 有 \(r.skipped.count) 个文件没读到，详情在包内 manifest.json")
                    }
                }
                .font(.caption)
                .foregroundColor(Theme.textMuted)

                Button(action: { controller.shareItem = ExportShareItem(url: r.zipURL) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("保存 / 分享备份包")
                        Spacer()
                    }
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let e = controller.errorText, !controller.running {
                Text("备份失败：\(e)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("导出全局数据")
        } footer: {
            Text("原样打包本机全部数据：聊天数据库快照、附件、贴纸、文件库、书、主题字体和设置，附文件清单与校验值。只读，不改动任何数据。API Key 存在钥匙串里不会导出，迁移后需重新填写。备份包含私人聊天，请存到「文件」或 iCloud Drive，不要发到公开的地方。")
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
        .sheet(item: $controller.shareItem) { item in
            ExportActivityView(items: [item.url])
        }
    }
}
