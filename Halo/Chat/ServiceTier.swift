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
