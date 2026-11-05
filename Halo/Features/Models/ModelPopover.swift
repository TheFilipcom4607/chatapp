import SwiftUI

#if os(macOS)
/// The Mac's model picker, opened from the toolbar's model button (or ⌘K): a search field, the
/// chat's tier, and one line per model with price, IQ and measured speed in aligned columns.
/// Typing searches the whole catalog; arrow keys move, Return picks, Escape closes.
struct ModelPopover: View {
    let currentID: String
    let chosenTier: ServiceTier
    /// The current model's tiers, when it sells more than Standard.
    let tiers: [ServiceTier: TierPrice]?
    let tier: ServiceTier
    /// Favorites, Trying out and Recent, the empty ones already left out.
    let sections: [(String, [String])]
    let speeds: [String: ModelSpeed]
    let newCount: Int
    let select: (String) -> Void
    let setTier: (ServiceTier) -> Void
    let open: (SheetRoute) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    private static let width: CGFloat = 470
    private static let priceWidth: CGFloat = 112
    private static let iqWidth: CGFloat = 34
    private static let speedWidth: CGFloat = 48
    private static let resultLimit = 60

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What the list shows: the sections, or a search of the whole catalog with favorites first.
    private var shown: [(String, [String])] {
        guard isSearching else { return sections }
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = catalog.models.filter { $0.matches(search: q) }.map(\.id)
        let favorites = hits.filter { settings.favoriteModelIDs.contains($0) }
        let rest = hits.filter { !settings.favoriteModelIDs.contains($0) }
        return [("Results", Array((favorites + rest).prefix(Self.resultLimit)))]
    }

    private var order: [String] { shown.flatMap(\.1) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if let tiers { tierBar(tiers); Divider() }
            list
            Divider()
            footer
        }
        .frame(width: Self.width)
        .onAppear {
            highlighted = currentID
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            highlighted = isSearching ? order.first : (order.contains(currentID) ? currentID : order.first)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let highlighted { select(highlighted) } }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            if isSearching {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Clear")
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The chat's tier, for the current model; switching keeps the popover open.
    private func tierBar(_ tiers: [ServiceTier: TierPrice]) -> some View {
        HStack(spacing: 8) {
            Picker("Tier", selection: Binding(get: { tier }, set: setTier)) {
                ForEach(ServiceTier.allCases.filter { tiers[$0] != nil }) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            Text(tier.menuTitle(tiers[tier]).replacingOccurrences(of: "\(tier.title) · ", with: ""))
                .font(.readout(.caption))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack builds rows outside this body, so they missed highlight
                // changes. At most `resultLimit` rows, cheap to build at once.
                VStack(alignment: .leading, spacing: 0) {
                    if order.isEmpty {
                        Text(isSearching ? "No models match “\(query)”" : "No favorites yet")
                            .font(.callout)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.0) { index, section in
                        header(section.0, columns: index == 0)
                        ForEach(section.1, id: \.self) { row($0) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(height: listHeight)
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
        }
    }

    /// Tall enough for the usual favorites without a scroll, capped for long lists and searches.
    private var listHeight: CGFloat {
        let rows = CGFloat(order.count), headers = CGFloat(shown.count)
        return min(440, max(80, rows * 28 + headers * 26 + 12))
    }

    /// A section title; the first one also names the columns.
    private func header(_ title: String, columns: Bool) -> some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            if columns {
                Group {
                    Text("$/M in/out").frame(width: Self.priceWidth, alignment: .trailing)
                    Text("IQ").frame(width: Self.iqWidth, alignment: .trailing)
                    Text("tok/s").frame(width: Self.speedWidth, alignment: .trailing)
                }
                .font(.readout(.caption2))
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func row(_ id: String) -> some View {
        let model = catalog.model(id)
        let full = catalog.displayName(id)
        let split = ModelRanking.splitReleaseStamp(full)
        let price = model.flatMap { ModelPickerButton.price(id, model: $0, chosen: chosenTier, catalog: catalog, settings: settings) }
        let isCurrent = id == currentID
        return Button { select(id) } label: {
            HStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 22)
                Text(split?.name ?? full)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let stamp = split?.stamp {
                    Text(" " + stamp).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Group {
                    HStack(spacing: 3) {
                        if let symbol = price?.tier.symbol {
                            Image(systemName: symbol).font(.caption2).help("\(price!.tier.title) price")
                        }
                        Text(price?.text ?? "–")
                    }
                    .frame(width: Self.priceWidth, alignment: .trailing)
                    Text(model?.intelligence.map { "\(Int($0.rounded()))" } ?? "–")
                        .frame(width: Self.iqWidth, alignment: .trailing)
                    Text(speeds[id].map { "\(Int($0.tokensPerSecond.rounded()))" } ?? "–")
                        .frame(width: Self.speedWidth, alignment: .trailing)
                }
                .font(.readout(.caption))
                .foregroundStyle(Theme.textSecondary)
            }
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.trailing, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.textPrimary.opacity(highlighted == id ? 0.1 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { highlighted = id } }
        .help(tooltip(id))
        .id(id)
    }

    /// The model's id, and the provider it's pinned to, if any.
    private func tooltip(_ id: String) -> String {
        var lines = [id]
        if let slug = settings.modelRouting[id]?.pinned.first,
           let provider = catalog.endpoints[id]?.first(where: { $0.slug == slug })?.name {
            lines.append("Pinned to \(provider)")
        }
        return lines.joined(separator: "\n")
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button { open(.modelPicker) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                    Text("All models…")
                    if newCount > 0 {
                        Text("\(newCount) new")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.corona))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer()
            Button { open(.favorites) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "star")
                    Text("Edit favorites…")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .hoverHighlight(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .font(.callout)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func move(_ step: Int) {
        let ids = order
        guard !ids.isEmpty else { return }
        guard let current = highlighted, let index = ids.firstIndex(of: current) else {
            highlighted = step > 0 ? ids.first : ids.last
            return
        }
        highlighted = ids[(index + step + ids.count) % ids.count]
    }
}
#endif
