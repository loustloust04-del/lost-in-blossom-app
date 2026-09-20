import SwiftUI

// MARK: - Character Card Editor

struct CharacterCardEditor: View {
    let card: CharacterCard
    let onSave: (CharacterCard) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var description: String
    @State private var personality: String
    @State private var scenario: String
    @State private var firstMes: String
    @State private var mesExample: String
    @State private var systemPrompt: String
    @State private var postHistoryInstructions: String
    @State private var creatorNotes: String

    init(card: CharacterCard, onSave: @escaping (CharacterCard) -> Void, onCancel: @escaping () -> Void) {
        self.card = card
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: card.name)
        _description = State(initialValue: card.description)
        _personality = State(initialValue: card.personality)
        _scenario = State(initialValue: card.scenario)
        _firstMes = State(initialValue: card.firstMes)
        _mesExample = State(initialValue: card.mesExample)
        _systemPrompt = State(initialValue: card.systemPrompt)
        _postHistoryInstructions = State(initialValue: card.postHistoryInstructions)
        _creatorNotes = State(initialValue: card.creatorNotes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    HStack {
                        Text("名称")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("名称", text: $name)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Theme.mainBg)

                Section("基本设定") {
                    editorField("模板描述", text: $description)
                    editorField("背景设定", text: $scenario)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("对话") {
                    editorField("第一条消息", text: $firstMes)
                    editorField("对话示例", text: $mesExample)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("Prompt") {
                    editorField("系统指令", text: $systemPrompt)
                    editorField("后置提醒", text: $postHistoryInstructions)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("备注") {
                    editorField("创作者注释", text: $creatorNotes)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("编辑自定义助手模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
    }

    @ViewBuilder
    private func editorField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
            TextEditor(text: text)
                .font(.system(size: Theme.F.body))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
        }
    }

    private func save() {
        var updated = card
        updated.name = name
        updated.description = description
        updated.personality = personality
        updated.scenario = scenario
        updated.firstMes = firstMes
        updated.mesExample = mesExample
        updated.systemPrompt = systemPrompt
        updated.postHistoryInstructions = postHistoryInstructions
        updated.creatorNotes = creatorNotes
        onSave(updated)
    }
}
