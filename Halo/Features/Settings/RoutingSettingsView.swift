import SwiftUI

/// Presets are starting points for the rules below; the preview is the order sent to OpenRouter.
struct RoutingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var previewModelID: String? = DemoSeeder.isDemo && DemoSeeder.screen == "routing" ? "z-ai/glm-5.3-flash" : nil
    @State private var showAllHosts = false

    /// Rows the preview shows before "Show all".
    private static let collapsedRows = 6

    private var previewID: String { previewModelID ?? settings.defaultModelID }
    private var modelRules: ModelRouting { settings.modelRouting[previewID] ?? ModelRouting() }
    private var endpoints: [EndpointInfo] { catalog.endpoints[previewID] ?? [] }
    private var ranked: [(EndpointInfo, RoutingRules.RankStatus)] {
        RoutingRules.rank(endpoints, rules: settings.routingRules, model: settings.modelRouting[previewID])
    }
    /// The endpoint tags in the `order` Halo would send for the preview model, exactly as built
    /// for a request, so the numbers in the preview can't drift from what's sent.
    private var sentOrder: [String] {
        let p = settings.routingRules.preferences(for: previewID, endpoints: endpoints,
                                                  model: settings.modelRouting[previewID])
        return p?.objectValue?["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Preset") {
                ForEach(RoutingPreset.allCases) { preset in
                    Button {
                        settings.routingRules.apply(preset)
                        Haptics.selection()
                    } label: {
                        presetRow(preset.title, subtitle: preset.subtitle,
                                  checked: settings.routingRules.matchingPreset == preset)
                    }
                }
                if settings.routingRules.matchingPreset == nil {
                    presetRow("Custom", subtitle: "Your own strategy below", checked: true)
                }
            }

            preview

            Section {
                MenuPickerRow(title: "Pick by", selection: Binding(
                    get: { settings.routingRules.sort.rawValue },
                    set: { settings.routingRules.sort = RoutingRules.Sort(rawValue: $0) ?? .price }
                ), options: [
                    .init(id: "price", name: "Price"),
                    .init(id: "throughput", name: "Throughput"),
                    .init(id: "latency", name: "Latency"),
                    .init(id: "none", name: "OpenRouter"),
                ])
                MenuPickerRow(title: "Prefer at least", selection: Binding(
                    get: { settings.routingRules.minThroughput.map { String(Int($0)) } ?? "off" },
                    set: { settings.routingRules.minThroughput = $0 == "off" ? nil : Double($0) }
                ), options: [
                    .init(id: "off", name: "Any speed"), .init(id: "20", name: "20 tok/s"),
                    .init(id: "40", name: "40 tok/s"), .init(id: "60", name: "60 tok/s"),
                    .init(id: "100", name: "100 tok/s"),
                ])
                MenuPickerRow(title: "Prefer first token under", selection: Binding(
                    get: { settings.routingRules.maxLatency.map { String(Int($0)) } ?? "off" },
                    set: { settings.routingRules.maxLatency = $0 == "off" ? nil : Double($0) }
                ), options: [
                    .init(id: "off", name: "Any"), .init(id: "1", name: "1 s"),
                    .init(id: "2", name: "2 s"), .init(id: "3", name: "3 s"),
                    .init(id: "5", name: "5 s"),
                ])
                MenuPickerRow(title: "Precision", selection: Binding(
                    get: { settings.routingRules.precision.rawValue },
                    set: { settings.routingRules.precision = RoutingRules.Precision(rawValue: $0) ?? .any }
                ), options: [
                    .init(id: "any", name: "Any"), .init(id: "eightBit", name: "8-bit or better"),
                    .init(id: "full", name: "16-bit only"),
                ])
            } header: {
                Text("Strategy")
            } footer: {
                Text("Editing these switches to Custom. Speed thresholds are soft (p50): slower hosts go to the back, not out. Precision is hard: fp4 and fp6 hosts are cheaper but dumber; a host that doesn't say counts as full.")
            }

            Section {
                priceRow("Max input", value: $settings.routingRules.maxPrompt)
                priceRow("Max output", value: $settings.routingRules.maxCompletion)
                Toggle("Fall back when a host fails", isOn: $settings.routingRules.allowFallbacks)
                Toggle("Skip hosts that keep prompts", isOn: $settings.routingRules.denyDataCollection)
                Toggle("One host per chat", isOn: $settings.routingRules.stickyPerChat)
                NavigationLink {
                    BlockedProvidersView()
                } label: {
                    LabeledContent("Blocked providers", value: settings.routingRules.blocked.isEmpty
                                   ? "None" : "\(settings.routingRules.blocked.count)")
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Every preset keeps these. Prices are $/M tokens; a limit no host meets is ignored for that model. One host per chat keeps its prompt cache warm, but won't switch to a cheaper host mid-chat.")
            }

            if !settings.modelRouting.isEmpty {
                Section {
                    ForEach(settings.modelRouting.keys.sorted(), id: \.self) { id in
                        let rules = settings.modelRouting[id] ?? ModelRouting()
                        Button {
                            previewModelID = id
                            Haptics.selection()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(catalog.displayName(id)).foregroundStyle(Theme.textPrimary)
                                Text(overrideSummary(rules, modelID: id))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .swipeActions {
                            Button("Reset", role: .destructive) { settings.modelRouting.removeValue(forKey: id) }
                        }
                    }
                } header: {
                    Text("Per-model rules")
                } footer: {
                    Text("Tap to preview, swipe to reset.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Provider routing")
        .macSheetBar("Provider routing", back: true)
        .inlineNavigationTitle()
        .task(id: previewID) { await catalog.loadTiers(previewID) }
    }

    // MARK: Preview

    private var preview: some View {
        let rows = ranked
        let order = sentOrder
        let picks = rows.filter { if case .pick = $0.1 { return true } else { return false } }.count
        let visible = showAllHosts ? rows : Array(rows.prefix(Self.collapsedRows))
        return Section {
            Menu {
                ForEach(previewModels, id: \.self) { id in
                    Button {
                        previewModelID = id
                        showAllHosts = false
                    } label: {
                        if id == previewID { Label(catalog.displayName(id), systemImage: "checkmark") }
                        else { Text(catalog.displayName(id)) }
                    }
                }
            } label: {
                SettingsValueRow(title: "Model", value: catalog.displayName(previewID))
            }
            if endpoints.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading providers…").foregroundStyle(Theme.textSecondary)
                }
            }
            if settings.routingRules.matchingPreset != .openRouter,
               let warning = RoutingRules.hardFilterWarning(
                endpoints, rules: settings.routingRules, model: settings.modelRouting[previewID]) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(visible, id: \.0.id) { endpoint, status in
                providerRow(endpoint, status: status, position: order.firstIndex(of: endpoint.tag).map { $0 + 1 })
            }
            if rows.count > Self.collapsedRows {
                Button {
                    withAnimation(Motion.snappy) { showAllHosts.toggle() }
                } label: {
                    HStack {
                        Text(showAllHosts ? "Show fewer" : "Show all \(rows.count) hosts")
                        Spacer()
                        Text("\(picks) usable · \(rows.count - picks) skipped")
                            .font(.readout(.caption))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
            }
        } header: {
            Text("Preview")
        } footer: {
            Text(previewFooter(sentCount: order.count))
        }
    }

    private func previewFooter(sentCount: Int) -> String {
        let rules = settings.routingRules
        let how: String
        if rules.matchingPreset == .openRouter {
            how = "OpenRouter picks the host; Halo only sends your limits and blocks."
        } else if sentCount == 0, RoutingRules.sortsByMissingStat(endpoints, sort: rules.sort) {
            how = "OpenRouter doesn't publish per-host \(rules.sort == .latency ? "latency" : "throughput") for this model, so Halo sends no order and lets OpenRouter sort by its live numbers."
        } else {
            how = "Numbered hosts are the order Halo sends, tried top to bottom. Unnumbered ones are OpenRouter's fallbacks."
        }
        return how + " Swipe right on a host to always use it for this model, left to never use it; long-press to block it everywhere."
    }

    private var previewModels: [String] {
        ([previewID] + settings.favoriteModelIDs).reduce(into: []) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

    // MARK: Rows

    private func presetRow(_ title: String, subtitle: String, checked: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if checked { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }

    private func priceRow(_ title: String, value: Binding<Double?>) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            TextField("Any", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
            Text("$/M").font(.readout(.caption)).foregroundStyle(Theme.textTertiary)
        }
    }

    @ViewBuilder
    private func providerRow(_ ep: EndpointInfo, status: RoutingRules.RankStatus, position: Int?) -> some View {
        let pinned = modelRules.pinned.contains(ep.slug)
        let blockedHere = modelRules.blocked.contains(ep.slug)
        let blockedEverywhere = settings.routingRules.blocked.contains(ep.slug)
        let skipReason: String? = if case .skipped(let reason) = status { reason } else { nil }
        let slow = skipReason == nil && !RoutingRules.meetsSoftThresholds(ep, rules: settings.routingRules)
        HStack(spacing: 12) {
            rankMark(position, skipped: skipReason != nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(ep.name).lineLimit(1)
                    if pinned { Image(systemName: "pin.fill").font(.caption2) }
                    if blockedHere || blockedEverywhere { Image(systemName: "nosign").font(.caption2) }
                }
                .foregroundStyle(skipReason == nil ? Theme.textPrimary : Theme.textTertiary)
                Text(details(ep))
                    .font(.readout(.caption2))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Money.perMillion(ep.prompt))/\(Money.perMillion(ep.completion))")
                    .font(.readout(.caption))
                    .foregroundStyle(skipReason == nil ? Theme.textSecondary : Theme.textTertiary)
                if let skipReason {
                    Text(skipReason).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                } else if slow {
                    Text("slow").font(.readout(.caption2)).foregroundStyle(.orange)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button { togglePin(ep.slug) } label: {
                Label(pinned ? "Unpin" : "Always", systemImage: pinned ? "pin.slash" : "pin")
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .trailing) {
            Button { toggleModelBlock(ep.slug) } label: {
                Label(blockedHere ? "Allow" : "Never", systemImage: blockedHere ? "checkmark" : "nosign")
            }
            .tint(blockedHere ? Theme.positive : Theme.negative)
        }
        .contextMenu {
            Button { togglePin(ep.slug) } label: {
                Label(pinned ? "Remove pin" : "Always use for this model", systemImage: "pin")
            }
            Button { toggleModelBlock(ep.slug) } label: {
                Label(blockedHere ? "Allow for this model" : "Never use for this model", systemImage: "nosign")
            }
            Button { toggleGlobalBlock(ep.slug) } label: {
                Label(blockedEverywhere ? "Allow everywhere" : "Block everywhere", systemImage: "hand.raised")
            }
        }
    }

    /// The host's place in the sent order; an empty ring for a usable fallback, nothing for a skipped host.
    private func rankMark(_ position: Int?, skipped: Bool) -> some View {
        ZStack {
            if let position {
                Circle().fill(Theme.fillStrong)
                Text("\(position)").font(.readout(.caption, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            } else if !skipped {
                Circle().strokeBorder(Theme.fillStrong, lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func details(_ ep: EndpointInfo) -> String {
        var parts: [String] = []
        if ep.quant != "unknown" { parts.append(ep.quant) }
        // The tag's variant tells apart two endpoints of one host ("wafer/us" beside "wafer/nvfp4").
        let variant = ep.tag.split(separator: "/").dropFirst().joined(separator: "/")
        if !variant.isEmpty, variant != ep.quant { parts.append(variant) }
        if let tps = ep.tps { parts.append("\(Int(tps.rounded())) tok/s") }
        if let latency = ep.latency { parts.append(String(format: "%.1fs", latency)) }
        // Nearly every host sits at 100%; only a dip is worth the room.
        if let uptime = ep.uptime, uptime < 99.5 { parts.append("\(Int(uptime.rounded()))% up") }
        return parts.isEmpty ? "no stats" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func togglePin(_ slug: String) {
        var rules = modelRules
        if rules.pinned.contains(slug) { rules.pinned.removeAll { $0 == slug } }
        else {
            rules.pinned.append(slug)
            rules.blocked.removeAll { $0 == slug }
        }
        save(rules)
        Haptics.selection()
    }

    private func toggleModelBlock(_ slug: String) {
        var rules = modelRules
        if rules.blocked.contains(slug) { rules.blocked.removeAll { $0 == slug } }
        else {
            rules.blocked.append(slug)
            rules.pinned.removeAll { $0 == slug }
        }
        save(rules)
        Haptics.selection()
    }

    private func toggleGlobalBlock(_ slug: String) {
        let wasBlocked = settings.routingRules.blocked.contains(slug)
        settings.routingRules.blocked.removeAll { $0 == slug }
        if !wasBlocked { settings.routingRules.blocked.append(slug) }
        Haptics.selection()
    }

    private func save(_ rules: ModelRouting) {
        settings.modelRouting[previewID] = rules.pinned.isEmpty && rules.blocked.isEmpty ? nil : rules
    }

    private func overrideSummary(_ rules: ModelRouting, modelID: String) -> String {
        var parts: [String] = []
        if !rules.pinned.isEmpty { parts.append("Always " + rules.pinned.map { providerName($0, modelID: modelID) }.joined(separator: ", ")) }
        if !rules.blocked.isEmpty { parts.append("Never " + rules.blocked.map { providerName($0, modelID: modelID) }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func providerName(_ slug: String, modelID: String) -> String {
        catalog.endpoints[modelID]?.first { $0.slug == slug }?.name ?? catalog.knownProviders[slug] ?? slug
    }
}

/// Providers skipped for every model, searchable since OpenRouter has dozens.
private struct BlockedProvidersView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var search = ""

    private var providers: [(slug: String, name: String)] {
        var all = catalog.knownProviders
        // A blocked host whose models aren't cached any more still needs a row to unblock it.
        for slug in settings.routingRules.blocked where all[slug] == nil { all[slug] = slug }
        return all.map { (slug: $0.key, name: $0.value) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.slug.contains(search.lowercased()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let all = providers
        let blocked = all.filter { settings.routingRules.blocked.contains($0.slug) }
        let allowed = all.filter { !settings.routingRules.blocked.contains($0.slug) }
        Form {
            if !blocked.isEmpty {
                Section("Blocked") {
                    ForEach(blocked, id: \.slug) { row($0, isBlocked: true) }
                }
            }
            Section {
                if allowed.isEmpty {
                    Text(search.isEmpty ? "Providers appear here once their models load." : "No matching providers")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(allowed, id: \.slug) { row($0, isBlocked: false) }
            } header: {
                Text("Allowed")
            } footer: {
                Text("Tap a provider to block it for every model. Pinning a host for one model in the preview overrides this.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        #if os(iOS)
        .searchable(text: $search, prompt: "Find a provider")
        #else
        .pinnedSearchable(text: $search, prompt: "Find a provider")
        #endif
        .navigationTitle("Blocked providers")
        .macSheetBar("Blocked providers", back: true)
        .inlineNavigationTitle()
    }

    private func row(_ provider: (slug: String, name: String), isBlocked: Bool) -> some View {
        Button {
            withAnimation(Motion.snappy) {
                settings.routingRules.blocked.removeAll { $0 == provider.slug }
                if !isBlocked { settings.routingRules.blocked.append(provider.slug) }
            }
            Haptics.selection()
        } label: {
            HStack {
                Text(provider.name).foregroundStyle(Theme.textPrimary)
                Text(provider.slug).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
                Spacer()
                if isBlocked { Image(systemName: "nosign").foregroundStyle(Theme.negative) }
            }
            .contentShape(Rectangle())
        }
    }
}
