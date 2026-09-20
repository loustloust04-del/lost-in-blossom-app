import SwiftUI
import SwiftData

/// 群成员页：从聊天页右上角 ⋯ 菜单进入。查看成员（颜色/名字/模型），
/// 可编辑群名片/话痨度/模型/气泡色，能加人踢人——群是活的。
struct GroupMembersSheet: View {
    let conversation: Conversation

    private static let palette = ["#7C9CBF", "#C28E6B", "#8FA876", "#B07CA8", "#D9A05B", "#6BA8A0", "#A87C7C", "#8E8EC2"]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    @State private var members: [GroupParticipant] = []
    @State private var newMemberName: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach($members) { $member in
                    Section {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hexString: member.colorHex))
                                .frame(width: 14, height: 14)
                            Text(member.name)
                                .font(.headline)
                            Spacer()
                            if members.count > 1 {
                                Button {
                                    members.removeAll { $0.id == member.id }
                                } label: {
                                    Image(systemName: "person.badge.minus")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Picker("模型", selection: $member.model) {
                            ForEach(providerManager?.allModels ?? []) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                        TextField("一句话简介（群名片，给其他成员看的）", text: $member.intro)
                            .font(.callout)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("话痨度")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(member.talkativeness * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $member.talkativeness, in: 0...1, step: 0.05)
                        }
                        HStack(spacing: 10) {
                            ForEach(Self.palette, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hexString: hex))
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if member.colorHex == hex {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .onTapGesture { member.colorHex = hex }
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("新成员名字", text: $newMemberName)
                        Button {
                            addMember()
                        } label: {
                            Label("加入", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(newMemberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("新成员默认用第一个可用模型，加入后可在上面改模型/颜色/简介。")
                }
            }
            .navigationTitle("群成员（\(members.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear { members = conversation.participants }
        }
    }

    private func modelName(_ id: String) -> String {
        providerManager?.model(byId: id)?.name ?? id
    }

    private func addMember() {
        let name = newMemberName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !members.contains(where: { $0.name == name }) else { newMemberName = ""; return }
        let color = Self.palette[members.count % Self.palette.count]
        let modelId = providerManager?.allModels.first?.id ?? ""
        members.append(GroupParticipant(name: name, model: modelId, colorHex: color))
        newMemberName = ""
    }

    private func save() {
        conversation.participants = members
        try? modelContext.save()
        dismiss()
    }
}
