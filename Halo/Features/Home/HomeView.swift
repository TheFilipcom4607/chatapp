import SwiftUI

/// Empty new-chat screen: the eclipse, who you're talking to, and what it costs.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @State private var risen = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            EclipseMark(size: 84)
                .rotationEffect(.degrees(risen ? 0 : -50))
                .opacity(risen ? 1 : 0)
                .blur(radius: risen ? 0 : 6)
            Text(app.persona(id: app.draft.personaID)?.name ?? "Halo")
                .font(.display(.title))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 28)
            Text(modelLine)
                .font(.readout())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)
                .padding(.horizontal, 24)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { Keyboard.dismiss() }
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { risen = true } }
        .task(id: app.draft.modelID) {
            if catalog.model(app.draft.modelID)?.isFree == false { await catalog.loadTiers(app.draft.modelID) }
        }
    }

    /// "$3.00/M in · $15.00/M out · 1M ctx", or just the model id until the catalog loads.
    private var modelLine: String {
        guard let model = catalog.model(app.draft.modelID) else { return app.draft.modelID }
        if model.isFree { return "free · \(TokenFormat.short(model.contextLength)) ctx" }
        if model.hasVariablePrice { return "price varies · \(TokenFormat.short(model.contextLength)) ctx" }
        // The same price as the model menu: the tier and provider this chat will actually use.
        if let expected = catalog.expectedPrice(model.id, chosen: settings.serviceTier(app.draft.serviceTier),
                                                rules: settings.routingRules, routing: settings.modelRouting[model.id]) {
            let tail = expected.tier == .standard ? "\(TokenFormat.short(model.contextLength)) ctx" : expected.tier.title.lowercased()
            return "\(Money.perMillion(expected.price.prompt))/M in · \(Money.perMillion(expected.price.completion))/M out · \(tail)"
        }
        // OpenRouter's list price, until the endpoints are looked up.
        return "\(Money.perMillion(model.promptPricePerMillion))/M in · \(Money.perMillion(model.completionPricePerMillion))/M out · \(TokenFormat.short(model.contextLength)) ctx"
    }
}
