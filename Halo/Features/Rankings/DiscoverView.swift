import SwiftUI

/// openrouter.ai/discover: starting points picked from the catalog's scores, this week's usage and
/// measured speed. The rows open a model's details on the model browser's stack.
struct DiscoverView: View {
    @Environment(RankingsStore.self) private var store
    @Environment(ModelCatalog.self) private var catalog
    @State private var showAllValue = false
    /// Opens a model's details: the cards are buttons, as a link in a list row draws a chevron beside each.
    var open: (String) -> Void = { _ in }

    private struct Highlight: Identifiable {
        let title: String
        let icon: String
        let model: ORModel
        let metric: String
        var id: String { title }
    }

    var body: some View {
        let peers = ModelInsights.peers(catalog.models)
        let usage = store.daily.map { UsageStats(rows: $0.data, weeks: 2) }
        let tokens = usage?.weekly.first ?? [:]
        let weekly = { (m: ORModel) in m.canonicalSlug.flatMap { tokens[$0] } }
        List {
            highlightsSection(peers, weekly: weekly, usage: usage)
            frontierSection(peers)
            valueSection(peers, weekly: weekly)
            routersSection
            aliasesSection
            freeSection
            Section {
            } footer: {
                Text("Scores and speeds: Artificial Analysis. Tokens: OpenRouter, the last 7 days, licensed under CC BY 4.0. Image and video models are in the image and video pickers.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .refreshable { await store.refresh(force: true) }
        .task { await store.refresh() }
    }

    // MARK: Highlights

    @ViewBuilder
    private func highlightsSection(_ peers: [ORModel], weekly: (ORModel) -> Double?, usage: UsageStats?) -> some View {
        let highlights = highlights(peers, weekly: weekly, usage: usage)
        if !highlights.isEmpty {
            Section {
                // A grid, not a sideways scroll: past the second card the rest didn't look like they were there.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(highlights) { h in
                            Button { open(h.model.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 5) {
                                        Image(systemName: h.icon)
                                        Text(h.title).lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    Text(h.model.shortName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2, reservesSpace: true)
                                        .multilineTextAlignment(.leading)
                                    Text(h.metric)
                                        .font(.readout(.caption, weight: .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                sectionTitle("#1 right now")
            }
        }
    }

    private func highlights(_ peers: [ORModel], weekly: (ORModel) -> Double?, usage: UsageStats?) -> [Highlight] {
        var result: [Highlight] = []
        let index = ModelIndex(catalog.models)
        if let top = usage?.ranking().first, let model = index.model(top.slug) {
            result.append(Highlight(title: "Most used", icon: "flame", model: model, metric: "\(RankingsFormat.tokens(top.tokens)) tok/wk"))
        }
        if let m = peers.filter({ $0.intelligence != nil }).max(by: { $0.intelligence! < $1.intelligence! }) {
            result.append(Highlight(title: "Smartest", icon: "brain.head.profile", model: m, metric: "IQ \(EffortMenu.score(m.intelligence!))"))
        }
        if let m = peers.filter({ $0.isOpenWeights && $0.intelligence != nil }).max(by: { $0.intelligence! < $1.intelligence! }) {
            result.append(Highlight(title: "Smartest open", icon: "lock.open", model: m, metric: "IQ \(EffortMenu.score(m.intelligence!))"))
        }
        if let (id, _) = ModelRanking.valueScores(peers, catalog: catalog.models).max(by: { $0.value < $1.value }), let m = catalog.model(id) {
            result.append(Highlight(title: "Best value", icon: "dollarsign.circle", model: m,
                                    metric: "IQ \(EffortMenu.score(m.intelligence ?? 0)) · \(Money.perMillion(ModelRanking.blendedPrice(m)))"))
        }
        if let m = peers.filter({ $0.coding != nil }).max(by: { $0.coding! < $1.coding! }) {
            result.append(Highlight(title: "Best for coding", icon: "chevron.left.forwardslash.chevron.right", model: m,
                                    metric: "Coding \(EffortMenu.score(m.coding!))"))
        }
        // The biggest week-on-week climber among the 25 most used, so a tiny model doubling doesn't win.
        if let climb = usage?.ranking().prefix(25).filter({ $0.change != nil }).max(by: { $0.change! < $1.change! }),
           let change = climb.change, change > 0, let model = index.model(climb.slug) {
            result.append(Highlight(title: "Trending", icon: "chart.line.uptrend.xyaxis", model: model,
                                    metric: "\(RankingsFormat.change(change)) this week"))
        }
        let free = catalog.models.filter { $0.isFree && $0.intelligence != nil && !$0.id.hasPrefix("openrouter/") }
        if let m = free.max(by: { $0.intelligence! < $1.intelligence! }) {
            result.append(Highlight(title: "Best free", icon: "gift", model: m, metric: "IQ \(EffortMenu.score(m.intelligence!))"))
        }
        let speeds = peers.compactMap { m in catalog.measuredSpeed(for: m).map { (m, $0.tps) } }
        if let (m, tps) = speeds.max(by: { $0.1 < $1.1 }) {
            result.append(Highlight(title: "Fastest", icon: "bolt", model: m, metric: "\(Int(tps.rounded())) tok/s"))
        }
        return result
    }

    // MARK: Frontier

    @ViewBuilder
    private func frontierSection(_ peers: [ORModel]) -> some View {
        // Each lab's smartest model, as openrouter.ai/discover lists it.
        let byLab = Dictionary(grouping: peers.filter { $0.intelligence != nil }) { $0.id.split(separator: "/").first.map(String.init) ?? $0.id }
        let top = byLab.values.compactMap { $0.max { $0.intelligence! < $1.intelligence! } }
            .sorted { $0.intelligence! > $1.intelligence! }.prefix(6)
        if let leader = top.first, let runnerUp = top.dropFirst().first {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(leader.shortName) takes the frontier lead")
                        .font(.display(.title3, weight: .semibold))
                    let gap = Int((leader.intelligence! - runnerUp.intelligence!).rounded())
                    Text(gap == 0 ? "\(leader.providerName) and \(runnerUp.providerName) are level on the Artificial Analysis intelligence index."
                         : "\(leader.providerName) edges \(runnerUp.providerName) by \(gap) \(gap == 1 ? "point" : "points") on the Artificial Analysis intelligence index.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 4)
                ForEach(Array(top.enumerated()), id: \.element.id) { i, m in
                    NavigationLink(value: m.id) {
                        HStack(spacing: 10) {
                            rank(i + 1)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(m.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(m.providerName).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    Spacer()
                                    Text(EffortMenu.score(m.intelligence!)).font(.readout(.subheadline, weight: .semibold))
                                }
                                ShareBar(title: nil, value: m.intelligence! / 100)
                            }
                        }
                    }
                }
            } header: {
                sectionTitle("Today's frontier")
            } footer: {
                footer("Each lab's smartest model by the Artificial Analysis intelligence index, 0 to 100.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Value

    @ViewBuilder
    private func valueSection(_ peers: [ORModel], weekly: @escaping (ORModel) -> Double?) -> some View {
        let values = ModelRanking.valueScores(peers, catalog: catalog.models)
        let leaders = values.sorted { $0.value > $1.value }.compactMap { catalog.model($0.key) }
        if !leaders.isEmpty {
            let iq = peers.compactMap(\.intelligence), code = peers.compactMap(\.coding), agent = peers.compactMap(\.agentic)
            Section {
                ForEach(Array(leaders.prefix(showAllValue ? 25 : 8).enumerated()), id: \.element.id) { i, m in
                    NavigationLink(value: m.id) {
                        HStack(spacing: 10) {
                            rank(i + 1)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(m.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text(Money.perMillion(ModelRanking.blendedPrice(m))).font(.readout(.subheadline, weight: .semibold))
                                }
                                let parts = [
                                    m.intelligence.map { "IQ p\(Self.percentile($0, iq))" },
                                    m.coding.map { "code p\(Self.percentile($0, code))" },
                                    m.agentic.map { "agentic p\(Self.percentile($0, agent))" },
                                    weekly(m).map { "\(RankingsFormat.tokens($0)) tok/wk" },
                                ].compactMap { $0 }
                                Text(parts.joined(separator: " · "))
                                    .font(.readout(.caption2))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                }
                if leaders.count > 8 {
                    Button(showAllValue ? "Show fewer" : "Show \(min(leaders.count, 25))") { withAnimation { showAllValue.toggle() } }
                        .font(.subheadline)
                }
            } header: {
                sectionTitle("Value leaders")
            } footer: {
                footer("Models nearly as smart as the best, by intelligence per dollar. pN is the percentile among scored models: p90 beats 90% of them. Price is a 3:1 blend per million tokens.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Routers, aliases, free

    @ViewBuilder
    private var routersSection: some View {
        let routers = catalog.models.filter { $0.id.hasPrefix("openrouter/") }
        if !routers.isEmpty {
            Section {
                ForEach(routers) { m in
                    NavigationLink(value: m.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.shortName).font(.subheadline.weight(.semibold))
                            Text(Self.firstSentence(m.description ?? ""))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                sectionTitle("Routers")
            } footer: {
                footer("OpenRouter picks the model per request. You pay the price of the model it picks.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    @ViewBuilder
    private var aliasesSection: some View {
        let aliases = catalog.models.filter { $0.id.hasPrefix("~") }
        if !aliases.isEmpty {
            Section {
                ForEach(aliases.prefix(12)) { m in
                    NavigationLink(value: m.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(m.providerName).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if let ctx = m.contextLength {
                                Text(TokenFormat.short(ctx)).font(.readout(.caption)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            } header: {
                sectionTitle("Always-latest aliases")
            } footer: {
                footer("Each one moves to the family's newest model when it ships, so a chat on it upgrades itself.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    @ViewBuilder
    private var freeSection: some View {
        // The catalog comes most popular first.
        let free = catalog.models.filter { $0.isFree && !$0.id.hasPrefix("openrouter/") }.prefix(10)
        if !free.isEmpty {
            Section {
                ForEach(Array(free.enumerated()), id: \.element.id) { i, m in
                    NavigationLink(value: m.id) {
                        HStack(spacing: 10) {
                            rank(i + 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(m.providerName).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let iq = m.intelligence { Text("IQ \(EffortMenu.score(iq))").font(.readout(.subheadline, weight: .semibold)) }
                                if let ctx = m.contextLength {
                                    Text(TokenFormat.short(ctx)).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }
                    }
                }
            } header: {
                sectionTitle("Free models")
            } footer: {
                footer("The most used free models. Free tiers are rate-limited and may train on your prompts.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Pieces

    private func rank(_ n: Int) -> some View {
        Text("\(n)")
            .font(.readout(.caption, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 22, alignment: .trailing)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary).textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textTertiary)
    }

    /// Share of the scored values at or below this one, 0–100.
    static func percentile(_ value: Double, _ all: [Double]) -> Int {
        guard !all.isEmpty else { return 0 }
        return Int((Double(all.filter { $0 <= value }.count) / Double(all.count) * 100).rounded())
    }

    private static func firstSentence(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        if let r = plain.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { return String(plain[..<r.upperBound]).trimmingCharacters(in: .whitespaces) }
        return plain
    }
}
