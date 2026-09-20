import SwiftUI

// MARK: - Card Library Panel (右栏卡库 Tab)

struct CardLibraryPanelView: View {
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var expandedCardId: String?
    @State private var deletingCard: CharacterCard?
    @State private var editingCard: CharacterCard?
    @State private var highlightedId: String? = nil

    private var cards: [CharacterCard] {
        cardManager?.cards ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if cards.isEmpty {
                Section {
                    emptyState
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(cards) { card in
                        cardRow(card)
                            .id(card.id)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(highlightedId == card.id ? Theme.branchIndicator.opacity(0.3) : Color.clear)
                                    .animation(.easeInOut(duration: 0.35), value: highlightedId)
                            )
                    }
                } header: {
                    HStack {
                        Text("自定义助手模板库")
                        Spacer()
                        Text("\(cards.count) 张")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                        Button { showFileImporter = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Theme.branchIndicator.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .sheet(isPresented: $showFileImporter) {
            DocumentPickerView(contentTypes: [.json, .png]) { urls in
                handleImport(.success(urls))
            } onCancel: {}
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(
            "删除自定义助手模板",
            isPresented: Binding(
                get: { deletingCard != nil },
                set: { if !$0 { deletingCard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let card = deletingCard {
                    cardManager?.delete(card)
                }
                deletingCard = nil
            }
            Button("取消", role: .cancel) { deletingCard = nil }
        } message: {
            if let card = deletingCard {
                Text("确定要从卡库删除「\(card.name)」吗？已创建的楼层不受影响。")
            }
        }
        .sheet(item: $editingCard) { card in
            CharacterCardEditor(card: card) { updated in
                cardManager?.update(updated)
                editingCard = nil
            } onCancel: {
                editingCard = nil
            }
        }
        .onAppear { consumeTarget(navigator?.pendingTarget, proxy: proxy) }
        .onChange(of: navigator?.pendingTarget) { _, target in
            consumeTarget(target, proxy: proxy)
        }
        } // end ScrollViewReader
    }

    private func consumeTarget(_ target: RightPanelNavigator.Target?, proxy: ScrollViewProxy) {
        guard let t = target, t.tool == "cardLibrary" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(t.id, anchor: .center)
            }
        }
        highlightedId = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlightedId == t.id { highlightedId = nil }
        }
        navigator?.pendingTarget = nil
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 24))
                .foregroundColor(Theme.textMuted.opacity(0.4))
            Text("卡库是空的")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 10))
                    Text("导入自定义助手模板")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                }
                .foregroundColor(Theme.branchIndicator)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.branchIndicator.opacity(0.12)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Card Row

    private func cardRow(_ card: CharacterCard) -> some View {
        let isExpanded = expandedCardId == card.id

        return VStack(alignment: .leading, spacing: 0) {
            // 主行
            HStack(spacing: 8) {
                if let imgData = card.imageData, let coverImage = platformImage(from: imgData) {
                    coverImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.branchIndicator.opacity(0.15))
                        .frame(width: 32, height: 32)
                        .overlay(Text("🎭").font(.system(size: 16)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if card.hasWorldBook {
                            metaLabel("📖 \(card.worldBookEntryCount)条")
                        }
                        if !card.alternateGreetings.isEmpty {
                            metaLabel("💬 \(card.alternateGreetings.count + 1)")
                        }
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedCardId = isExpanded ? nil : card.id
                }
            }

            // 展开详情
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !card.description.isEmpty {
                        Text(String(card.description.prefix(200)) + (card.description.count > 200 ? "…" : ""))
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(5)
                    }

                    if !card.creatorNotes.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 8))
                            Text(card.creatorNotes)
                                .font(.system(size: Theme.F.caption))
                                .lineLimit(3)
                        }
                        .foregroundColor(Theme.textMuted)
                    }

                    HStack(spacing: 8) {
                        Button {
                            createFloor(from: card)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus.square")
                                    .font(.system(size: 9))
                                Text("创建楼层")
                                    .font(.system(size: Theme.F.secondary, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.branchIndicator))
                        }
                        .buttonStyle(.plain)

                        Button { editingCard = card } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "pencil").font(.system(size: 9))
                                Text("编辑").font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(Theme.branchIndicator)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                        }
                        .buttonStyle(.plain)

                        Button { deletingCard = card } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash").font(.system(size: 9))
                                Text("删除").font(.system(size: Theme.F.secondary))
                            }
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.red.opacity(0.08)))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - Helpers

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try cardManager?.importFromFile(url: url)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func createFloor(from card: CharacterCard) {
        guard let profileManager = profileManager else { return }
        cardManager?.createFloor(from: card, profileManager: profileManager)
    }

    private func platformImage(from data: Data) -> Image? {
        guard let img = UIImage(data: data) else { return nil }
        return Image(uiImage: img)
    }
}
