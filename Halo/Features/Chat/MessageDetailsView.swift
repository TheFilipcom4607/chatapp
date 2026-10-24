import SwiftUI

struct MessageDetailsView: View {
    let messageID: UUID
    @Environment(ChatEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var stats: GenerationStats?

    var body: some View {
        NavigationStack {
            List {
                if let m = engine.message(id: messageID) {
                    let usage = m.usage
                    Section("Model") {
                        row("Model", catalog.displayName(m.modelID ?? ""))
                        row("Model id", m.modelID ?? "–", mono: true)
                        row("Provider", stats?.providerName ?? m.provider ?? "–")
                        if m.serviceTier != nil { row("Tier", ServiceTier(response: m.serviceTier).title) }
                    }
                    Section("Cost") {
                        row("This reply", Money.format(m.cost))
                        if let conv = m.conversation { row("Whole chat", Money.format(conv.totalCost)) }
                        if let stats, let total = stats.totalCost { row("OpenRouter billed", Money.format(total)) }
                    }
                    Section("Tokens") {
                        row("Input", "\(usage?.promptTokens ?? 0)")
                        row("Cached input", "\(usage?.cachedTokens ?? 0)")
                        row("Output", "\(usage?.completionTokens ?? 0)")
                        row("Reasoning", "\(usage?.reasoningTokens ?? 0)")
                    }
                    if let searches = usage?.webSearches, searches > 0 {
                        Section("Web search") {
                            row("Searches", "\(searches)")
                            if let config = m.searchConfig {
                                row("Engine", "\(config.engine.title) · \(config.depth.title)")
                                if let each = config.estimatedCostPerSearch(model: catalog.model(m.modelID ?? "")) {
                                    row("Search cost", "≈\(SearchPrices.format(each * Double(searches)))")
                                }
                            }
                        }
                    }
                    Section("Speed") {
                        if let latency = m.latency { row("Time to first token", String(format: "%.2fs", latency)) }
                        if let duration = m.duration { row("Total time", String(format: "%.1fs", duration)) }
                        if let speed = ModelSpeed.tokensPerSecond(m) {
                            row("Speed", String(format: "%.0f tokens/s", speed))
                        }
                    }
                    if let id = m.generationID {
                        Section("Generation") {
                            row("Id", id, mono: true)
                            Link("Open in OpenRouter activity", destination: URL(string: "https://openrouter.ai/activity")!)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .task {
                if let id = engine.message(id: messageID)?.generationID {
                    stats = try? await engine.client.generation(id: id, attempts: 2)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(mono ? .readout(.caption) : .readout(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }
}
