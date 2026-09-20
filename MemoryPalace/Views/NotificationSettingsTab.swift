import SwiftUI
import UserNotifications
import UIKit

// MARK: - iOS 通知设置页

struct IOSNotificationPage: View {
    @State private var service = LocalNotificationService.shared
    @State private var isRequestingPermission = false

    var body: some View {
        List {
            // 权限状态
            Section {
                authStatusRow
            } header: {
                Text("通知权限")
            } footer: {
                Text("通知权限由系统管理。拒绝后需前往「设置 → Lost in Blossom」重新开启。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 总开关
            Section {
                Toggle(isOn: Binding(
                    get: { service.preferences.isEnabled },
                    set: { newVal in
                        service.preferences.isEnabled = newVal
                        if newVal && service.authStatus == .notDetermined {
                            Task { await service.requestAuthorization() }
                        } else {
                            Task { await service.rescheduleAll() }
                        }
                    }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用通知")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                            Text("允许 Caelum 主动联系你")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textMuted)
                        }
                    } icon: {
                        Image(systemName: "bell.fill")
                            .foregroundColor(Theme.branchIndicator)
                    }
                }
                .tint(Theme.branchIndicator)
                .disabled(service.authStatus == .denied)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 每日问候
            if service.preferences.isEnabled && service.authStatus == .authorized {
                Section {
                    Toggle(isOn: Binding(
                        get: { service.preferences.dailyCheckInEnabled },
                        set: { newVal in
                            service.preferences.dailyCheckInEnabled = newVal
                            Task { await service.rescheduleAll() }
                        }
                    )) {
                        Label {
                            Text("每日问候")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "sun.horizon.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    .tint(Theme.branchIndicator)

                    if service.preferences.dailyCheckInEnabled {
                        DatePicker(
                            "问候时间",
                            selection: Binding(
                                get: {
                                    var comps = DateComponents()
                                    comps.hour   = service.preferences.dailyCheckInHour
                                    comps.minute = service.preferences.dailyCheckInMinute
                                    return Calendar.current.date(from: comps) ?? Date()
                                },
                                set: { date in
                                    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                                    service.preferences.dailyCheckInHour   = comps.hour   ?? 20
                                    service.preferences.dailyCheckInMinute = comps.minute ?? 0
                                    Task { await service.rescheduleAll() }
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                        .tint(Theme.branchIndicator)
                    }
                } header: {
                    Text("每日问候")
                } footer: {
                    Text("Caelum 会在设定时间给你发一句问候。")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                // 主动消息（Phase 3.2）
                Section {
                    Toggle(isOn: Binding(
                        get: { service.preferences.proactiveEnabled },
                        set: { newVal in
                            service.preferences.proactiveEnabled = newVal
                            Task { await service.rescheduleAll() }
                        }
                    )) {
                        Label {
                            Text("主动消息")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundColor(Theme.branchIndicator)
                        }
                    }
                    .tint(Theme.branchIndicator)
                } header: {
                    Text("主动消息")
                } footer: {
                    Text("Caelum 会结合记忆，隔一段时间主动发来一句话（23:00–09:00 静默）。实际触发时机由 iOS 后台调度决定。")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.refreshAuthStatus() }
    }

    // MARK: - 权限状态行

    @ViewBuilder
    private var authStatusRow: some View {
        switch service.authStatus {
        case .authorized, .provisional:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 18))
                Text("已授权")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.vertical, 2)

        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("权限已拒绝")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Text("点此前往系统设置开启")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.F.secondary, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

        case .notDetermined:
            Button {
                isRequestingPermission = true
                Task {
                    await service.requestAuthorization()
                    isRequestingPermission = false
                }
            } label: {
                HStack(spacing: 10) {
                    if isRequestingPermission {
                        ProgressView()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(Theme.branchIndicator)
                            .font(.system(size: 18))
                    }
                    Text(isRequestingPermission ? "请求权限中…" : "请求通知权限")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    if !isRequestingPermission {
                        Image(systemName: "chevron.right")
                            .font(.system(size: Theme.F.secondary, weight: .semibold))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(isRequestingPermission)

        default:
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(Theme.textMuted)
                Text("权限状态未知")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }
}

// MARK: - macOS 占位

