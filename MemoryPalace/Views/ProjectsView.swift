import SwiftUI
import SwiftData

// MARK: - Project Draft (value type for editor)

struct ProjectDraft {
    var id: String = UUID().uuidString
    var name: String = ""
    var desc: String = ""
    var icon: String = "folder"
    var colorHex: String = "6B7CB3"
    var instructions: String = ""

    init() {}

    init(from project: Project) {
        id = project.id
        name = project.name
        desc = project.desc
        icon = project.icon
        colorHex = project.colorHex
        instructions = project.instructions
    }
}

// MARK: - Projects View

struct ProjectsView: View {
    let profileId: String
    var viewModel: ConversationViewModel

    @Environment(\.modelContext) private var modelContext
    @Query private var projects: [Project]

    @State private var selectedProjectId: String? = nil
    @State private var showEditor = false
    @State private var editorDraft = ProjectDraft()
    @State private var editingExistingId: String? = nil

    init(profileId: String, viewModel: ConversationViewModel) {
        self.profileId = profileId
        self.viewModel = viewModel
        let pid = profileId
        _projects = Query(
            filter: #Predicate<Project> { p in p.profileId == pid && p.archivedAt == nil },
            sort: \Project.createdAt
        )
    }

    private var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let project = selectedProject {
                ProjectDetailView(
                    project: project,
                    profileId: profileId,
                    viewModel: viewModel,
                    onBack: { selectedProjectId = nil },
                    onEdit: {
                        editorDraft = ProjectDraft(from: project)
                        editingExistingId = project.id
                        showEditor = true
                    }
                )
            } else {
                projectListView
            }
        }
        .sheet(isPresented: $showEditor) {
            ProjectEditorSheet(
                draft: $editorDraft,
                isNew: editingExistingId == nil,
                onSave: { saveEditor() },
                onCancel: { showEditor = false }
            )
        }
    }

    private var projectListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    editorDraft = ProjectDraft()
                    editingExistingId = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 30))
                        .foregroundColor(Theme.textMuted.opacity(0.3))
                    Text("还没有项目")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                    Text("点击 + 新建")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projects) { project in
                            ProjectRowView(project: project)
                                .onTapGesture { selectedProjectId = project.id }
                                .contextMenu {
                                    Button {
                                        editorDraft = ProjectDraft(from: project)
                                        editingExistingId = project.id
                                        showEditor = true
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        ProjectStore.delete(project, context: modelContext)
                                    } label: {
                                        Label("删除项目", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
        }
    }

    private func saveEditor() {
        let trimmedName = editorDraft.name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        if let existingId = editingExistingId,
           let project = projects.first(where: { $0.id == existingId }) {
            project.name = trimmedName
            project.desc = editorDraft.desc
            project.icon = editorDraft.icon
            project.colorHex = editorDraft.colorHex
            project.instructions = editorDraft.instructions
        } else {
            let project = Project(
                id: editorDraft.id,
                name: trimmedName,
                desc: editorDraft.desc,
                icon: editorDraft.icon,
                colorHex: editorDraft.colorHex,
                instructions: editorDraft.instructions,
                profileId: profileId
            )
            ProjectStore.insert(project, context: modelContext)
        }
        showEditor = false
    }
}

// MARK: - Project Row

struct ProjectRowView: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(hexString: project.colorHex))
                    .frame(width: 28, height: 28)
                Image(systemName: project.icon)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: Theme.F.label, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if !project.desc.isEmpty {
                    Text(project.desc)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - Project Detail View

struct ProjectDetailView: View {
    let project: Project
    let profileId: String
    var viewModel: ConversationViewModel
    let onBack: () -> Void
    let onEdit: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var conversations: [Conversation]

    init(project: Project, profileId: String, viewModel: ConversationViewModel, onBack: @escaping () -> Void, onEdit: @escaping () -> Void) {
        self.project = project
        self.profileId = profileId
        self.viewModel = viewModel
        self.onBack = onBack
        self.onEdit = onEdit
        let projectId = project.id
        let pid = profileId
        let optProjectId: String? = projectId
        _conversations = Query(
            filter: #Predicate<Conversation> { conv in
                conv.projectId == optProjectId && conv.profileId == pid && !conv.isTrashed
            },
            sort: \Conversation.updateTime,
            order: .reverse
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .medium))
                        Text("Projects")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)

                Spacer()

                Button { onEdit() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)

                Button {
                    let conv = viewModel.createNewConversation(
                        title: "新对话",
                        profileId: profileId,
                        context: modelContext,
                        projectId: project.id
                    )
                    viewModel.loadConversation(conv, context: modelContext)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(hexString: project.colorHex))
                        .frame(width: 22, height: 22)
                    Image(systemName: project.icon)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                }
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider().opacity(0.2)

            if conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 26))
                        .foregroundColor(Theme.textMuted.opacity(0.3))
                    Text("还没有对话")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                    Text("点击右上角铅笔新建")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 4)
                        ForEach(conversations) { conversation in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title)
                                        .font(.system(size: Theme.F.label, weight: .medium))
                                        .foregroundColor(viewModel.selectedConversation?.id == conversation.id ? Theme.branchIndicator : Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(conversation.updateTime, style: .relative)
                                        .font(.system(size: Theme.F.caption))
                                        .foregroundColor(Theme.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.loadConversation(conversation, context: modelContext)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    conversation.projectId = nil
                                } label: {
                                    Label("移出项目", systemImage: "folder.badge.minus")
                                }
                            }
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
        }
    }
}

// MARK: - Project Editor Sheet

struct ProjectEditorSheet: View {
    @Binding var draft: ProjectDraft
    let isNew: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    private let icons = ["folder", "briefcase", "book.closed", "lightbulb", "star", "heart", "flag", "tag", "terminal", "cpu"]
    private let colors = ["6B7CB3", "5A9A6B", "D4845A", "8B6BA8", "B8658A", "B05A5A", "4A8B8B", "7A7A8B"]

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
                Spacer()
                Text(isNew ? "新建项目" : "编辑项目")
                    .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("保存") { onSave() }
                    .buttonStyle(.plain)
                    .foregroundColor(canSave ? .white : Theme.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(canSave ? Theme.branchIndicator : Theme.textMuted.opacity(0.3)))
                    .disabled(!canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorField("项目名称") {
                        TextField("工作、学习…", text: $draft.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                    }

                    editorField("描述（可选）") {
                        TextField("简短描述", text: $draft.desc)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.body))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                    }

                    editorField("颜色") {
                        HStack(spacing: 10) {
                            ForEach(colors, id: \.self) { hex in
                                ZStack {
                                    Circle()
                                        .fill(Color(hexString: hex))
                                        .frame(width: 26, height: 26)
                                    if draft.colorHex == hex {
                                        Circle()
                                            .stroke(Color.white, lineWidth: 2)
                                            .frame(width: 26, height: 26)
                                    }
                                }
                                .onTapGesture { draft.colorHex = hex }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    editorField("图标") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 5), spacing: 8) {
                            ForEach(icons, id: \.self) { icon in
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(draft.icon == icon ? Color(hexString: draft.colorHex) : Theme.mainBg.opacity(0.8))
                                        .frame(width: 40, height: 40)
                                    Image(systemName: icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(draft.icon == icon ? .white : Theme.textMuted)
                                }
                                .onTapGesture { draft.icon = icon }
                            }
                        }
                    }

                    editorField("项目指令（注入每条对话的 system prompt）") {
                        TextEditor(text: $draft.instructions)
                            .font(.system(size: Theme.F.body))
                            .frame(minHeight: 100)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg.opacity(0.8)))
                            .scrollContentBackground(.hidden)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: 500, minHeight: 460)
        .frame(maxWidth: .infinity)
        .background(Theme.sidebarBg)
    }

    private func editorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
            content()
        }
    }
}

// MARK: - Project Picker Sheet (for "Move to Project" from conversation list)

struct ProjectPickerSheet: View {
    let conversation: Conversation
    let profileId: String

    @Environment(\.dismiss) private var dismiss
    @Query private var projects: [Project]

    init(conversation: Conversation, profileId: String) {
        self.conversation = conversation
        self.profileId = profileId
        let pid = profileId
        _projects = Query(
            filter: #Predicate<Project> { p in p.profileId == pid && p.archivedAt == nil },
            sort: \Project.createdAt
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("移动到项目")
                    .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.2)

            ScrollView {
                VStack(spacing: 0) {
                    // "No project" option
                    pickerRow(
                        icon: "xmark",
                        color: Theme.textMuted.opacity(0.2),
                        iconColor: Theme.textMuted,
                        title: "不属于任何项目",
                        isSelected: conversation.projectId == nil
                    ) {
                        conversation.projectId = nil
                        dismiss()
                    }

                    ForEach(projects) { project in
                        pickerRow(
                            icon: project.icon,
                            color: Color(hexString: project.colorHex),
                            iconColor: .white,
                            title: project.name,
                            isSelected: conversation.projectId == project.id
                        ) {
                            conversation.projectId = project.id
                            dismiss()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.sidebarBg)
        .presentationDetents([.medium, .large])
    }

    private func pickerRow(icon: String, color: Color, iconColor: Color, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
            }
            Text(title)
                .font(.system(size: Theme.F.label))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.branchIndicator)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}
