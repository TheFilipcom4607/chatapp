import SwiftUI

/// Presets are starting points for the rules below; the preview is the order sent to OpenRouter.
struct RoutingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var previewModelID: String?
    @State private var providerSearch = ""

    private var previewID: String { previewModelID ?? settings.defaultModelID }
    private var modelRules: ModelRouting { settings.modelRouting[previewID] ?? ModelRouting() }
    private var endpoints: [EndpointInfo] { catalog.endpoints[previewID] ?? [] }
    private var ranked: [(EndpointInfo, RoutingRules.RankStatus)] {
        RoutingRules.rank(endpoints, rules: settings.routingRules, model: settings.modelRouting[previewID])
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Preset") {
                ForEach(RoutingPreset.allCases) { preset in
                    Button {
                        var rules = preset.rules
                        rules.blocked = settings.routingRules.blocked
                        settings.routingRules = rules
                        Haptics.selection()
                    } label: {
                        presetRow(preset.title, subtitle: preset.subtitle,
                                  checked: settings.routingRules.matchingPreset == preset)
                    }
                }
                if settings.routingRules.matchingPreset == nil {
                    presetRow("Custom", subtitle: "Your own provider rules", checked: true)
                }
            }

            Section("Rules") {
                MenuPickerRow(title: "Pick by", selection: Binding(
                    get: { settings.routingRules.sort.rawValue },
                    set: { settings.routingRules.sort = RoutingRules.Sort(rawValue: $0) ?? .price }
                ), options: [
                    .init(id: "price", name: "Price"),
                    .init(id: "throughput", name: "Speed"),
                    .init(id: "latency", name: "Response time"),
                    .init(id: "none", name: "OpenRouter"),
                ])
                VStack(alignment: .leading, spacing: 5) {
                    MenuPickerRow(title: "Prefer at least", selection: Binding(
                        get: { settings.routingRules.minThroughput.map { String(Int($0)) } ?? "off" },
                        set: { settings.routingRules.minThroughput = $0 == "off" ? nil : Double($0) }
                    ), options: [
                        .init(id: "off", name: "Off"), .init(id: "20", name: "20 tok/s"),
                        .init(id: "40", name: "40 tok/s"), .init(id: "60", name: "60 tok/s"),
                        .init(id: "100", name: "100 tok/s"),
                    ])
                    Text("Slower hosts are only used if nothing faster works")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                MenuPickerRow(title: "Prefer first token under", selection: Binding(
                    get: { settings.routingRules.maxLatency.map { String(Int($0)) } ?? "off" },
                    set: { settings.routingRules.maxLatency = $0 == "off" ? nil : Double($0) }
                ), options: [
                    .init(id: "off", name: "Off"), .init(id: "1", name: "1 s"),
                    .init(id: "2", name: "2 s"), .init(id: "3", name: "3 s"),
                    .init(id: "5", name: "5 s"),
                ])
                VStack(alignment: .leading, spacing: 5) {
                    MenuPickerRow(title: "Precision", selection: Binding(
                        get: { settings.routingRules.precision.rawValue },
                        set: { settings.routingRules.precision = RoutingRules.Precision(rawValue: $0) ?? .any }
                    ), options: [
                        .init(id: "any", name: "Any"), .init(id: "eightBit", name: "8-bit or better"),
                        .init(id: "full", name: "Full only"),
                    ])
                    Text("Lower bits are cheaper but noticeably dumber")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                LabeledContent("Max input price, $/M") {
                    TextField("No limit", value: $settings.routingRules.maxPrompt, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Max output price, $/M") {
                    TextField("No limit", value: $settings.routingRules.maxCompletion, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Toggle("Fall back to other hosts if one fails", isOn: $settings.routingRules.allowFallbacks)
                Toggle("Skip hosts that log or train on prompts", isOn: $settings.routingRules.denyDataCollection)
                Toggle("Stay on one host per chat (better caching)", isOn: $settings.routingRules.stickyPerChat)
            }

            Section("Blocked providers") {
                let providers = filteredProviders
                if providers.isEmpty {
                    Text(providerSearch.isEmpty ? "Providers appear here after their models load." : "No matching providers")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(providers, id: \.key) { slug, name in
                    Toggle(name, isOn: Binding(
                        get: { settings.routingRules.blocked.contains(slug) },
                        set: { blocked in
                            settings.routingRules.blocked.removeAll { $0 == slug }
                            if blocked { settings.routingRules.blocked.append(slug) }
                        }
                    ))
                }
            }

            Section {
                Menu {
                    ForEach(previewModels, id: \.self) { id in
                        Button {
                            previewModelID = id
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
                ForEach(Array(ranked.enumerated()), id: \.offset) { _, item in
                    providerRow(item.0, status: item.1)
                }
            } header: {
                Text("Preview")
            } footer: {
                Text(settings.routingRules.matchingPreset == .openRouter
                     ? "OpenRouter chooses the host; Halo sends no provider order for this preset."
                     : "Halo sends this order; if a host fails, the next one is tried.")
            }

            if !settings.modelRouting.isEmpty {
                Section("Per-model rules") {
                    ForEach(settings.modelRouting.keys.sorted(), id: \.self) { id in
                        let rules = settings.modelRouting[id] ?? ModelRouting()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(catalog.displayName(id))
                                Text(overrideSummary(rules, modelID: id))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button("Reset") { settings.modelRouting.removeValue(forKey: id) }
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Provider routing")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $providerSearch, prompt: "Find a provider")
        .task(id: previewID) { await catalog.loadTiers(previewID) }
    }

    private var filteredProviders: [(key: String, value: String)] {
        catalog.knownProviders
            .filter { providerSearch.isEmpty || $0.value.localizedCaseInsensitiveContains(providerSearch) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedSame }
    }

    private var previewModels: [String] {
        ([previewID] + settings.favoriteModelIDs).reduce(into: []) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

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

    @ViewBuilder
    private func providerRow(_ ep: EndpointInfo, status: RoutingRules.RankStatus) -> some View {
        let pinned = modelRules.pinned.contains(ep.slug)
        let blocked = modelRules.blocked.contains(ep.slug) || settings.routingRules.blocked.contains(ep.slug)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ep.name).foregroundStyle(Theme.textPrimary)
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint) }
                    if blocked { Image(systemName: "nosign").font(.caption2).foregroundStyle(Theme.textTertiary) }
                }
                Text("\(Money.perMillion(ep.prompt)) / \(Money.perMillion(ep.completion)) · \(ep.quant)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Text(metrics(ep)).font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            switch status {
            case .pick(let position):
                VStack(alignment: .trailing, spacing: 4) {
                    Text(ordinal(position)).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    if !RoutingRules.meetsSoftThresholds(ep, rules: settings.routingRules) {
                        Text("slow").font(.caption2).foregroundStyle(.orange)
                    }
                }
            case .skipped(let reason):
                Text("skipped: \(reason)").font(.caption2).foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .swipeActions(edge: .leading) {
            Button { togglePin(ep.slug) } label: { Label(pinned ? "Unpin" : "Always use", systemImage: "pin") }
                .tint(.accentColor)
        }
        .swipeActions(edge: .trailing) {
            Button(modelRules.blocked.contains(ep.slug) ? "Allow" : "Never use") { toggleModelBlock(ep.slug) }
                .tint(.red)
        }
        .contextMenu {
            Button { togglePin(ep.slug) } label: {
                Label(pinned ? "Remove pin" : "Always use for this model", systemImage: "pin")
            }
            Button { toggleModelBlock(ep.slug) } label: {
                Label(modelRules.blocked.contains(ep.slug) ? "Allow for this model" : "Never use for this model", systemImage: "nosign")
            }
            Button { toggleGlobalBlock(ep.slug) } label: {
                Label(settings.routingRules.blocked.contains(ep.slug) ? "Allow everywhere" : "Block everywhere", systemImage: "hand.raised")
            }
        }
    }

    private func metrics(_ ep: EndpointInfo) -> String {
        var result: [String] = []
        result.append(ep.tps.map { "\(Int($0.rounded())) tok/s" } ?? "tok/s unknown")
        result.append(ep.latency.map { "first token \(String(format: "%.1f", $0)) s" } ?? "latency unknown")
        if let uptime = ep.uptime { result.append("\(Int(uptime.rounded()))% uptime") }
        return result.joined(separator: " · ")
    }

    private func ordinal(_ n: Int) -> String {
        let suffix = switch n % 100 {
        case 11...13: "th"
        default: switch n % 10 { case 1: "st"; case 2: "nd"; case 3: "rd"; default: "th" }
        }
        return "\(n)\(suffix)"
    }

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
        if !rules.pinned.isEmpty { parts.append("Pinned: " + rules.pinned.map { providerName($0, modelID: modelID) }.joined(separator: ", ")) }
        if !rules.blocked.isEmpty { parts.append("Blocked: " + rules.blocked.map { providerName($0, modelID: modelID) }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func providerName(_ slug: String, modelID: String) -> String {
        catalog.endpoints[modelID]?.first { $0.slug == slug }?.name ?? catalog.knownProviders[slug] ?? slug
    }
}
