import SwiftUI
import Charts

/// openrouter.ai/rankings on the phone: usage, market share, open vs closed, tasks, smarts against
/// price, speed, apps and benchmarks. Pushed from the model browser, whose stack opens a model's
/// details from a row here.
struct RankingsView: View {
    enum Metric: String, CaseIterable, Identifiable {
        case intelligence = "Intelligence", coding = "Coding", agentic = "Agentic"
        var id: String { rawValue }
        func score(_ m: ORModel) -> Double? {
            switch self {
            case .intelligence: m.intelligence
            case .coding: m.coding
            case .agentic: m.agentic
            }
        }
    }

    enum Scale: String, CaseIterable, Identifiable {
        case share = "Share", tokens = "Tokens"
        var id: String { rawValue }
    }

    enum SpeedSort: String, CaseIterable, Identifiable {
        case throughput = "Throughput", latency = "First token"
        var id: String { rawValue }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case discover = "Discover", rankings = "Rankings"
        var id: String { rawValue }
    }

    /// Opens a model's details on the browser's stack.
    var open: (String) -> Void = { _ in }
    @Environment(RankingsStore.self) private var store
    @Environment(ModelCatalog.self) private var catalog
    @State private var tab: Tab = DemoSeeder.isDemo && DemoSeeder.screen == "rankings" ? .rankings : .discover
    @State private var showAllModels = false
    @State private var showAllLabs = false
    @State private var labScale: Scale = .share
    @State private var openScale: Scale = .share
    @State private var macro: String?
    @State private var metric: Metric = .intelligence
    @State private var speedSort: SpeedSort = .throughput
    @State private var appSort = "popular"
    @State private var board = RankingsStore.Board.all[0]

    private var usage: UsageStats? { store.daily.map { UsageStats(rows: $0.data, weeks: RankingsStore.weeks) } }

    var body: some View {
        Group {
            switch tab {
            case .discover: DiscoverView(open: open)
            case .rankings: rankings
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
    }

    private var rankings: some View {
        let index = ModelIndex(catalog.models)
        let usage = usage
        return List {
            if store.daily == nil, let error = store.errors["daily"] {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Color.white.opacity(0.03))
            }
            topModelsSection(usage, index: index)
            marketShareSection(usage, index: index)
            openClosedSection(usage, index: index)
            tasksSection(index: index)
            paretoSection(index: index)
            speedSection(index: index)
            appsSection
            benchmarksSection(index: index)
            Section {
            } footer: {
                Text("Usage, tasks, apps and benchmarks: OpenRouter (openrouter.ai/rankings)\(store.daily?.meta?.asOf.map { ", as of \(Self.asOf($0))" } ?? ""). Licensed under CC BY 4.0. Scores and speeds: Artificial Analysis.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .refreshable {
            async let all: Void = store.refresh(force: true)
            async let apps: Void = store.loadApps(appSort, force: true)
            async let board: Void = store.loadBoard(board, force: true)
            _ = await (all, apps, board)
        }
        .task { await store.refresh() }
        .task(id: appSort) { await store.loadApps(appSort) }
        .task(id: board) { await store.loadBoard(board) }
    }

    // MARK: Top models

    @ViewBuilder
    private func topModelsSection(_ usage: UsageStats?, index: ModelIndex) -> some View {
        if let usage {
            let ranking = usage.ranking()
            // The five biggest over the whole span get colors; the rest stack as Others.
            let leaders = Self.leaders(usage.weekly, count: 5)
            Section {
                StackChart(weeks: usage.weekly.indices.map { usage.weekStart($0) },
                           series: Self.stacks(usage.weekly, leaders: leaders),
                           names: leaders.map { index.name($0) }, normalized: false)
                    .frame(height: 220)
                    .padding(.vertical, 8)
                ForEach(Array(ranking.prefix(showAllModels ? 50 : 10).enumerated()), id: \.element.id) { i, entry in
                    usageRow(rank: i + 1, entry: entry, index: index, trend: usage.daily[entry.slug])
                }
                if ranking.count > 10 {
                    Button(showAllModels ? "Show top 10" : "Show all \(ranking.count)") {
                        withAnimation { showAllModels.toggle() }
                    }
                    .font(.subheadline)
                }
            } header: {
                sectionTitle("Top models")
            } footer: {
                footer("Tokens processed on OpenRouter each week. The list is the 7 days to \(Self.day(usage.latestDay)), against the week before; the line is the last 30 days.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        } else if store.loading.contains("daily") {
            loadingSection("Top models")
        }
    }

    private func usageRow(rank: Int, entry: UsageStats.Entry, index: ModelIndex, trend: [Double]?) -> some View {
        let model = index.model(entry.slug)
        let content = HStack(spacing: 10) {
            Text("\(rank)")
                .font(.readout(.caption, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(index.name(entry.slug)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(index.lab(entry.slug)).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let trend { Sparkline(values: trend).frame(width: 44, height: 18) }
            VStack(alignment: .trailing, spacing: 2) {
                Text(RankingsFormat.tokens(entry.tokens)).font(.readout(.subheadline, weight: .semibold))
                HStack(spacing: 4) {
                    Text(RankingsFormat.share(entry.share)).foregroundStyle(Theme.textTertiary)
                    changeText(entry.change, new: entry.previous == nil)
                }
                .font(.readout(.caption2))
            }
        }
        return Group {
            if let model { NavigationLink(value: model.id) { content } } else { content }
        }
    }

    // MARK: Market share

    @ViewBuilder
    private func marketShareSection(_ usage: UsageStats?, index: ModelIndex) -> some View {
        if let usage {
            let labs = usage.grouped(UsageStats.lab)
            let leaders = Self.leaders(labs, count: 5)
            let total = labs.first?.values.reduce(0, +) ?? 0
            let ranked = (labs.first ?? [:]).sorted { $0.value > $1.value }
            Section {
                scalePicker($labScale)
                StackChart(weeks: labs.indices.map { usage.weekStart($0) },
                           series: Self.stacks(labs, leaders: leaders),
                           names: leaders.map { index.labName($0) }, normalized: labScale == .share)
                    .frame(height: 200)
                    .padding(.vertical, 8)
                ForEach(Array(ranked.prefix(showAllLabs ? ranked.count : 8).enumerated()), id: \.element.key) { i, lab in
                    let previous = labs[safe: 1]?[lab.key]
                    let previousTotal = labs[safe: 1]?.values.reduce(0, +) ?? 0
                    let share = total > 0 ? lab.value / total : 0
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .font(.readout(.caption, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 22, alignment: .trailing)
                        Text(index.labName(lab.key)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(RankingsFormat.share(share)).font(.readout(.subheadline, weight: .semibold))
                            HStack(spacing: 4) {
                                Text(RankingsFormat.tokens(lab.value)).foregroundStyle(Theme.textTertiary)
                                if let previous, previousTotal > 0 {
                                    pointsText(share - previous / previousTotal)
                                }
                            }
                            .font(.readout(.caption2))
                        }
                    }
                }
                if ranked.count > 8 {
                    Button(showAllLabs ? "Show top 8" : "Show all \(ranked.count)") { withAnimation { showAllLabs.toggle() } }
                        .font(.subheadline)
                }
            } header: {
                sectionTitle("Market share")
            } footer: {
                footer("Each lab's share of the tokens of the top 50 models, by week. Change is in percentage points against the week before.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Open vs closed

    @ViewBuilder
    private func openClosedSection(_ usage: UsageStats?, index: ModelIndex) -> some View {
        if let usage {
            // Only models the catalog knows can be told apart; the rest (and "other") are left out.
            let split = usage.grouped { slug in index.model(slug).map { $0.isOpenWeights ? "Open weights" : "Closed" } }
            let share = { (week: [String: Double]) -> Double? in
                let total = week.values.reduce(0, +)
                return total > 0 ? (week["Open weights"] ?? 0) / total : nil
            }
            Section {
                if let now = split.first.flatMap(share) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Open weights").font(.subheadline)
                        Spacer()
                        Text(RankingsFormat.share(now)).font(.readout(.subheadline, weight: .semibold))
                        if let before = split[safe: 1].flatMap(share) { pointsText(now - before).font(.readout(.caption2)) }
                    }
                }
                scalePicker($openScale)
                StackChart(weeks: split.indices.map { usage.weekStart($0) },
                           series: split.map { week in ["Closed", "Open weights"].map { ($0, week[$0] ?? 0) } },
                           names: ["Closed", "Open weights"], normalized: openScale == .share, area: true)
                    .frame(height: 180)
                    .padding(.vertical, 8)
            } header: {
                sectionTitle("Open vs closed")
            } footer: {
                footer("Tokens to models whose weights are on Hugging Face, against the rest. Models no longer listed aren't counted.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Tasks

    @ViewBuilder
    private func tasksSection(index: ModelIndex) -> some View {
        if let payload = store.tasks?.data {
            let macros = (payload.macroCategories ?? []).sorted { ($0.usageShare ?? 0) > ($1.usageShare ?? 0) }
            let current = macro ?? macros.first?.key
            let tags = payload.classifications
                .filter { current == nil || $0.macroCategory == current }
                .sorted { ($0.usageShare ?? 0) > ($1.usageShare ?? 0) }
            Section {
                if !macros.isEmpty {
                    ChipBar(items: macros.map { ($0.key, "\($0.label) \(RankingsFormat.share($0.usageShare ?? 0))") },
                            selection: Binding(get: { current ?? "" }, set: { macro = $0 }))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(tags) { tag in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(tag.displayName).font(.subheadline.weight(.semibold))
                            Spacer()
                            if let share = tag.usageShare {
                                Text("\(RankingsFormat.share(share)) of requests").font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        ForEach(tag.models.sorted { ($0.tagUsageShare ?? 0) > ($1.tagUsageShare ?? 0) }.prefix(4), id: \.id) { m in
                            ShareBar(title: index.name(m.id), value: m.tagUsageShare ?? 0)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                sectionTitle("Top models by task")
            } footer: {
                footer("What requests were for over the last \(payload.windowDays ?? 7) days, as OpenRouter classifies them, and each task's leading models by share of its requests.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        } else if let error = store.errors["tasks"] {
            errorSection("Top models by task", error)
        }
    }

    // MARK: Pareto

    @ViewBuilder
    private func paretoSection(index: ModelIndex) -> some View {
        let peers = ModelInsights.peers(catalog.models)
        let points = peers.compactMap { m -> ParetoFrontier.Point? in
            guard let score = metric.score(m), let price = ModelRanking.blendedPrice(m), price > 0 else { return nil }
            return ParetoFrontier.Point(id: m.id, price: price, score: score)
        }
        if !points.isEmpty {
            let frontier = ParetoFrontier.frontier(points)
            Section {
                Picker("Score", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                ParetoChart(points: points, frontier: frontier)
                    .frame(height: 260)
                    .padding(.vertical, 8)
                // Numbered as on the chart, where names wouldn't fit: 1 is the cheapest.
                ForEach(Array(frontier.enumerated()).reversed(), id: \.element.id) { i, p in
                    NavigationLink(value: p.id) {
                        HStack(spacing: 10) {
                            FrontierBadge(number: i + 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(index.name(p.id)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(index.lab(p.id)).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(EffortMenu.score(p.score)).font(.readout(.subheadline, weight: .semibold))
                                Text("\(Money.perMillion(p.price)) /M").font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
            } header: {
                sectionTitle("\(metric.rawValue) vs price")
            } footer: {
                footer("Artificial Analysis \(metric.rawValue.lowercased()) index against a 3:1 blend of input and output price (Standard tier), log scale. The line is the Pareto frontier: nothing cheaper scores as high. Numbered from the cheapest.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Speed

    @ViewBuilder
    private func speedSection(index: ModelIndex) -> some View {
        let measured = ModelInsights.peers(catalog.models).compactMap { m in catalog.measuredSpeed(for: m).map { (m, $0) } }
        if !measured.isEmpty {
            let sorted = switch speedSort {
            case .throughput: measured.sorted { $0.1.tps > $1.1.tps }
            case .latency: measured.filter { $0.1.ttft != nil }.sorted { $0.1.ttft! < $1.1.ttft! }
            }
            let top = sorted.prefix(15)
            let best = speedSort == .throughput ? (top.first?.1.tps ?? 1) : (top.last?.1.ttft ?? 1)
            Section {
                Picker("Sort", selection: $speedSort) {
                    ForEach(SpeedSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                ForEach(Array(top), id: \.0.id) { model, speed in
                    NavigationLink(value: model.id) {
                        switch speedSort {
                        case .throughput:
                            ShareBar(title: model.shortName, value: speed.tps / best, label: "\(Int(speed.tps.rounded())) tok/s")
                        case .latency:
                            ShareBar(title: model.shortName, value: (speed.ttft ?? 0) / best, label: ModelSpeed.seconds(speed.ttft ?? 0))
                        }
                    }
                }
            } header: {
                sectionTitle("Fastest models")
            } footer: {
                footer("Artificial Analysis measures at each model's own provider with 1K-token prompts, at its highest reasoning effort.")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Apps

    @ViewBuilder
    private var appsSection: some View {
        let rows = store.apps[appSort]?.data ?? []
        Section {
            Picker("Sort", selection: $appSort) {
                Text("Popular").tag("popular")
                Text("Trending").tag("trending")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if rows.isEmpty {
                if let error = store.errors["apps-\(appSort)"] {
                    Text(error).font(.subheadline).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            ForEach(rows.prefix(20)) { app in
                HStack(spacing: 10) {
                    Text("\(app.rank)")
                        .font(.readout(.caption, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, alignment: .trailing)
                    Text(app.appName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(RankingsFormat.tokens(app.totalTokens.value ?? 0)).font(.readout(.subheadline, weight: .semibold))
                        if let requests = app.totalRequests?.value {
                            Text("\(RankingsFormat.tokens(requests)) requests").font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        } header: {
            sectionTitle("Top apps")
        } footer: {
            footer(appSort == "popular" ? "Apps by tokens sent through OpenRouter over the last 30 days." : "Apps growing fastest against their usual volume.")
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    // MARK: Benchmarks

    @ViewBuilder
    private func benchmarksSection(index: ModelIndex) -> some View {
        let items = store.items(board)
        let top = items.first?.score ?? 1
        Section {
            ChipBar(items: RankingsStore.Board.all.map { ($0.key, $0.title) },
                    selection: Binding(get: { board.key }, set: { key in board = RankingsStore.Board.all.first { $0.key == key } ?? board }))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if items.isEmpty {
                if let error = store.errors[board.key] {
                    Text(error).font(.subheadline).foregroundStyle(Theme.textSecondary)
                } else if store.loading.contains(board.key) {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Text("No results on this board yet.").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
            ForEach(Array(items.prefix(20).enumerated()), id: \.element.id) { i, item in
                let model = index.model(item.model)
                let row = VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(i + 1)")
                            .font(.readout(.caption, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 22, alignment: .trailing)
                        Text(model?.shortName ?? item.name ?? UsageStats.fallbackName(item.model))
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(Self.score(item.score, elo: board.isElo)).font(.readout(.subheadline, weight: .semibold))
                    }
                    let details = [
                        item.winRate.map { "\(RankingsFormat.share($0)) wins" },
                        item.costPerTask.map { "\(Money.format($0)) a task" },
                        item.latencyMs.map { "\(ModelSpeed.seconds($0 / 1000)) a task" },
                    ].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.readout(.caption2))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 30)
                    }
                    if !board.isElo, top > 0 {
                        ShareBar(title: nil, value: item.score / top).padding(.leading, 30)
                    }
                }
                if let model { NavigationLink(value: model.id) { row } } else { row }
            }
        } header: {
            sectionTitle("Benchmarks")
        } footer: {
            footer(store.benchmarks[board.key]?.citation ?? "OpenRouter's own evals, and Design Arena's blind votes on design work.")
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    // MARK: Pieces

    private func scalePicker(_ binding: Binding<Scale>) -> some View {
        Picker("Scale", selection: binding) {
            ForEach(Scale.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textTertiary)
    }

    private func loadingSection(_ title: String) -> some View {
        Section {
            HStack { Spacer(); ProgressView(); Spacer() }
        } header: {
            sectionTitle(title)
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    private func errorSection(_ title: String, _ error: String) -> some View {
        Section {
            Text(error).font(.subheadline).foregroundStyle(Theme.textSecondary)
        } header: {
            sectionTitle(title)
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private func changeText(_ change: Double?, new: Bool) -> some View {
        if new {
            Text("new").foregroundStyle(Theme.textSecondary)
        } else if let change {
            Text(RankingsFormat.change(change)).foregroundStyle(change >= 0 ? Theme.positive : Theme.negative)
        }
    }

    /// A change in share, in percentage points.
    private func pointsText(_ delta: Double) -> some View {
        let pts = delta * 100
        return Text(abs(pts) < 0.05 ? "±0 pts" : String(format: "%@%.1f pts", pts > 0 ? "+" : "−", abs(pts)))
            .foregroundStyle(abs(pts) < 0.05 ? Theme.textTertiary : pts > 0 ? Theme.positive : Theme.negative)
    }

    private static func score(_ value: Double, elo: Bool) -> String {
        if elo { return "\(Int(value.rounded()))" }
        return value <= 1 ? RankingsFormat.share(value) : String(format: "%.1f", value)
    }

    private static func day(_ date: Date?) -> String {
        guard let date else { return "–" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }

    /// The API's ISO time as a day: "Oct 24, 2026".
    private static func asOf(_ iso: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: iso) ?? RankingsStore.day(String(iso.prefix(10)))
        return parsed.map { day($0) } ?? iso
    }

    /// The keys with the most tokens over every week.
    private static func leaders(_ weeks: [[String: Double]], count: Int) -> [String] {
        var totals: [String: Double] = [:]
        for week in weeks { for (k, v) in week where k != UsageStats.otherSlug { totals[k, default: 0] += v } }
        return totals.sorted { $0.value > $1.value }.prefix(count).map(\.key)
    }

    /// Each week as (series, tokens): the leaders by name order, then everything else as Others.
    private static func stacks(_ weeks: [[String: Double]], leaders: [String]) -> [[(String, Double)]] {
        weeks.map { week in
            let rest = week.filter { !leaders.contains($0.key) }.values.reduce(0, +)
            return leaders.map { ($0, week[$0] ?? 0) } + [(StackChart.others, rest)]
        }
    }
}

/// Catalog lookups by id or canonical slug, as the datasets use both.
struct ModelIndex {
    private let byID: [String: ORModel]
    private let bySlug: [String: ORModel]
    private let labNames: [String: String]

    init(_ models: [ORModel]) {
        byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var bySlug: [String: ORModel] = [:]
        var labNames: [String: String] = [:]
        for m in models {
            // The plain id over ":free" and other variants of the same model.
            if let slug = m.canonicalSlug, bySlug[slug] == nil || !m.id.contains(":") { bySlug[slug] = m }
            if let lab = m.id.split(separator: "/").first.map(String.init), labNames[lab] == nil, m.name.contains(": ") {
                labNames[lab] = m.providerName
            }
        }
        self.bySlug = bySlug
        self.labNames = labNames
    }

    func model(_ key: String) -> ORModel? { byID[key] ?? bySlug[key] }

    func name(_ key: String) -> String {
        if key == UsageStats.otherSlug { return "Others" }
        return model(key)?.shortName ?? UsageStats.fallbackName(key)
    }

    func lab(_ key: String) -> String { UsageStats.lab(key).map(labName) ?? "" }

    func labName(_ lab: String) -> String {
        if lab == StackChart.others { return lab }
        return labNames[lab] ?? lab.prefix(1).uppercased() + lab.dropFirst()
    }
}

/// Weekly stacked bars (or areas), the named series in chart colors and the rest gray.
private struct StackChart: View {
    static let others = "Others"

    /// Each week's first day, newest first, as the stats keep them.
    let weeks: [Date]
    /// Per week, (series key, tokens) in stacking order.
    let series: [[(String, Double)]]
    /// Display names for the leading keys, in order; Others follows.
    let names: [String]
    let normalized: Bool
    var area = false

    private struct Point: Identifiable {
        let week: Date
        let name: String
        let order: Int
        let value: Double
        var id: String { "\(week.timeIntervalSince1970)-\(name)" }
    }

    /// Shares are worked out here, not with Charts' normalized stacking, so the axis reads 0–100%.
    private var points: [Point] {
        zip(weeks, series).flatMap { week, values in
            let total = values.reduce(0) { $0 + $1.1 }
            return values.enumerated().map { i, pair in
                Point(week: week, name: i < names.count ? names[i] : Self.others, order: i,
                      value: normalized ? (total > 0 ? pair.1 / total : 0) : pair.1)
            }
        }
    }

    private static func maxStack(_ points: [Point]) -> Double {
        Dictionary(grouping: points, by: \.week).values.map { $0.reduce(0) { $0 + $1.value } }.max() ?? 1
    }

    var body: some View {
        let points = points
        // Others gets a legend entry only when something was grouped into it.
        let hasOthers = points.contains { $0.name == Self.others } && !names.contains(Self.others)
        let domain = names + (hasOthers ? [Self.others] : [])
        let colors = domain.indices.map { i in i < names.count && names[i] != Self.others ? Theme.chartSeries[i % 5] : Theme.chartSeries[5] }
        Chart(points) { p in
            if area {
                AreaMark(x: .value("Week", p.week), y: .value("Tokens", p.value))
                    .foregroundStyle(by: .value("Series", p.name))
            } else {
                BarMark(x: .value("Week", p.week, unit: .weekOfYear), y: .value("Tokens", p.value))
                    .foregroundStyle(by: .value("Series", p.name))
            }
        }
        .chartForegroundStyleScale(domain: domain, range: colors)
        .chartYScale(domain: normalized ? 0...1 : 0...(Self.maxStack(points) * 1.05))
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(normalized ? "\(Int((v * 100).rounded()))%" : RankingsFormat.tokens(v)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }
}

/// Every model as a dot, with the frontier joined and numbered from the cheapest.
private struct ParetoChart: View {
    let points: [ParetoFrontier.Point]
    let frontier: [ParetoFrontier.Point]

    var body: some View {
        let onFrontier = Set(frontier.map(\.id))
        let prices = points.map(\.price)
        let lo = (prices.min() ?? 0.01) / 1.5, hi = (prices.max() ?? 10) * 1.5
        Chart {
            ForEach(points.filter { !onFrontier.contains($0.id) }) { p in
                PointMark(x: .value("Price", p.price), y: .value("Score", p.score))
                    .symbolSize(14)
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
            }
            ForEach(frontier) { p in
                LineMark(x: .value("Price", p.price), y: .value("Score", p.score))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Theme.chartSeries[1].opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(Array(frontier.enumerated()), id: \.element.id) { i, p in
                PointMark(x: .value("Price", p.price), y: .value("Score", p.score))
                    .symbol { FrontierBadge(number: i + 1) }
            }
        }
        .chartXScale(domain: lo...hi, type: .log)
        .chartXAxis {
            AxisMarks(values: [0.01, 0.1, 1, 10, 100].filter { $0 >= lo && $0 <= hi }) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel { if let v = value.as(Double.self) { Text(v >= 1 ? "$\(Int(v))" : Money.format(v)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("Price per million tokens", alignment: .trailing)
        .accessibilityLabel("Score against price for \(points.count) models, \(frontier.count) on the frontier")
    }
}

/// A frontier model's number, as on the chart and beside its row.
private struct FrontierBadge: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 17, height: 17)
            .background(Circle().fill(Theme.chartSeries[1]))
    }
}

/// The last 30 days of a model's tokens, as a line.
private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            LineMark(x: .value("Day", i), y: .value("Tokens", v))
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.textSecondary)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(values.max() ?? 1) * 1.05)
        .accessibilityHidden(true)
    }
}

/// A name over a thin bar, with its value at the end.
struct ShareBar: View {
    let title: String?
    /// 0–1: the bar's length, and the label unless one is given.
    let value: Double
    var label: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(label ?? RankingsFormat.share(value)).font(.readout(.caption2)).foregroundStyle(Theme.textSecondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.textSecondary).frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Capsule chips in a row that scrolls, one selected.
private struct ChipBar: View {
    let items: [(key: String, title: String)]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.key) { item in
                    let on = item.key == selection
                    Button {
                        selection = item.key
                        Haptics.selection()
                    } label: {
                        Text(item.title)
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
    }
}
