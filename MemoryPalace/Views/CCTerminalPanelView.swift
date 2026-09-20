import SwiftUI
import SwiftTerm
import Combine

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class CCTerminalController: ObservableObject {
    let sessionName: String
    @Published var error: String?
    weak var terminalView: TerminalView?
    private var hasAttached = false
    private var resizeWork: DispatchWorkItem?

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    func attachOrResize(cols: Int, rows: Int) {
        if hasAttached {
            resizeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                CCBridgeWebSocketClient.shared.sendTerminalResize(
                    session: self.sessionName, cols: cols, rows: rows
                )
            }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        attachIfNotYet(cols: cols, rows: rows)
    }

    func attachIfNotYet(cols: Int, rows: Int) {
        guard !hasAttached else { return }
        hasAttached = true
        CCBridgeWebSocketClient.shared.attachTerminal(
            session: sessionName,
            cols: cols,
            rows: rows,
            onInit: { [weak self] data in
                guard let tv = self?.terminalView else { return }
                tv.feed(byteArray: ArraySlice([0x1b, 0x63]))
                let arr = Array(data)
                tv.feed(byteArray: arr[...])
            },
            onChunk: { [weak self] data in
                guard let tv = self?.terminalView else { return }
                let arr = Array(data)
                tv.feed(byteArray: arr[...])
            },
            onError: { [weak self] reason in
                self?.error = reason
            }
        )
    }

    func detach() {
        CCBridgeWebSocketClient.shared.detachTerminal(session: sessionName)
        hasAttached = false
    }

    func sendInput(_ bytes: Data) {
        CCBridgeWebSocketClient.shared.sendTerminalInput(session: sessionName, bytes: bytes)
    }

    func refresh() {
        CCBridgeWebSocketClient.shared.refreshTerminal(session: sessionName)
    }

    func sendScrollWheel(up: Bool, ticks: Int) {
        guard ticks > 0 else { return }
        let button = up ? "64" : "65"
        let one = "\u{1b}[<\(button);1;1M"
        let seq = String(repeating: one, count: min(ticks, 10))
        guard let data = seq.data(using: .utf8) else { return }
        sendInput(data)
    }
}

// MARK: - 终端按键

struct TerminalKey: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var bytes: [UInt8]
}

let defaultTerminalKeys: [TerminalKey] = [
    TerminalKey(label: "Esc",  bytes: [0x1b]),
    TerminalKey(label: "⌃C",   bytes: [0x03]),
    TerminalKey(label: "Tab",  bytes: [0x09]),
    TerminalKey(label: "⇧Tab", bytes: [0x1b, 0x5b, 0x5a]),
    TerminalKey(label: "↑",    bytes: [0x1b, 0x5b, 0x41]),
    TerminalKey(label: "↓",    bytes: [0x1b, 0x5b, 0x42]),
    TerminalKey(label: "←",    bytes: [0x1b, 0x5b, 0x44]),
    TerminalKey(label: "→",    bytes: [0x1b, 0x5b, 0x43]),
]

final class TerminalKeyStore: ObservableObject {
    static let shared = TerminalKeyStore()
    private static let storeKey = "ccTerminalKeys"

    @Published var keys: [TerminalKey] { didSet { save() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode([TerminalKey].self, from: data),
           !decoded.isEmpty {
            keys = decoded
        } else {
            keys = defaultTerminalKeys
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    func resetToDefault() { keys = defaultTerminalKeys }
}

// MARK: - Cross-platform TerminalView wrapper

#if canImport(UIKit)
final class TerminalAccessoryBar: UIView {
    private let onTap: ([UInt8]) -> Void
    private let stack = UIStackView()
    private var cancellable: AnyCancellable?

    init(onTap: @escaping ([UInt8]) -> Void) {
        self.onTap = onTap
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear

        // iOS 18 compatible: blur effect instead of iOS 26 UIGlassEffect
        let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 18
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        addSubview(glass)

        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])

        rebuild(TerminalKeyStore.shared.keys)
        cancellable = TerminalKeyStore.shared.$keys.sink { [weak self] keys in self?.rebuild(keys) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild(_ keys: [TerminalKey]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for key in keys {
            stack.addArrangedSubview(makeButton(title: key.label) { [weak self] in self?.onTap(key.bytes) })
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 52) }

    private func makeButton(title: String, action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = UIColor.label
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
        let haptic = UIImpactFeedbackGenerator(style: .light)
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in
            haptic.impactOccurred()
            action()
        })
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        b.titleLabel?.numberOfLines = 1
        b.titleLabel?.lineBreakMode = .byClipping
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }
}

protocol TerminalKeyboardSelfManaging {}

final class ScrollableTerminalView: TerminalView, TerminalKeyboardSelfManaging {
    override func mouseModeChanged(source: Terminal) {
        // Intentionally empty: keep touch scrolling; don't enable mouse pan gesture.
    }

    private var kbObserving = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { addKeyboardObservers() } else { removeKeyboardObservers() }
    }

    private func addKeyboardObservers() {
        guard !kbObserving else { return }
        kbObserving = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(kbFrameWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(kbWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func removeKeyboardObservers() {
        guard kbObserving else { return }
        kbObserving = false
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func kbFrameWillChange(_ note: Notification) {
        guard isFirstResponder, let win = window,
              let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let h = win.bounds.height
        let docked = abs(end.maxY - h) < 1
        let hidden = end.minY >= h - 1
        guard docked || hidden else { return }
        if hidden { animateShift(0, note: note); return }
        let saved = transform
        transform = .identity
        let myMaxY = convert(bounds, to: nil).maxY
        transform = saved
        let overlap = max(0, myMaxY - end.minY)
        animateShift(overlap, note: note)
    }

    @objc private func kbWillHide(_ note: Notification) {
        animateShift(0, note: note)
    }

    private func animateShift(_ dy: CGFloat, note: Notification) {
        let dur = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let target: CGAffineTransform = dy > 0.5 ? CGAffineTransform(translationX: 0, y: -dy) : .identity
        UIView.animate(withDuration: dur, delay: 0, options: [.beginFromCurrentState]) {
            self.transform = target
        }
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        let maxOff = max(0, contentSize.height - bounds.height)
        let atBottom = contentOffset.y >= maxOff - 20
        if isTracking || isDragging || isDecelerating || !atBottom {
            return
        }
        super.scrolled(source: terminal, yDisp: yDisp)
    }
}

struct TerminalRepresentable: UIViewRepresentable {
    let controller: CCTerminalController

    func makeUIView(context: Context) -> UIView {
        let tv = ScrollableTerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.allowMouseReporting = false
        let termBg = UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)
        tv.isOpaque = true
        tv.backgroundColor = termBg
        tv.nativeBackgroundColor = termBg
        tv.inputAccessoryView = TerminalAccessoryBar(
            onTap: { [weak controller] bytes in controller?.sendInput(Data(bytes)) }
        )
        tv.keyboardDismissMode = .onDrag
        tv.alwaysBounceVertical = false
        tv.contentInsetAdjustmentBehavior = .never
        controller.terminalView = tv

        let wheelPan = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleWheelPan(_:)))
        wheelPan.delegate = context.coordinator
        tv.addGestureRecognizer(wheelPan)
        return tv
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
}

#else
struct TerminalRepresentable: NSViewRepresentable {
    let controller: CCTerminalController

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        let termBg = NSColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)
        tv.nativeBackgroundColor = termBg
        tv.layer?.backgroundColor = termBg.cgColor
        controller.terminalView = tv
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
}
#endif

final class Coordinator: NSObject, TerminalViewDelegate {
    let controller: CCTerminalController

    init(controller: CCTerminalController) {
        self.controller = controller
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor in
            controller.sendInput(Data(data))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            controller.attachOrResize(cols: newCols, rows: newRows)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if canImport(UIKit)
extension Coordinator: UIGestureRecognizerDelegate {
    @MainActor @objc func handleWheelPan(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let t = g.translation(in: g.view)
        guard abs(t.y) > abs(t.x) else { return }
        let step: CGFloat = 16
        guard abs(t.y) >= step else { return }
        let ticks = Int(t.y / step)
        controller.sendScrollWheel(up: ticks > 0, ticks: abs(ticks))
        g.setTranslation(CGPoint(x: t.x, y: t.y - CGFloat(ticks) * step), in: g.view)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif

// MARK: - Main panel view

struct CCTerminalPanelView: View {
    @Bindable var viewModel: ConversationViewModel

    private var currentSession: String {
        viewModel.selectedConversation?.ccBridgeSessionName ?? "mp-cc"
    }

    var body: some View {
        CCTerminalSessionView(sessionName: currentSession)
            .id(currentSession)
    }
}

private struct CCTerminalSessionView: View {
    let sessionName: String
    @StateObject private var controller: CCTerminalController
    @State private var refreshTrigger = 0

    init(sessionName: String) {
        self.sessionName = sessionName
        _controller = StateObject(wrappedValue: CCTerminalController(sessionName: sessionName))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(Theme.textMuted)
                    .font(.system(size: 11))
                Text("CC 终端")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(sessionName)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    refreshTrigger += 1
                    controller.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(red: 0.22, green: 0.94, blue: 0.49)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .sensoryFeedback(.impact, trigger: refreshTrigger)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.sidebarBg)

            if let error = controller.error {
                Text("⚠️ \(error)")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }

            TerminalRepresentable(controller: controller)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
        .background(Theme.sidebarBg)
        .onAppear {
            CCBridgeWebSocketClient.shared.spawnSession(sessionName) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak controller] in
                controller?.attachIfNotYet(cols: 80, rows: 24)
            }
        }
        .onDisappear { controller.detach() }
    }
}
