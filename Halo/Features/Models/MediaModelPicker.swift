import SwiftUI

/// A short menu of recommended image, video or voice models, plus "Browse all", which opens the
/// full list. `label` is what sits in the layout and shows the current model, so the menu doesn't
/// repeat it (a taller menu would push "Browse all" out of sight).
struct MediaModelMenu<MenuLabel: View>: View {
    let kind: MediaKind
    let selectedID: String
    var hasReferences = false
    let onPick: (String) -> Void
    @ViewBuilder let label: () -> MenuLabel

    @Environment(ModelCatalog.self) private var catalog
    @State private var showBrowser = false

    var body: some View {
        let models = catalog.mediaModels(kind, hasReferences: hasReferences)
        let picks = MediaPicks.compute(models)
        Menu {
            if !picks.isEmpty {
                Section("Recommended") {
                    ForEach(picks) { pick in
                        Button { choose(pick.id) } label: {
                            Text(pick.model.name)
                            Text(Self.subtitle(pick))
                            Image(systemName: pick.id == selectedID ? "checkmark" : pick.role.symbol)
                        }
                    }
                }
            }
            Section {
                Button { showBrowser = true } label: {
                    Label("Browse all \(models.count) models", systemImage: "square.grid.2x2")
                }
            }
        } label: {
            label()
        }
        .sheet(isPresented: $showBrowser) {
            MediaModelBrowser(kind: kind, selectedID: selectedID, hasReferences: hasReferences, onPick: onPick)
        }
        .task(id: kind) { if kind == .image { await catalog.loadAllImagePrices() } }
        .onAppear {
            // Screenshots of the image model's detail page, which the browser opens.
            if DemoSeeder.isDemo, DemoSeeder.screen == "mediadetail", kind == .image { showBrowser = true }
        }
    }

    private func choose(_ id: String) {
        Haptics.selection()
        onPick(id)
    }

    private static func subtitle(_ pick: MediaPick) -> String {
        let role = [pick.role.rawValue, pick.detail].compactMap { $0 }.joined(separator: ": ")
        return [role, pick.model.priceLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Every model of one kind: recommended picks first, then the rest, searchable, filterable and
/// sortable. Models that can't run here (a style model with no reference image, say) sink to the end.
/// A tap opens the model's details; a swipe or the menu picks it straight away.
struct MediaModelBrowser: View {
    enum Sort: String, CaseIterable, Identifiable {
        case rated = "Top rated", cheapest = "Cheapest", newest = "Newest", lab = "Lab"
        var id: String { rawValue }
    }

    private struct Row: Identifiable {
        let model: MediaModelSummary
        var role: MediaPickRole? = nil
        var detail: String? = nil
        var id: String { "\(role?.rawValue ?? "")\(model.id)" }
    }

    private struct Group: Identifiable {
        let title: String
        var footer: AttributedString? = nil
        let rows: [Row]
        /// Set on the collapsible "Older versions" group: how many it holds.
        var olderCount: Int? = nil
        var id: String { title }
    }

    let kind: MediaKind
    let selectedID: String
    var hasReferences = false
    let onPick: (String) -> Void

    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filters: Set<MediaFeature> = []
    @State private var sort: Sort = .rated
    @State private var showOlder = false
    @State private var path: [String] = []

    private var isBrowsing: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && filters.isEmpty }

    private func groups(_ all: [MediaModelSummary]) -> [Group] {
        var shown = all
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            shown = shown.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.lab.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
        }
        shown = shown.filter { filters.isSubset(of: $0.features) }
        // Older releases only make the list longer; searching still finds them.
        let older = isBrowsing ? MediaPicks.superseded(shown, keeping: selectedID) : []
        let usable = sorted(shown.filter { $0.isUsable && !older.contains($0.id) })
        let olderUsable = sorted(shown.filter { $0.isUsable && older.contains($0.id) })
        let unusable = shown.filter { !$0.isUsable }

        var result: [Group] = []
        let picks = MediaPicks.compute(all)
        if isBrowsing && !picks.isEmpty {
            result.append(Group(title: "Recommended", footer: footer(all), rows: picks.map { Row(model: $0.model, role: $0.role, detail: $0.detail) }))
        }
        if sort == .lab {
            let byLab = Dictionary(grouping: usable, by: \.lab)
            // Labs with a better-rated model first.
            let best = { (lab: String) in byLab[lab]?.compactMap(\.rating?.rank).min() ?? .max }
            for lab in byLab.keys.sorted(by: { best($0) != best($1) ? best($0) < best($1) : $0 < $1 }) {
                result.append(Group(title: lab, rows: byLab[lab]!.map { Row(model: $0) }))
            }
        } else if !usable.isEmpty {
            result.append(Group(title: isBrowsing ? "All models" : "\(usable.count) \(usable.count == 1 ? "match" : "matches")",
                                rows: usable.map { Row(model: $0) }))
        }
        if !olderUsable.isEmpty {
            // The button below says what it holds, so no header.
            result.append(Group(title: "", rows: showOlder ? olderUsable.map { Row(model: $0) } : [], olderCount: olderUsable.count))
        }
        if !unusable.isEmpty {
            result.append(Group(title: hasReferences ? "Can't use with your images" : "Can't use here", rows: unusable.map { Row(model: $0) }))
        }
        return result
    }

    private func sorted(_ list: [MediaModelSummary]) -> [MediaModelSummary] {
        let newest = { (a: MediaModelSummary, b: MediaModelSummary) in (a.created ?? 0) > (b.created ?? 0) }
        switch sort {
        case .rated, .lab:
            // Unrated models follow, newest first.
            return list.filter { $0.rating != nil }.sorted { $0.rating!.rank < $1.rating!.rank }
                + list.filter { $0.rating == nil }.sorted(by: newest)
        case .cheapest:
            return list.sorted { ($0.price ?? .infinity, $0.name) < ($1.price ?? .infinity, $1.name) }
        case .newest:
            return list.sorted(by: newest)
        }
    }

    private func footer(_ all: [MediaModelSummary]) -> AttributedString {
        let rated = all.filter { $0.rating != nil }.count
        let board: MediaModelResearch.Board = switch kind {
        case .image: hasReferences ? .imageEditing : .textToImage
        case .video: hasReferences ? .imageToVideo : .textToVideo
        case .speech: .textToSpeech
        }
        var text = "Ratings come from blind votes on the \(MediaModelResearch.source) \(board.rawValue) arena (\(catalog.arenaAsOf(board))), with live scores filling in newer models; \(rated) of \(all.count) are rated. Best value is the cheapest within \(Int(MediaPicks.valueWindow)) points of the best."
        switch kind {
        case .image: text += " Prices are for one image at about 1K, at the settings the votes used."
        case .video: text += " Prices are per second at 720p (or the nearest size offered), without audio."
        case .speech: text += " Prices are rough, for 1,000 characters (about a minute)."
        }
        if all.contains(where: \.priceIsLearned) {
            text += " A ~ price is what you paid last time, for a model with no listed price."
        }
        // Artificial Analysis asks for a link wherever its data shows.
        var result = AttributedString(text)
        if let range = result.range(of: MediaModelResearch.source) {
            result[range].link = MediaModelResearch.sourceURL
            result[range].underlineStyle = .single
        }
        return result
    }

    var body: some View {
        let all = catalog.mediaModels(kind, hasReferences: hasReferences)
        let groups = groups(all)
        NavigationStack(path: $path) {
            List {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.rows) { row in rowView(row) }
                        if let count = group.olderCount {
                            Button {
                                withAnimation(Motion.snappy) { showOlder.toggle() }
                            } label: {
                                HStack {
                                    Text(showOlder ? "Hide older versions" : "Show \(count) older \(count == 1 ? "version" : "versions")")
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .rotationEffect(.degrees(showOlder ? 180 : 0))
                                }
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            }
                            .listRowBackground(Color.white.opacity(0.03))
                        }
                    } header: {
                        // The chips ride in the first header, as in the chat model browser.
                        VStack(alignment: .leading, spacing: 12) {
                            if index == 0 && !kind.filters.isEmpty { filterBar }
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .textCase(nil)
                    } footer: {
                        if let footer = group.footer {
                            Text(footer).font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                if groups.isEmpty {
                    Section {
                        Text(all.isEmpty ? "Loading models…" : "No models match")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    } header: {
                        if !kind.filters.isEmpty { filterBar.textCase(nil) }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(all.count) models")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle(kind.title)
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
            .task { if kind == .image { await catalog.loadAllImagePrices() } }
            .navigationDestination(for: String.self) { id in
                MediaModelDetailView(kind: kind, modelID: id, isCurrent: id == selectedID, hasReferences: hasReferences) {
                    // The button has already buzzed.
                    onPick($0)
                    dismiss()
                }
            }
            .onAppear {
                if DemoSeeder.isDemo, DemoSeeder.screen == "mediadetail", path.isEmpty { path.append(selectedID) }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func rowView(_ row: Row) -> some View {
        MediaModelRow(model: row.model, role: row.role, roleDetail: row.detail, isSelected: row.model.id == selectedID, kind: kind)
            .contentShape(Rectangle())
            .onTapGesture { path.append(row.model.id) }
            .contextMenu { details(row.model) }
            .swipeActions(edge: .trailing) {
                if row.model.isUsable {
                    Button { pick(row.model.id) } label: { Label("Use", systemImage: "checkmark") }
                        .tint(Theme.fillStrong)
                }
            }
            .listRowBackground(Color.white.opacity(0.03))
    }

    private func pick(_ id: String) {
        Haptics.selection()
        onPick(id)
        dismiss()
    }

    @ViewBuilder
    private func details(_ model: MediaModelSummary) -> some View {
        if model.isUsable {
            Button { pick(model.id) } label: { Label("Use", systemImage: "checkmark") }
        }
        Button { path.append(model.id) } label: { Label("Details", systemImage: "info.circle") }
        if let r = model.rating {
            Section(r.source) {
                Text("\(r.board.capitalized) arena · Elo \(Int(r.elo.rounded()))")
                Text("#\(r.rank) of the rated models here")
            }
        }
        if let created = model.created {
            Text("Released \(Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .omitted))")
        }
        Text(model.id)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(kind.filters) { f in
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
        .padding(.horizontal, -20)
    }
}

struct MediaModelRow: View {
    let model: MediaModelSummary
    var role: MediaPickRole? = nil
    var roleDetail: String? = nil
    let isSelected: Bool
    let kind: MediaKind

    /// Features worth a mention on the row. Nearly every image model edits, and vector models say so
    /// in their note, so those two are left to the filters.
    private var highlights: [String] {
        MediaFeature.allCases.filter { ![.edits, .vector].contains($0) && model.features.contains($0) }.map(\.rawValue)
    }

    private var unitLabel: String {
        switch kind {
        case .image: return "per image"
        case .video: return "per second"
        case .speech: return "per 1K chars"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let role {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: role.symbol)
                        Text([role.rawValue, roleDetail].compactMap { $0 }.joined(separator: ": "))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(model.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if model.isNew() {
                        Text("NEW")
                            .font(.readout(.caption2, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                    if isSelected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    }
                }
                Text([model.lab, model.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                if let reason = model.unavailableReason {
                    HStack(spacing: 4) {
                        Image(systemName: "nosign")
                        Text(reason)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                } else if model.rating != nil || !highlights.isEmpty {
                    HStack(spacing: 8) {
                        if let r = model.rating {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill").imageScale(.small)
                                Text("#\(r.rank)")
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Rated number \(r.rank)")
                        }
                        if !highlights.isEmpty {
                            Text(highlights.joined(separator: " · "))
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if let price = model.price {
                VStack(alignment: .trailing, spacing: 2) {
                    Text((model.priceIsLearned && price > 0 ? "~" : "") + MediaModelSummary.formatPrice(price))
                        .font(.readout(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if price > 0 {
                        Text(model.priceIsLearned ? "last used" : unitLabel)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            } else if model.priceUnlisted {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("–")
                        .font(.readout(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("no price listed")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(model.isUsable ? 1 : 0.45)
    }
}
