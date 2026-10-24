import Foundation

/// Ranks chat models for the browser's Value sort, its Top picks and the starter picks.
enum ModelRanking {
    /// Labs whose new releases are worth surfacing (OpenRouter id prefixes). Smaller labs ship
    /// constantly, so their releases aren't marked New.
    static let majorLabs: Set<String> = ["anthropic", "openai", "google", "x-ai", "deepseek", "meta", "meta-llama", "mistralai",
                                         "qwen", "moonshotai", "z-ai", "minimax", "xiaomi"]

    /// Artificial Analysis' 3:1 input-to-output blend, per million tokens. Nil when unknown or free.
    static func blendedPrice(_ model: ORModel) -> Double? {
        guard !model.isFree, let input = model.promptPricePerMillion, let output = model.completionPricePerMillion else { return nil }
        return (3 * input + output) / 4
    }

    /// How close to the smartest model a model has to score to count as good value.
    static let valueFloor = 0.65

    /// Intelligence per dollar, but only for models nearly as smart as the best: a weak model that's
    /// nearly free would otherwise top any per-dollar ranking. The bar is set by the smartest paid model
    /// in `catalog`, so a search or filter doesn't lower it. Keyed by model ID; unscored, free and
    /// batch-only models are left out.
    static func valueScores(_ models: [ORModel], catalog: [ORModel]) -> [String: Double] {
        guard let top = catalog.filter(isChatPick).compactMap(\.intelligence).max() else { return [:] }
        var scores: [String: Double] = [:]
        for m in models where isChatPick(m) {
            guard let score = m.intelligence, score >= top * valueFloor, let price = blendedPrice(m), price > 0 else { continue }
            scores[m.id] = score / price
        }
        return scores
    }

    /// A model you'd chat with on purpose: not a router, a preview alias or a batch-only variant.
    static func isChatPick(_ model: ORModel) -> Bool {
        !model.hasVariablePrice && !model.id.hasPrefix("~") && !model.id.hasPrefix("openrouter/") && !model.id.hasSuffix(":batch")
    }

    enum Reason: String, CaseIterable, Identifiable {
        case smartest = "Smartest", value = "Best value", coding = "Best for coding",
             fastest = "Fastest for you", free = "Best free", newest = "Newest"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .smartest: return "brain.head.profile"
            case .value: return "dollarsign.circle"
            case .coding: return "chevron.left.forwardslash.chevron.right"
            case .fastest: return "hare"
            case .free: return "gift"
            case .newest: return "sparkles"
            }
        }
    }

    struct Pick: Identifiable, Hashable {
        let model: ORModel
        var reasons: [Reason]
        var id: String { model.id }
    }

    /// One model per reason, merged when a model wins several (it lists each reason once).
    /// "Fastest for you" needs a few of your own timed replies, so it only appears once you have them.
    /// `catalog` sets the bar for Best value when `models` is a filtered subset.
    static func topPicks(_ models: [ORModel], catalog: [ORModel]? = nil, speeds: [String: ModelSpeed] = [:]) -> [Pick] {
        let candidates = models.filter(isChatPick)
        let values = valueScores(candidates, catalog: catalog ?? models)
        let paid = candidates.filter { !$0.isFree }
        var winners: [(Reason, ORModel)] = []
        func add(_ reason: Reason, _ model: ORModel?) { if let model { winners.append((reason, model)) } }

        add(.smartest, paid.filter { $0.intelligence != nil }.max { $0.intelligence! < $1.intelligence! })
        // The pick leans on the big labs (the Value sort itself ranks everyone): it can become a new
        // user's default, and small labs' models come and go.
        let major = paid.filter { majorLabs.contains(lab($0.id)) }
        add(.value, (major.isEmpty ? paid : major).compactMap { m in values[m.id].map { (m, $0) } }.max { $0.1 < $1.1 }?.0)
        add(.coding, paid.filter { $0.coding != nil }.max { $0.coding! < $1.coding! })
        add(.fastest, candidates.compactMap { m in speeds[m.id].flatMap { $0.replies >= 3 ? (m, $0.tokensPerSecond) : nil } }
            .max { $0.1 < $1.1 }?.0)
        let free = candidates.filter(\.isFree)
        add(.free, free.filter { $0.intelligence != nil }.max { $0.intelligence! < $1.intelligence! }
            ?? free.max { ($0.created ?? 0) < ($1.created ?? 0) })
        add(.newest, paid.filter { majorLabs.contains(lab($0.id)) }.max { ($0.created ?? 0) < ($1.created ?? 0) })

        var picks: [Pick] = []
        for (reason, model) in winners {
            if let i = picks.firstIndex(where: { $0.model.id == model.id }) { picks[i].reasons.append(reason) }
            else { picks.append(Pick(model: model, reasons: [reason])) }
        }
        return picks
    }

    /// Major labs' models added to OpenRouter after `date`. None before you've looked once, so a first
    /// visit doesn't flag all of them.
    static func newModels(_ models: [ORModel], since date: Date?) -> Set<String> {
        guard let since = date?.timeIntervalSince1970 else { return [] }
        return Set(models.filter { ($0.created ?? 0) > since && majorLabs.contains(lab($0.id)) && isChatPick($0) }.map(\.id))
    }

    static func lab(_ id: String) -> String { id.split(separator: "/").first.map(String.init) ?? "" }

    /// A trailing release stamp in a model's name: "DeepSeek V4.1 Flash 1017" → ("DeepSeek V4.1 Flash", "1017").
    /// Also "(2025-10-17)" and "0528"-style stamps; nil when the name doesn't end in one.
    static func splitReleaseStamp(_ name: String) -> (name: String, stamp: String)? {
        let patterns = [#"\s+\((\d{4}-\d{2}-\d{2}|\d{2}-\d{2})\)$"#, #"\s+(\d{4})$"#]
        for pattern in patterns {
            guard let range = name.range(of: pattern, options: .regularExpression) else { continue }
            let stamp = name[range].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            // A bare four digits that reads as a year or version ("2024") isn't a release stamp.
            if stamp.count == 4, let n = Int(stamp), n >= 1900 && n <= 2100 { continue }
            let base = String(name[..<range.lowerBound])
            return base.isEmpty ? nil : (base, stamp)
        }
        return nil
    }
}
