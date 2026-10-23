import SwiftUI

/// Glass capsule in the nav bar: current model + quick switch to favorites.
struct ModelPickerButton: View {
    let conversation: Conversation?
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog

    private var currentID: String { conversation?.modelID ?? app.draft.modelID }
    /// The tiers this model sells, when it sells more than Standard.
    private var tiers: [ServiceTier: TierPrice]? {
        guard let t = catalog.tiers(currentID), t.count > 1 else { return nil }
        return t
    }
    /// The chat's tier as it will actually be served: one the model doesn't offer runs as Standard.
    private var tier: ServiceTier {
        let chosen = settings.serviceTier(conversation.map(\.serviceTier) ?? app.draft.serviceTier)
        return tiers?[chosen] != nil ? chosen : .standard
    }

    var body: some View {
        Menu {
            if let tiers {
                // A palette: one row of tier icons, the current one highlighted. The menu shows the
                // picker's title as its header, so that's where the tier and its price go.
                Section {
                    Picker(tier.menuTitle(tiers[tier]),
                           selection: Binding(get: { tier }, set: { setTier($0) })) {
                        ForEach(ServiceTier.allCases.filter { tiers[$0] != nil }) { t in
                            Label(t.title, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.palette)
                }
            }
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
                // Models sold in tiers keep a fixed slot for the tier's icon, so switching tiers with
                // the menu open never changes the label's width (the menu would slide to follow it).
                if tiers != nil {
                    Image(systemName: tier.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tier == .standard ? Theme.textTertiary : Theme.textSecondary)
                        .frame(width: 18)
                        .contentTransition(.symbolEffect(.replace))
                }
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
        .accessibilityValue(tier == .standard ? "" : tier.title)
        .task(id: currentID) { await catalog.loadTiers(currentID) }
    }

    private func setTier(_ value: ServiceTier) {
        Haptics.selection()
        if let conversation { conversation.serviceTier = value.rawValue } else { app.draft.serviceTier = value.rawValue }
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
        case popular = "Popular", smartest = "Smartest", coding = "Coding", lab = "Lab", newest = "Newest", cheapest = "Cheapest", context = "Context"
        var id: String { rawValue }
    }
    /// A run of rows under one header; `title` is nil when the list isn't grouped.
    struct Group: Identifiable {
        let title: String?
        let models: [ORModel]
        var id: String { title ?? "" }
    }
    /// The big labs first when grouping by lab (OpenRouter id prefixes); the rest alphabetically.
    private static let labOrder = ["anthropic", "openai", "google", "x-ai", "deepseek", "meta-llama", "mistralai",
                                   "qwen", "moonshotai", "z-ai", "minimax", "nvidia", "microsoft", "amazon", "cohere"]

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
    /// Measured from your own replies, by model ID.
    @State private var speeds: [String: ModelSpeed] = [:]

    private var groups: [Group] {
        guard sort == .lab else { return [Group(title: nil, models: results)] }
        let byLab = Dictionary(grouping: results) { $0.id.split(separator: "/").first.map(String.init) ?? "" }
        let rank = { (lab: String) in Self.labOrder.firstIndex(of: lab) ?? Self.labOrder.count }
        return byLab.keys
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1 }
            .map { lab in
                let models = byLab[lab] ?? []
                return Group(title: models.first?.providerName ?? lab, models: models)
            }
    }

    private var currentID: String { selectedID ?? app.currentConversation?.modelID ?? app.draft.modelID }
    /// Prices are shown for the open chat's tier (or the default tier when picking the default model).
    private var tier: ServiceTier {
        if onPick != nil { return settings.serviceTier(nil) }
        return settings.serviceTier(app.currentConversation.map(\.serviceTier) ?? app.draft.serviceTier)
    }

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
        case .coding:
            list = list.filter { $0.coding != nil }.sorted { $0.coding! > $1.coding! }
                + list.filter { $0.coding == nil }
        case .newest, .lab: list.sort { ($0.created ?? 0) > ($1.created ?? 0) }
        // Unknown prices, routers' included, count as 999 and land last.
        case .cheapest: list.sort { ($0.promptPricePerMillion ?? 999) + ($0.completionPricePerMillion ?? 999) < ($1.promptPricePerMillion ?? 999) + ($1.completionPricePerMillion ?? 999) }
        case .context: list.sort { ($0.contextLength ?? 0) > ($1.contextLength ?? 0) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        if index == 0 && catalog.models.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                        } else if index == 0 && results.isEmpty && !query.isEmpty {
                            Text("No models match “\(query)”")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(group.models) { model in row(model) }
                    } header: {
                        // The chips ride in the first header: an inset above the list, or a bar
                        // above it, glitches when the search bar takes over the navigation bar.
                        VStack(alignment: .leading, spacing: 12) {
                            if index == 0 { filterBar }
                            if let title = group.title {
                                Text(title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await catalog.refresh() }
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
            .task(id: query) {
                // Let typing settle before re-filtering a few hundred rows.
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 120_000_000) }
                guard !Task.isCancelled else { return }
                results = computeResults()
            }
            .task { speeds = ModelSpeed.load(from: app.context) }
            .onChange(of: filters) { _, _ in results = computeResults() }
            .onChange(of: sort) { _, _ in results = computeResults() }
            .onChange(of: catalog.models.count) { _, _ in results = computeResults() }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func row(_ model: ORModel) -> some View {
        ModelRow(model: model, isSelected: model.id == currentID,
                 isFavorite: settings.favoriteModelIDs.contains(model.id),
                 isDefault: model.id == settings.defaultModelID, speed: speeds[model.id],
                 tier: tier, tiers: catalog.tiers(model.id), showsCoding: sort == .coding) {
            settings.toggleFavorite(model.id)
            Haptics.selection()
        }
        .task { if !model.isFree { await catalog.loadTiers(model.id) } }
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
            .padding(.vertical, 2)
        }
        // Scroll edge to edge, past the header's inset.
        .padding(.horizontal, -20)
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
        if let speed = speeds[model.id] {
            Section("Your replies") {
                Text("\(Int(speed.tokensPerSecond.rounded())) tokens per second")
                Text("\(ModelSpeed.seconds(speed.timeToFirstToken)) to first token")
                Text("Median of \(speed.replies) \(speed.replies == 1 ? "reply" : "replies")")
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
    var speed: ModelSpeed? = nil
    /// The tier you'd use: its price is shown when the model sells it, else the Standard price.
    var tier: ServiceTier = .standard
    var tiers: [ServiceTier: TierPrice]? = nil
    /// Show the coding score instead of intelligence, when the list is ranked by it.
    var showsCoding = false
    let toggleFavorite: () -> Void

    private var tierPrice: TierPrice? { tier == .standard ? nil : tiers?[tier] }

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
                Text(speed.map { "\(model.providerName) · \($0.summary)" } ?? model.providerName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if model.isFree { Badge(text: "Free", color: .white) }
                    else if model.hasVariablePrice { Badge(text: "Varies", color: .white) }
                    else if let tierPrice {
                        Badge(text: tierPrice.label, color: .white, systemImage: tier.symbol)
                            .accessibilityLabel("\(tier.title) price \(tierPrice.label)")
                    } else {
                        Badge(text: "\(Money.perMillion(model.promptPricePerMillion)) / \(Money.perMillion(model.completionPricePerMillion))", color: .white)
                    }
                    if showsCoding, let score = model.coding {
                        Badge(text: "\(Int(score.rounded()))", color: .white, systemImage: "chevron.left.forwardslash.chevron.right")
                            .accessibilityLabel("Coding \(Int(score.rounded()))")
                    } else if !showsCoding, let score = model.intelligence {
                        Badge(text: "\(Int(score.rounded()))", color: .white, systemImage: "brain.head.profile")
                            .accessibilityLabel("Intelligence \(Int(score.rounded()))")
                    }
                    if let ctx = model.contextLength { Badge(text: TokenFormat.short(ctx), color: .white) }
                    if model.supportsVision { Image(systemName: "eye").font(.caption2) }
                    if model.supportsTools { Image(systemName: "wrench.and.screwdriver").font(.caption2) }
                    // The score badge already carries a brain; a second one would read as a duplicate.
                    if model.supportsReasoning, showsCoding || model.intelligence == nil { Image(systemName: "brain").font(.caption2) }
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
