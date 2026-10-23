import SwiftUI
import UIKit
import CryptoKit

/// 设置 → 数据 →「导出全局数据」：原样整包备份入口（BunnyPalace-Next Phase A）。
///
/// v2（用户反馈分享弹窗留不住、没法存进「文件」）：
/// - 备份包打完立刻移到 Library/BunnyBackups/ 长期保存（不在 tmp，不进下次备份），离开页面、重开 App 都还在；
/// - 「存到文件」用系统文件选择器（导出副本）直接选位置保存；「分享」作为备用；
/// - 两个弹窗都由 UIKit 从最上层页面直接弹出，不挂在 List 行上，避免列表重绘把弹窗冲掉；
/// - 控制器是单例：打包途中离开设置页也不丢进度。
struct SavedRawBackup: Codable, Equatable {
    var fileName: String
    var size: Int64
    var sha256: String
    var fileCount: Int
    var totalBytes: Int64
    var skippedCount: Int
    var integrityProblemCount: Int
    var createdAt: Date
}

final class RawBackupController: NSObject, ObservableObject, UIDocumentPickerDelegate {
    static let shared = RawBackupController()

    @Published var running = false
    @Published var done = 0
    @Published var total = 0
    @Published var label = ""
    @Published var saved: SavedRawBackup?
    @Published var errorText: String?
    @Published var notice: String?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    static var storeDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("BunnyBackups", isDirectory: true)
    }
    private static var infoURL: URL { storeDir.appendingPathComponent("latest.json") }

    var savedURL: URL? {
        guard let s = saved else { return nil }
        let u = Self.storeDir.appendingPathComponent(s.fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    override init() {
        super.init()
        loadSaved()
    }

    // MARK: - 持久化

    private func loadSaved() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.infoURL), let s = try? dec.decode(SavedRawBackup.self, from: d),
           FileManager.default.fileExists(atPath: Self.storeDir.appendingPathComponent(s.fileName).path) {
            saved = s
            return
        }
        adoptLeftoverFromTmp()
    }

    /// 旧版把包留在 tmp/RawBackup：如果还在，就收进长期目录（后台算校验值）
    private func adoptLeftoverFromTmp() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("RawBackup", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path),
              let name = names.filter({ $0.hasPrefix("BunnyBackup-") && $0.hasSuffix(".zip") }).sorted().last else { return }
        let src = tmp.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let dst = try? Self.moveIntoStore(src),
                  let sha = try? RawBackupExporter.sha256(of: dst) else { return }
            let size = Int64((try? dst.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let info = SavedRawBackup(fileName: dst.lastPathComponent, size: size, sha256: sha, fileCount: 0,
                                      totalBytes: 0, skippedCount: 0, integrityProblemCount: 0, createdAt: Date())
            Self.writeInfo(info)
            DispatchQueue.main.async { self?.saved = info }
        }
    }

    private static func moveIntoStore(_ src: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        var dir = storeDir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true      // 几百 MB 不必进 iCloud 整机备份
        try? dir.setResourceValues(rv)
        let dst = storeDir.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: src, to: dst)
        return dst
    }

    private static func writeInfo(_ info: SavedRawBackup) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(info).write(to: infoURL, options: .atomic)
    }

    /// 新包落地后，删掉更早的包（只删本目录里的 BunnyBackup-*.zip）
    private static func pruneOld(keeping keep: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: storeDir.path) else { return }
        for n in names where n.hasPrefix("BunnyBackup-") && n.hasSuffix(".zip") && n != keep {
            try? fm.removeItem(at: storeDir.appendingPathComponent(n))
        }
    }

    // MARK: - 打包

    func start() {
        guard !running else { return }
        running = true
        errorText = nil
        notice = nil
        done = 0
        total = 0
        label = "准备中"
        UIApplication.shared.isIdleTimerDisabled = true
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
                let dst = try Self.moveIntoStore(r.zipURL)
                let info = SavedRawBackup(fileName: dst.lastPathComponent, size: r.zipSize, sha256: r.zipSHA256,
                                          fileCount: r.fileCount, totalBytes: r.totalBytes,
                                          skippedCount: r.skipped.count,
                                          integrityProblemCount: r.integrityProblems.count, createdAt: Date())
                Self.writeInfo(info)
                Self.pruneOld(keeping: info.fileName)
                DispatchQueue.main.async {
                    self?.finish()
                    self?.saved = info
                    self?.notice = "打包完成，已存在 App 里。点「存到文件」选个位置保存一份。"
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

    // MARK: - 保存 / 分享（UIKit 直接弹，不挂在 SwiftUI 列表行上）

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        var vc = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }

    func saveToFiles() {
        guard let url = savedURL else { errorText = "找不到备份包，请重新打包"; return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        Self.topViewController()?.present(picker, animated: true)
    }

    func share() {
        guard let url = savedURL, let top = Self.topViewController() else { errorText = "找不到备份包，请重新打包"; return }
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = ac.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(ac, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        notice = "✅ 已保存到「文件」：\(urls.first?.lastPathComponent ?? "")"
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        notice = "没有保存。备份包还留在 App 里，随时可以再点「存到文件」。"
    }
}

struct RawBackupSection: View {
    @ObservedObject private var controller = RawBackupController.shared

    private static let bytes = ByteCountFormatter()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

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
                actionRow(icon: "externaldrive.badge.checkmark",
                          title: controller.saved == nil ? "原样整包备份（迁移用）" : "重新打包（会替换下面这份）") {
                    controller.start()
                }
            }

            if let s = controller.saved, controller.savedURL != nil, !controller.running {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近一份：\(Self.dateFmt.string(from: s.createdAt)) · \(Self.bytes.string(fromByteCount: s.size))"
                         + (s.fileCount > 0 ? " · \(s.fileCount) 个文件" : ""))
                    Text("校验值 \(String(s.sha256.prefix(16)))")
                        .textSelection(.enabled)
                    if s.integrityProblemCount > 0 {
                        Text("⚠️ 数据库自检有异常 \(s.integrityProblemCount) 项，备份仍已保存，请把包交给工程核对")
                    }
                    if s.skippedCount > 0 {
                        Text("⚠️ 有 \(s.skippedCount) 个文件没读到，详情在包内 manifest.json")
                    }
                }
                .font(.caption)
                .foregroundColor(Theme.textMuted)

                actionRow(icon: "folder", title: "存到「文件」") { controller.saveToFiles() }
                actionRow(icon: "square.and.arrow.up", title: "分享…（备用）") { controller.share() }
            }

            if let n = controller.notice, !controller.running {
                Text(n)
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            if let e = controller.errorText, !controller.running {
                Text("备份失败：\(e)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("导出全局数据")
        } footer: {
            Text("原样打包本机全部数据：聊天数据库快照、附件、贴纸、文件库、书、主题字体和设置，附文件清单与校验值。只读，不改动任何数据。打好的包会留在 App 里，可以随时「存到文件」。API Key 存在钥匙串里不会导出，迁移后需重新填写。备份包含私人聊天，请不要发到公开的地方。")
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                Spacer()
            }
            .font(.system(size: Theme.F.secondary))
            .foregroundColor(Theme.branchIndicator)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
