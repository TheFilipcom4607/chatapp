import Foundation

/// OpenRouter service tiers. A request gets Standard unless it asks for another, and a model only
/// offers Flex or Priority where one of its providers sells it.
enum ServiceTier: String, CaseIterable, Identifiable, Sendable {
    case standard, flex, priority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .flex: return "Flex"
        case .priority: return "Priority"
        }
    }

    var blurb: String {
        switch self {
        case .standard: return "Normal speed and price"
        case .flex: return "Cheaper, but slower and can fail when busy"
        case .priority: return "Faster, costs more"
        }
    }

    /// One line for the model menu's header: tier, price and the trade-off in a word.
    func menuTitle(_ price: TierPrice?) -> String {
        let note: String? = switch self {
        case .standard: nil
        case .flex: "slower"
        case .priority: "faster"
        }
        return ([title, price?.label, note].compactMap { $0 }).joined(separator: " · ")
    }

    /// The tier's icon in the model menu's palette.
    var icon: String { symbol ?? "gauge.with.dots.needle.50percent" }

    /// Marks a price that isn't Standard.
    var symbol: String? {
        switch self {
        case .standard: return nil
        case .flex: return "tortoise"
        case .priority: return "hare"
        }
    }

    /// The request's `service_tier`; nil for Standard.
    var requestValue: String? { self == .standard ? nil : rawValue }

    /// From a response's `service_tier` ("default", "flex", "priority" or nil).
    init(response value: String?) {
        self = value.flatMap(ServiceTier.init(rawValue:)) ?? .standard
    }
}

/// A tier's price, USD per million tokens.
struct TierPrice: Codable, Hashable, Sendable {
    var prompt: Double
    var completion: Double

    var label: String { "\(Money.perMillion(prompt)) / \(Money.perMillion(completion))" }
}

/// How OpenRouter picks among a model's providers. They can differ several times in price, speed
/// and precision for the same model.
enum ProviderRouting: String, CaseIterable, Identifiable, Sendable {
    case balanced, cheapest, fastest, quality, openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .cheapest: return "Cheapest"
        case .fastest: return "Fastest"
        case .quality: return "Best quality"
        case .openRouter: return "OpenRouter default"
        }
    }

    /// Below these a provider is tried only after the ones that meet them.
    static let minThroughput = 40.0   // tok/s, median
    static let maxLatency = 3.0       // seconds to first token, median

    /// Precisions that don't make a model noticeably dumber; "unknown" is mostly first-party hosts.
    static let goodQuants: Set<String> = ["int8", "fp8", "fp16", "bf16", "fp32", "unknown"]
    static let fullQuants: Set<String> = ["fp16", "bf16", "fp32", "unknown"]

    /// The request's `provider` object. `quants` are the precisions the model's providers run
    /// (nil when not looked up yet); a filter is only sent when some provider passes it, so a
    /// request never ends up with no provider at all.
    func preferences(quants: [String]?) -> JSONValue? {
        func filter(_ allowed: Set<String>) -> JSONValue? {
            guard let quants else { return nil }
            let kept = quants.filter(allowed.contains).sorted()
            guard !kept.isEmpty, kept.count < Set(quants).count else { return nil }
            return .array(kept.map { .string($0) })
        }
        var p: [String: JSONValue] = [:]
        switch self {
        case .openRouter:
            return nil
        case .cheapest:
            p["sort"] = .string("price")
        case .fastest:
            p["sort"] = .string("throughput")
            p["quantizations"] = filter(Self.goodQuants)
        case .balanced, .quality:
            // The cheapest provider that is fast enough, else the cheapest of the slow ones.
            p["sort"] = .string("price")
            p["preferred_min_throughput"] = .number(Self.minThroughput)
            p["preferred_max_latency"] = .number(Self.maxLatency)
            p["quantizations"] = filter(self == .quality ? Self.fullQuants : Self.goodQuants)
        }
        return .object(p)
    }
}
