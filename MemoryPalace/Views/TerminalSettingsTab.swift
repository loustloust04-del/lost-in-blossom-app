import SwiftUI

/// CC 终端设置：自定义键盘工具条的按键（增删 / 排序 / 改名 / 恢复默认）。
/// 改完经 TerminalKeyStore 即时同步到工具条。
struct TerminalSettingsTab: View {
    @ObservedObject private var store = TerminalKeyStore.shared

    @State private var showAdd = false
    @State private var renameIndex: Int?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                ForEach(store.keys) { key in
                    Button {
                        if let i = store.keys.firstIndex(of: key) {
                            renameIndex = i
                            renameText = key.label
                        }
                    } label: {
                        HStack {
                            Text(key.label)
                                .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(byteHint(key.bytes))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                .onDelete { store.keys.remove(atOffsets: $0) }
                .onMove { store.keys.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("工具条按键（拖动排序，左滑删除，点击改名）")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("添加按键", systemImage: "plus")
                        .foregroundColor(Theme.branchIndicator)
                }
            }

            Section {
                Button(role: .destructive) {
                    store.resetToDefault()
                } label: {
                    Text("恢复默认")
                }
            }
        }
        .navigationTitle("终端")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        #endif
        .sheet(isPresented: $showAdd) {
            AddTerminalKeySheet { store.keys.append($0) }
        }
        .alert("改名", isPresented: Binding(get: { renameIndex != nil }, set: { if !$0 { renameIndex = nil } })) {
            TextField("显示文字", text: $renameText)
            Button("取消", role: .cancel) { renameIndex = nil }
            Button("保存") {
                if let i = renameIndex, store.keys.indices.contains(i), !renameText.isEmpty {
                    store.keys[i].label = renameText
                }
                renameIndex = nil
            }
        }
    }

    /// 把字节转成可读提示，例：[0x1b] → "ESC"，[0x03] → "^C"。
    private func byteHint(_ bytes: [UInt8]) -> String {
        if bytes.count == 1 {
            let b = bytes[0]
            switch b {
            case 0x1b: return "ESC"
            case 0x09: return "TAB"
            case 0x0d: return "↵"
            case 0x7f: return "DEL"
            case 0x20: return "SPC"
            case 0x01...0x1a: return "^\(Character(UnicodeScalar(b + 0x40)))"
            default: return String(format: "0x%02x", b)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - 添加按键 sheet（预设组合选择器）

private struct AddTerminalKeySheet: View {
    let onAdd: (TerminalKey) -> Void
    @Environment(\.dismiss) private var dismiss

    enum KeyType: String, CaseIterable { case control = "Ctrl 组合"; case special = "特殊键" }

    @State private var type: KeyType = .special
    @State private var letter = ""
    @State private var specialIndex = 0
    @State private var label = ""

    static let specials: [(label: String, bytes: [UInt8])] = [
        ("Esc",   [0x1b]),
        ("Tab",   [0x09]),
        ("⇧Tab",  [0x1b, 0x5b, 0x5a]),
        ("Enter", [0x0d]),
        ("↑",     [0x1b, 0x5b, 0x41]),
        ("↓",     [0x1b, 0x5b, 0x42]),
        ("←",     [0x1b, 0x5b, 0x44]),
        ("→",     [0x1b, 0x5b, 0x43]),
        ("Home",  [0x1b, 0x5b, 0x48]),
        ("End",   [0x1b, 0x5b, 0x46]),
        ("PgUp",  [0x1b, 0x5b, 0x35, 0x7e]),
        ("PgDn",  [0x1b, 0x5b, 0x36, 0x7e]),
        ("Del",   [0x7f]),
        ("Space", [0x20]),
        ("/",     [0x2f]),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $type) {
                    ForEach(KeyType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if type == .control {
                    HStack {
                        Text("Ctrl +")
                        TextField("字母 a–z", text: $letter)
                            .onChange(of: letter) { _, v in
                                letter = String(v.prefix(1)).lowercased()
                                label = defaultLabel()
                            }
                    }
                } else {
                    Picker("按键", selection: $specialIndex) {
                        ForEach(Self.specials.indices, id: \.self) { i in
                            Text(Self.specials[i].label).tag(i)
                        }
                    }
                    .onChange(of: specialIndex) { _, _ in label = defaultLabel() }
                }

                Section("显示文字") {
                    TextField("按钮上显示的字", text: $label)
                }
            }
            .navigationTitle("添加按键")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if let key = buildKey() { onAdd(key) }
                        dismiss()
                    }
                    .disabled(buildKey() == nil)
                }
            }
            .onAppear { if label.isEmpty { label = defaultLabel() } }
        }
    }

    private func defaultLabel() -> String {
        switch type {
        case .control:
            guard let c = letter.lowercased().first else { return "" }
            return "⌃\(String(c).uppercased())"
        case .special:
            return Self.specials[specialIndex].label
        }
    }

    private func buildKey() -> TerminalKey? {
        let finalLabel = label.isEmpty ? defaultLabel() : label
        switch type {
        case .control:
            guard let c = letter.lowercased().first, c.isLetter,
                  let a = c.asciiValue else { return nil }
            return TerminalKey(label: finalLabel, bytes: [a & 0x1f])
        case .special:
            return TerminalKey(label: finalLabel, bytes: Self.specials[specialIndex].bytes)
        }
    }
}
