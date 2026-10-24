import Charts
import SwiftUI

/// Everything about one chat model: what it costs, how it scores and ranks on Artificial Analysis,
/// how fast it runs, and which models are worth considering instead. Opened by tapping a model
/// in the browser; the big button at the bottom switches to it.
struct ModelDetailView: View {
    let modelID: String
    let isCurrent: Bool
    /// Measured from your own replies.
    var yourSpeed: ModelSpeed? = nil
    /// "Use", or "Add" where picking adds a favorite.
    var pickTitle = "Use"
    let onUse: (String) -> Void

    @Environment(ModelCatalog.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @State private var showAllBenchmarks = false

    var body: some View {
        Group {
            if let model = catalog.model(modelID) {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ model: ORModel) -> some View {
        let peers = ModelInsights.peers(catalog.models)
        let benchmarks = catalog.benchmarks(for: model)
        let alternatives = ModelInsights.alternatives(to: model, among: catalog.models) { catalog.measuredSpeed(for: $0)?.tps }
        return List {
            header(model)
            priceSection(model)
            scoresSection(model, peers: peers, benchmarks: benchmarks)
            effortSection(model)
            speedSection(model, peers: peers)
            compareSection(model, peers: peers, alternatives: alternatives)
            benchmarkSections(benchmarks, peers: peers)
            Section {} footer: {
                Text(attribution).font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { useButton(model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let favorite = settings.favoriteModelIDs.contains(model.id)
                Button {
                    settings.toggleFavorite(model.id)
                    Haptics.selection()
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star").contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    // MARK: Sections

    private func header(_ model: ORModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.providerName.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(model.shortName)
                    .font(.display(.title, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                let meta = [model.created.map { "Released \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted))" },
                            model.contextLength.map { "\(TokenFormat.short($0)) context" }].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                let capabilities = [Capability(on: model.supportsVision, icon: "eye", name: "Images"),
                                    Capability(on: model.supportsFiles, icon: "doc.richtext", name: "PDFs"),
                                    Capability(on: model.supportsTools, icon: "wrench.and.screwdriver", name: "Tools"),
                                    Capability(on: model.supportsReasoning, icon: "brain", name: "Reasoning")].filter(\.on)
                if !capabilities.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(capabilities) { Badge(text: $0.name, color: .white, systemImage: $0.icon) }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        }
    }

    @ViewBuilder
    private func priceSection(_ model: ORModel) -> some View {
        Section {
            if model.isFree {
                row("Price", "Free")
            } else if model.hasVariablePrice {
                row("Price", "Depends on the model it picks")
            } else {
                row("Input", Money.perMillion(model.promptPricePerMillion))
                row("Output", Money.perMillion(model.completionPricePerMillion))
            }
        } header: {
            sectionTitle("Price per million tokens")
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private func scoresSection(_ model: ORModel, peers: [ORModel], benchmarks: [String: Double]) -> some View {
        let math = { (m: ORModel) in catalog.benchmarks(for: m)[ModelInsights.mathIndex] }
        let shown = [
            Score(title: "Intelligence", value: model.intelligence, all: peers.compactMap(\.intelligence)),
            Score(title: "Coding", value: model.coding, all: peers.compactMap(\.coding)),
            Score(title: "Agentic", value: model.agentic, all: peers.compactMap(\.agentic)),
            Score(title: "Math", value: benchmarks[ModelInsights.mathIndex], all: peers.compactMap(math)),
        ].filter { $0.value != nil }
        Section {
            if shown.isEmpty {
                Text("Artificial Analysis hasn't tested this model yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(shown) { score in
                let value = score.value ?? 0
                let place = ModelInsights.rank(value, among: score.all)
                ScoreBar(title: score.title, value: EffortMenu.score(value), fraction: value / max(score.all.max() ?? value, 1),
                         caption: "#\(place.rank) of \(place.of)")
            }
        } header: {
            sectionTitle("Scores")
        } footer: {
            if !shown.isEmpty {
                Text("Artificial Analysis indexes, 0 to 100, at the model's highest reasoning effort. Ranked among the models here it has scored.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private func effortSection(_ model: ORModel) -> some View {
        let scores = catalog.effortScores(for: model)
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        let efforts = order.filter { scores[$0] != nil }
        if efforts.count >= 2, let top = scores.values.max() {
            Section {
                ForEach(efforts, id: \.self) { effort in
                    ScoreBar(title: EffortMenu.label(effort), value: "IQ \(EffortMenu.score(scores[effort]!))",
                             fraction: scores[effort]! / top, caption: nil)
                }
            } header: {
                sectionTitle("Intelligence by thinking effort")
            } footer: {
                Text("More thinking scores higher but answers slower and costs more.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    @ViewBuilder
    private func speedSection(_ model: ORModel, peers: [ORModel]) -> some View {
        let measured = catalog.measuredSpeed(for: model)
        if measured != nil || yourSpeed != nil {
            Section {
                if let measured {
                    let place = ModelInsights.rank(measured.tps, among: peers.compactMap { catalog.measuredSpeed(for: $0)?.tps })
                    row("Speed", "\(Int(measured.tps.rounded())) tokens/s", caption: "#\(place.rank) fastest of \(place.of)")
                    if let ttft = measured.ttft { row("First token", ModelSpeed.seconds(ttft)) }
                    // Thinking models stream their thoughts first; the answer starts later.
                    if let ttfa = measured.ttfa, ttfa > (measured.ttft ?? 0) + 0.5 { row("First answer token", ModelSpeed.seconds(ttfa)) }
                }
                if let yourSpeed {
                    row("Your replies", yourSpeed.summary,
                        caption: "Median of \(yourSpeed.replies) \(yourSpeed.replies == 1 ? "reply" : "replies")")
                }
            } header: {
                sectionTitle("Speed")
            } footer: {
                if measured != nil {
                    Text("Artificial Analysis measures at the model's own provider with 1K-token prompts. Your replies include your network and whichever provider OpenRouter picked.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    @ViewBuilder
    private func compareSection(_ model: ORModel, peers: [ORModel], alternatives: [ModelInsights.Alternative]) -> some View {
        if model.intelligence != nil, ModelInsights.price(model) != nil {
            Section {
                PriceIntelligenceChart(model: model, peers: peers, highlighted: Set(alternatives.map(\.model.id)))
                    .frame(height: 230)
                    .padding(.vertical, 8)
                if alternatives.isEmpty {
                    Text("Nothing here is smarter for the price, nearly as smart for much less, or much faster.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(alternatives) { alt in
                    NavigationLink(value: alt.model.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(alt.kind.title, systemImage: alt.kind.icon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(alt.model.shortName).font(.subheadline.weight(.semibold))
                            Text(alt.detail).font(.readout(.caption)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                sectionTitle("Compared with the rest")
            } footer: {
                Text("Price is a 3:1 blend of input and output, per million tokens. Free models aren't plotted.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    @ViewBuilder
    private func benchmarkSections(_ benchmarks: [String: Double], peers: [ORModel]) -> some View {
        let groups = ModelInsights.groups.compactMap { group -> ModelInsights.BenchmarkGroup? in
            let present = group.benchmarks.filter { benchmarks[$0.key] != nil }
            return present.isEmpty ? nil : ModelInsights.BenchmarkGroup(title: group.title, benchmarks: present)
        }
        let count = groups.reduce(0) { $0 + $1.benchmarks.count }
        if count > 0 {
            if showAllBenchmarks {
                let scored = peers.map { catalog.benchmarks(for: $0) }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.benchmarks) { b in
                            let value = benchmarks[b.key]!
                            let place = ModelInsights.rank(value, among: scored.compactMap { $0[b.key] })
                            LabeledContent {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(ModelInsights.format(value, key: b.key)).font(.readout(.subheadline, weight: .semibold))
                                    Text("#\(place.rank) of \(place.of)").font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                                }
                            } label: {
                                Text(b.title)
                                Text(b.detail)
                            }
                        }
                    } header: {
                        sectionTitle(group.title)
                    }
                    .listRowBackground(Color.white.opacity(0.03))
                }
            } else {
                Section {
                    Button {
                        withAnimation(Motion.snappy) { showAllBenchmarks = true }
                    } label: {
                        HStack {
                            Text("All \(count) benchmarks")
                            Spacer()
                            Image(systemName: "chevron.down")
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
                .listRowBackground(Color.white.opacity(0.03))
            }
        }
    }

    private func useButton(_ model: ORModel) -> some View {
        Button {
            Haptics.selection()
            onUse(model.id)
        } label: {
            Label(isCurrent ? "In use" : "\(pickTitle) \(model.shortName)", systemImage: isCurrent ? "checkmark" : "arrow.up.circle.fill")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .opacity(isCurrent ? 0.55 : 1)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Pieces

    private struct Capability: Identifiable {
        let on: Bool
        let icon: String
        let name: String
        var id: String { name }
    }

    private struct Score: Identifiable {
        let title: String
        let value: Double?
        /// The same score for every peer that has one, to rank against.
        let all: [Double]
        var id: String { title }
    }

    private var attribution: AttributedString {
        var text = AttributedString("Scores and speed from Artificial Analysis.")
        if let range = text.range(of: MediaModelResearch.source) {
            text[range].link = MediaModelResearch.sourceURL
            text[range].underlineStyle = .single
        }
        return text
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(nil)
    }

    private func row(_ label: String, _ value: String, caption: String? = nil) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.readout(.subheadline)).foregroundStyle(Theme.textSecondary)
                if let caption { Text(caption).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary) }
            }
        }
    }
}

/// A score with a bar against the best: "Intelligence  63", a bar, "#4 of 285".
private struct ScoreBar: View {
    let title: String
    let value: String
    let fraction: Double
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer()
                if let caption { Text(caption).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary) }
                Text(value).font(.readout(.subheadline, weight: .semibold))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.textSecondary).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Every scored, priced model as a dot, price across (log scale) and intelligence up, with this
/// model and its alternatives picked out and named.
private struct PriceIntelligenceChart: View {
    let model: ORModel
    let peers: [ORModel]
    let highlighted: Set<String>

    private struct Point: Identifiable {
        let id: String
        let name: String
        let price: Double
        let iq: Double
        let role: Int  // 0 the rest, 1 an alternative, 2 this model
    }

    private var points: [Point] {
        let mine = model.canonicalSlug ?? model.id
        let others = peers.filter { ($0.canonicalSlug ?? $0.id) != mine }
        return (others + [model]).compactMap { m in
            guard let iq = m.intelligence, let price = ModelInsights.price(m), price > 0 else { return nil }
            let role = m.id == model.id ? 2 : highlighted.contains(m.id) ? 1 : 0
            return Point(id: m.id, name: m.shortName, price: price, iq: iq, role: role)
        }
        // Picked-out dots last, so they're drawn on top.
        .sorted { $0.role < $1.role }
    }

    var body: some View {
        Chart(points) { p in
            PointMark(x: .value("Price", p.price), y: .value("Intelligence", p.iq))
                .symbolSize(p.role == 2 ? 140 : p.role == 1 ? 70 : 16)
                .foregroundStyle(p.role == 2 ? Theme.accent : p.role == 1 ? Theme.chartSeries[1] : Theme.textTertiary.opacity(0.6))
                .annotation(position: .top, spacing: 4) {
                    if p.role > 0 {
                        Text(p.name)
                            .font(.caption2.weight(p.role == 2 ? .semibold : .regular))
                            .foregroundStyle(p.role == 2 ? Theme.textPrimary : Theme.chartSeries[1])
                            .lineLimit(1)
                    }
                }
        }
        .chartXScale(type: .log)
        .chartXAxis {
            AxisMarks(values: [0.01, 0.1, 1, 10, 100]) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel { if let v = value.as(Double.self) { Text(Money.format(v)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("Price", alignment: .trailing)
        .chartYAxisLabel("IQ")
        .accessibilityLabel("Intelligence against price for \(points.count) models")
    }
}
