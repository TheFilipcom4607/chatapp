import SwiftUI

/// Glass capsule in the nav bar: current model + quick switch to favorites.
struct ModelPickerButton: View {
    let conversation: Conversation?
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog

    private var currentID: String { conversation?.modelID ?? app.draft.modelID }

    var body: some View {
        Menu {
            Section("Favorites") {
                ForEach(settings.favoriteModelIDs, id: \.self) { id in
                    Button {
                        select(id)
                    } label: {
                        if id == currentID {
                            Label(catalog.displayName(id), systemImage: "checkmark")
                        } else {
                            Text(catalog.displayName(id))
                        }
                    }
                }
            }
            Button { app.sheet = .modelPicker } label: { Label("Browse all models…", systemImage: "square.grid.2x2") }
            Section {
                if currentID == settings.defaultModelID {
                    Button {} label: { Label("Default for new chats", systemImage: "checkmark.seal") }
                        .disabled(true)
                } else {
                    Button {
                        settings.defaultModelID = currentID
                        Haptics.selection()
                        app.showToast("New chats will use \(catalog.displayName(currentID))")
                    } label: {
                        Label("Use \(catalog.displayName(currentID)) for new chats", systemImage: "checkmark.seal")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(catalog.displayName(currentID))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
        }
    }

    private func select(_ id: String) {
        Haptics.selection()
        if let conversation { conversation.modelID = id } else { app.draft.modelID = id }
    }
}

/// Full searchable OpenRouter catalog.
struct ModelBrowserView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case vision = "Vision", tools = "Tools", reasoning = "Reasoning", files = "PDFs", free = "Free"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case popular = "Popular", smartest = "Smartest", newest = "Newest", cheapest = "Cheapest", context = "Context"
        var id: String { rawValue }
    }

    var onPick: ((String) -> Void)? = nil
    /// The checkmarked model; defaults to the open chat's (or the draft's) model.
    var selectedID: String? = nil
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filters: Set<Filter> = []
    @State private var sort: Sort = .popular
    /// Filtered and sorted off the typing path, so the search field stays responsive.
    @State private var results: [ORModel] = []

    private var currentID: String { selectedID ?? app.currentConversation?.modelID ?? app.draft.modelID }

    private func computeResults() -> [ORModel] {
        var list = catalog.models
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.matches(search: q) }
        }
        for f in filters {
            switch f {
            case .vision: list = list.filter(\.supportsVision)
            case .tools: list = list.filter(\.supportsTools)
            case .reasoning: list = list.filter(\.supportsReasoning)
            case .files: list = list.filter(\.supportsFiles)
            case .free: list = list.filter(\.isFree)
            }
        }
        switch sort {
        case .popular: break
        case .smartest:
            // Unscored models go last, in API order.
            list = list.filter { $0.intelligence != nil }.sorted { $0.intelligence! > $1.intelligence! }
                + list.filter { $0.intelligence == nil }
        case .newest: list.sort { ($0.created ?? 0) > ($1.created ?? 0) }
        case .cheapest: list.sort { ($0.promptPricePerMillion ?? 999) + ($0.completionPricePerMillion ?? 999) < ($1.promptPricePerMillion ?? 999) + ($1.completionPricePerMillion ?? 999) }
        case .context: list.sort { ($0.contextLength ?? 0) > ($1.contextLength ?? 0) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                if catalog.models.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if results.isEmpty && !query.isEmpty {
                    Text("No models match “\(query)”")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                ForEach(results) { model in
                    ModelRow(model: model, isSelected: model.id == currentID,
                             isFavorite: settings.favoriteModelIDs.contains(model.id),
                             isDefault: model.id == settings.defaultModelID) {
                        settings.toggleFavorite(model.id)
                        Haptics.selection()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { pick(model.id) }
                    .contextMenu { modelActions(model) }
                    .swipeActions(edge: .leading) {
                        if model.id != settings.defaultModelID {
                            Button { makeDefault(model.id) } label: { Label("Default", systemImage: "checkmark.seal") }
                                .tint(.gray)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.03))
                }
            }
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .top, spacing: 0) { filterBar }
            .background(Theme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(catalog.models.count) models")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .refreshable { await catalog.refresh() }
            .task(id: query) {
                // Let typing settle before re-filtering a few hundred rows.
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 120_000_000) }
                guard !Task.isCancelled else { return }
                results = computeResults()
            }
            .onChange(of: filters) { _, _ in results = computeResults() }
            .onChange(of: sort) { _, _ in results = computeResults() }
            .onChange(of: catalog.models.count) { _, _ in results = computeResults() }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    let on = filters.contains(f)
                    Button {
                        if on { filters.remove(f) } else { filters.insert(f) }
                        Haptics.selection()
                    } label: {
                        Text(f.rawValue)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                            .background(Capsule().fill(on ? Theme.accent : Theme.fill))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func modelActions(_ model: ORModel) -> some View {
        if model.id != settings.defaultModelID {
            Button { makeDefault(model.id) } label: { Label("Set as default model", systemImage: "checkmark.seal") }
        }
        Button { settings.toggleFavorite(model.id) } label: {
            settings.favoriteModelIDs.contains(model.id)
                ? Label("Remove from favorites", systemImage: "star.slash")
                : Label("Add to favorites", systemImage: "star")
        }
        if model.intelligence != nil || model.coding != nil || model.agentic != nil {
            Section("Artificial Analysis") {
                if let v = model.intelligence { Text("Intelligence \(Int(v.rounded()))") }
                if let v = model.coding { Text("Coding \(Int(v.rounded()))") }
                if let v = model.agentic { Text("Agentic \(Int(v.rounded()))") }
            }
        }
    }

    private func pick(_ id: String) {
        Haptics.selection()
        if let onPick { onPick(id) }
        else if let c = app.currentConversation { c.modelID = id }
        else { app.draft.modelID = id }
        dismiss()
    }

    private func makeDefault(_ id: String) {
        settings.defaultModelID = id
        Haptics.selection()
    }
}

struct ModelRow: View {
    let model: ORModel
    let isSelected: Bool
    let isFavorite: Bool
    var isDefault = false
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(model.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isSelected { Image(systemName: "checkmark").foregroundStyle(Theme.textPrimary).font(.caption.weight(.bold)) }
                    if isDefault {
                        Text("DEFAULT")
                            .font(.readout(.caption2, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(model.providerName).font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    if model.isFree { Badge(text: "Free", color: .white) }
                    else {
                        Badge(text: "\(Money.perMillion(model.promptPricePerMillion)) / \(Money.perMillion(model.completionPricePerMillion))", color: .white)
                    }
                    if let score = model.intelligence {
                        Badge(text: "\(Int(score.rounded()))", color: .white, systemImage: "brain.head.profile")
                            .accessibilityLabel("Intelligence \(Int(score.rounded()))")
                    }
                    if let ctx = model.contextLength { Badge(text: TokenFormat.short(ctx), color: .white) }
                    if model.supportsVision { Image(systemName: "eye").font(.caption2) }
                    if model.supportsTools { Image(systemName: "wrench.and.screwdriver").font(.caption2) }
                    // The score badge already carries a brain; a second one would read as a duplicate.
                    if model.supportsReasoning, model.intelligence == nil { Image(systemName: "brain").font(.caption2) }
                    if model.supportsFiles { Image(systemName: "doc.richtext").font(.caption2) }
                }
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Theme.textPrimary : Theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.readout(.caption2, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }
}
