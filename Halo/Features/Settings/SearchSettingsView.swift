import SwiftUI

/// Who runs web searches and which sites they may use, for every chat. A chat picks its own depth
/// from the search button; a persona can pick its own engine.
struct SearchSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newDomain = ""

    private var filter: DomainFilterMode { DomainFilterMode(rawValue: settings.searchDomainFilter) ?? .none }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(SearchEngine.allCases) { engine in
                    Button {
                        Haptics.selection()
                        settings.searchEngine = engine.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(engine.title)
                                Text(engine.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                if let price = Self.priceNote(engine) {
                                    Text(price)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .opacity(settings.searchEngine == engine.rawValue ? 1 : 0)
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Prices are per search, on top of the model's own tokens. Each chat picks Quick, Standard or Deep from its search button; Deep reads more of each page and can search more times per reply.")
            }

            Section {
                Picker("Search", selection: $settings.searchDomainFilter) {
                    ForEach(DomainFilterMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if filter != .none {
                    ForEach(settings.searchDomains, id: \.self) { domain in
                        Text(domain)
                    }
                    .onDelete { settings.searchDomains.remove(atOffsets: $0) }
                    HStack {
                        TextField("Add a site, like reddit.com", text: $newDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .onSubmit(addDomain)
                        if DomainFilterMode.normalize(newDomain) != nil {
                            Button("Add", action: addDomain)
                                .fontWeight(.semibold)
                        }
                    }
                }
            } footer: {
                Text(footer)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.snappy, value: filter)
    }

    private var footer: String {
        let gemini = "Gemini's own search can't filter sites: Automatic switches those chats to Exa, and Model's own searches them unfiltered."
        switch filter {
        case .none: return "Limit searches to sites you trust, or keep some sites out of them."
        case .only: return gemini
        case .exclude: return gemini + " OpenAI's own search ignores this list."
        }
    }

    private func addDomain() {
        guard let domain = DomainFilterMode.normalize(newDomain) else { return }
        if !settings.searchDomains.contains(domain) { settings.searchDomains.append(domain) }
        newDomain = ""
        Haptics.tap()
    }

    /// The engine's price range across depths; nil for engines priced per model.
    static func priceNote(_ engine: SearchEngine) -> String? {
        if engine == .auto || engine == .native { return "Model's own price, else Exa's \(SearchPrices.format(SearchPrices.exaAuto))" }
        let prices = SearchDepth.allCases.compactMap { SearchConfig(engine: engine, depth: $0).estimatedCostPerSearch(model: nil) }
        guard let low = prices.min(), let high = prices.max() else { return nil }
        return low == high ? SearchPrices.format(low) : "\(SearchPrices.format(low))–\(SearchPrices.format(high))"
    }
}
