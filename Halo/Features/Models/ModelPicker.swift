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
        case popular = "Popular", newest = "Newest", cheapest = "Cheapest", context = "Context"
        var id: String { rawValue }
    }

    var onPick: ((String) -> Void)? = nil
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filters: Set<Filter> = []
    @State private var sort: Sort = .popular

    private var currentID: String { app.currentConversation?.modelID ?? app.draft.modelID }

    private var results: [ORModel] {
        var list = catalog.models
        if !query.isEmpty {
            let q = query.lowercased()
            list = list.filter { $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }
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
        case .newest: list.sort { ($0.created ?? 0) > ($1.created ?? 0) }
        case .cheapest: list.sort { ($0.promptPricePerMillion ?? 999) + ($0.completionPricePerMillion ?? 999) < ($1.promptPricePerMillion ?? 999) + ($1.completionPricePerMillion ?? 999) }
        case .context: list.sort { ($0.contextLength ?? 0) > ($1.contextLength ?? 0) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                                        .foregroundStyle(on ? Color.white : Theme.textSecondary)
                                        .glassEffect(on ? .regular.tint(Theme.violet.opacity(0.5)).interactive() : .regular.interactive(), in: .capsule)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                if catalog.models.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
                ForEach(results) { model in
                    ModelRow(model: model, isSelected: model.id == currentID, isFavorite: settings.favoriteModelIDs.contains(model.id)) {
                        settings.toggleFavorite(model.id)
                        Haptics.selection()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.selection()
                        if let onPick { onPick(model.id) }
                        else if let c = app.currentConversation { c.modelID = model.id }
                        else { app.draft.modelID = model.id }
                        dismiss()
                    }
                    .listRowBackground(Color.white.opacity(0.03))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(catalog.models.count) models")
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
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }
}

struct ModelRow: View {
    let model: ORModel
    let isSelected: Bool
    let isFavorite: Bool
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(model.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal).font(.caption) }
                }
                Text(model.providerName).font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    if model.isFree { Badge(text: "Free", color: Theme.teal) }
                    else {
                        Badge(text: "\(Money.perMillion(model.promptPricePerMillion)) / \(Money.perMillion(model.completionPricePerMillion))", color: .white)
                    }
                    if let ctx = model.contextLength { Badge(text: TokenFormat.short(ctx), color: .white) }
                    if model.supportsVision { Image(systemName: "eye").font(.caption2) }
                    if model.supportsTools { Image(systemName: "wrench.and.screwdriver").font(.caption2) }
                    if model.supportsReasoning { Image(systemName: "brain").font(.caption2) }
                    if model.supportsFiles { Image(systemName: "doc.richtext").font(.caption2) }
                }
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Theme.textTertiary)
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
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}
