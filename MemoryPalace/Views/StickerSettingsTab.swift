import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - iOS Sticker Settings Page

struct IOSStickerPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var stickerAssetCount: Int = 0
    @State private var placedStickerCount: Int = 0
    @State private var stickerDiskUsage: String = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showFileImporter = false
    @State private var statusMessage: String? = nil

    var body: some View {
        List {
            Section("贴纸库") {
                HStack(spacing: 20) {
                    stickerStat("贴纸资产", value: "\(stickerAssetCount)")
                    stickerStat("已贴数量", value: "\(placedStickerCount)")
                    stickerStat("磁盘占用", value: stickerDiskUsage)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section("贴纸数据") {
                Text("导出包含贴纸资产（图片+描边）和画布布局。导入后贴纸归位。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)

                HStack(spacing: 12) {
                    Button(action: exportPack) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: Theme.F.caption))
                            Text(isExporting ? "导出中..." : "导出贴纸包")
                                .font(.system(size: Theme.F.secondary, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.branchIndicator))
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)

                    Button(action: { showFileImporter = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: Theme.F.caption))
                            Text(isImporting ? "导入中..." : "导入贴纸包")
                                .font(.system(size: Theme.F.secondary, weight: .medium))
                        }
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().stroke(Theme.branchIndicator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isImporting)
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("贴纸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadStats() }
        .sheet(isPresented: $showFileImporter) {
            DocumentPickerView(contentTypes: [UTType(filenameExtension: "stickerpack") ?? .data]) { urls in
                importPack(result: .success(urls))
            } onCancel: {}
        }
    }

    private func stickerStat(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        }
    }

    private func loadStats() {
        guard let pid = profileManager?.currentProfile.id else { return }

        stickerAssetCount = StickerViewModel.assetCount(profileId: pid, context: modelContext)
        placedStickerCount = StickerViewModel.placedCount(profileId: pid, context: modelContext)

        let dir = StickerFileManager.stickerDirectory(profileId: pid)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            let totalBytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
            if totalBytes < 1024 * 1024 {
                stickerDiskUsage = "\(totalBytes / 1024) KB"
            } else {
                stickerDiskUsage = String(format: "%.1f MB", Double(totalBytes) / 1024 / 1024)
            }
        } else {
            stickerDiskUsage = "0 KB"
        }
    }

    private func exportPack() {
        guard let pid = profileManager?.currentProfile.id else { return }
        isExporting = true
        statusMessage = nil
        Task {
            do {
                let url = try await StickerPackExporter.export(profileId: pid, context: modelContext)
                await MainActor.run {
                    isExporting = false
                    // iOS 分享面板
                    let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = scene.windows.first?.rootViewController {
                        if let popover = activityVC.popoverPresentationController {
                            popover.sourceView = root.view
                            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                        }
                        root.present(activityVC, animated: true)
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    statusMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importPack(result: Result<[URL], Error>) {
        guard let pid = profileManager?.currentProfile.id else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            statusMessage = nil
            Task {
                do {
                    let counts = try await StickerPackImporter.importPack(url: url, profileId: pid, context: modelContext)
                    await MainActor.run {
                        isImporting = false
                        statusMessage = "导入成功！\(counts.assets) 个贴纸，\(counts.placements) 个布局"
                        loadStats()
                    }
                } catch {
                    await MainActor.run {
                        isImporting = false
                        statusMessage = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
        case .failure(let error):
            statusMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }
}
