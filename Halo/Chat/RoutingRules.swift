import Foundation

/// A provider endpoint in the form Halo ranks, caches and shows in routing settings.
struct EndpointInfo: Codable, Hashable, Sendable, Identifiable {
    var slug: String
    var name: String
    /// OpenRouter's endpoint tag, such as `relace` or `z-ai/fp8`.
    var tag: String
    var tier: ServiceTier
    var prompt: Double
    var completion: Double
    var quant: String
    var tps: Double?
    var latency: Double?
    var uptime: Double?

    var id: String { "\(tier.rawValue)|\(tag)" }

    init(slug: String, name: String, tag: String? = nil, tier: ServiceTier = .standard,
         prompt: Double, completion: Double, quant: String = "unknown",
         tps: Double? = nil, latency: Double? = nil, uptime: Double? = nil) {
        self.slug = slug
        self.name = name
        self.tag = tag ?? slug
        self.tier = tier
        self.prompt = prompt
        self.completion = completion
        self.quant = quant
        self.tps = tps
        self.latency = latency
        self.uptime = uptime
    }
}

/// Provider rules that apply to one model instead of the global defaults.
struct ModelRouting: Codable, Hashable, Sendable {
    var pinned: [String] = []
    var blocked: [String] = []

    init(pinned: [String] = [], blocked: [String] = []) {
        self.pinned = pinned
        self.blocked = blocked
    }

    private enum CodingKeys: String, CodingKey { case pinned, blocked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
    }
}

/// Visible, editable provider rules. Soft thresholds affect order; precision and price are hard
/// filters unless using them together would leave the model with no provider at all.
struct RoutingRules: Codable, Hashable, Sendable {
    enum Sort: String, Codable, CaseIterable, Sendable {
        case price, throughput, latency, none
    }

    enum Precision: String, Codable, CaseIterable, Sendable {
        case any, eightBit, full

        var allowed: Set<String>? {
            switch self {
            case .any: return nil
            case .eightBit: return ["int8", "fp8", "fp16", "bf16", "fp32", "unknown"]
            case .full: return ["fp16", "bf16", "fp32", "unknown"]
            }
        }
    }

    enum RankStatus: Hashable, Sendable {
        case pick(Int)
        case skipped(reason: String)
    }

    var sort: Sort = .price
    var minThroughput: Double? = 40
    var maxLatency: Double? = 3
    var precision: Precision = .eightBit
    var maxPrompt: Double? = nil
    var maxCompletion: Double? = nil
    var allowFallbacks = true
    var denyDataCollection = false
    var blocked: [String] = []
    var stickyPerChat = false

    init(sort: Sort = .price, minThroughput: Double? = 40, maxLatency: Double? = 3,
         precision: Precision = .eightBit, maxPrompt: Double? = nil, maxCompletion: Double? = nil,
         allowFallbacks: Bool = true, denyDataCollection: Bool = false, blocked: [String] = [],
         stickyPerChat: Bool = false) {
        self.sort = sort
        self.minThroughput = minThroughput
        self.maxLatency = maxLatency
        self.precision = precision
        self.maxPrompt = maxPrompt
        self.maxCompletion = maxCompletion
        self.allowFallbacks = allowFallbacks
        self.denyDataCollection = denyDataCollection
        self.blocked = blocked
        self.stickyPerChat = stickyPerChat
    }

    private enum CodingKeys: String, CodingKey {
        case sort, minThroughput, maxLatency, precision, maxPrompt, maxCompletion
        case allowFallbacks, denyDataCollection, blocked, stickyPerChat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = try c.decodeIfPresent(Sort.self, forKey: .sort) ?? .price
        minThroughput = c.contains(.minThroughput) ? try c.decodeIfPresent(Double.self, forKey: .minThroughput) : 40
        maxLatency = c.contains(.maxLatency) ? try c.decodeIfPresent(Double.self, forKey: .maxLatency) : 3
        precision = try c.decodeIfPresent(Precision.self, forKey: .precision) ?? .eightBit
        maxPrompt = try c.decodeIfPresent(Double.self, forKey: .maxPrompt)
        maxCompletion = try c.decodeIfPresent(Double.self, forKey: .maxCompletion)
        allowFallbacks = try c.decodeIfPresent(Bool.self, forKey: .allowFallbacks) ?? true
        denyDataCollection = try c.decodeIfPresent(Bool.self, forKey: .denyDataCollection) ?? false
        blocked = try c.decodeIfPresent([String].self, forKey: .blocked) ?? []
        stickyPerChat = try c.decodeIfPresent(Bool.self, forKey: .stickyPerChat) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sort, forKey: .sort)
        // Explicit null distinguishes Off from an older payload that predates these fields.
        try c.encode(minThroughput, forKey: .minThroughput)
        try c.encode(maxLatency, forKey: .maxLatency)
        try c.encode(precision, forKey: .precision)
        try c.encode(maxPrompt, forKey: .maxPrompt)
        try c.encode(maxCompletion, forKey: .maxCompletion)
        try c.encode(allowFallbacks, forKey: .allowFallbacks)
        try c.encode(denyDataCollection, forKey: .denyDataCollection)
        try c.encode(blocked, forKey: .blocked)
        try c.encode(stickyPerChat, forKey: .stickyPerChat)
    }

    var matchingPreset: RoutingPreset? {
        // Blocking hosts is independent for every preset. Data policy is also independent in the
        // OpenRouter preset, whose whole purpose is to send only those two routing policies.
        var mine = self
        mine.blocked = []
        for preset in RoutingPreset.allCases {
            var candidate = mine
            var rules = preset.rules
            rules.blocked = []
            if preset == .openRouter {
                candidate.denyDataCollection = false
                rules.denyDataCollection = false
            }
            if candidate == rules { return preset }
        }
        return nil
    }

    /// The request's `provider` object, using the same local order shown in routing settings.
    func preferences(for modelID: String, endpoints: [EndpointInfo]?, model: ModelRouting? = nil,
                     lastProvider: String? = nil, tier: ServiceTier = .standard) -> JSONValue? {
        var p: [String: JSONValue] = [:]
        let pinned = Set(model?.pinned ?? [])
        let ignored = Set(blocked + (model?.blocked ?? [])).subtracting(pinned).sorted()
        if !ignored.isEmpty { p["ignore"] = .array(ignored.map { .string($0) }) }
        if denyDataCollection { p["data_collection"] = "deny" }

        // This preset really is OpenRouter's choice, not a local price sort under another name.
        guard matchingPreset != .openRouter else { return p.isEmpty ? nil : .object(p) }

        if sort != .none { p["sort"] = .string(sort.rawValue) }
        if let minThroughput { p["preferred_min_throughput"] = .number(minThroughput) }
        if let maxLatency { p["preferred_max_latency"] = .number(maxLatency) }
        p["allow_fallbacks"] = .bool(allowFallbacks)

        guard let endpoints else {
            // Precision isn't safe without knowing whether the model has any matching endpoint.
            if maxPrompt != nil || maxCompletion != nil {
                var price: [String: JSONValue] = [:]
                if let maxPrompt { price["prompt"] = .number(maxPrompt) }
                if let maxCompletion { price["completion"] = .number(maxCompletion) }
                p["max_price"] = .object(price)
            }
            return .object(p)
        }

        let effective = Self.effectiveRules(endpoints, rules: self, model: model, tier: tier)
        let candidates = endpoints.filter { $0.tier == tier && !Self.isBlocked($0, rules: self, model: model) }
        if let allowed = effective.precision.allowed {
            let available = Set(candidates.map(\.quant))
            let kept = available.intersection(allowed).sorted()
            if !kept.isEmpty, kept.count < available.count {
                p["quantizations"] = .array(kept.map { .string($0) })
            }
        }
        if effective.maxPrompt != nil || effective.maxCompletion != nil,
           candidates.contains(where: { Self.passesHardFilters($0, rules: effective) }) {
            var price: [String: JSONValue] = [:]
            if let maxPrompt = effective.maxPrompt { price["prompt"] = .number(maxPrompt) }
            if let maxCompletion = effective.maxCompletion { price["completion"] = .number(maxCompletion) }
            p["max_price"] = .object(price)
        }

        let ranked = Self.rank(endpoints, rules: self, model: model, tier: tier)
        var picks = ranked.compactMap { endpoint, status -> EndpointInfo? in
            if case .pick = status { return endpoint }
            return nil
        }
        if stickyPerChat, let lastProvider {
            let sticky = Set(endpoints.filter {
                $0.name.caseInsensitiveCompare(lastProvider) == .orderedSame
                    || $0.slug.caseInsensitiveCompare(lastProvider) == .orderedSame
                    || $0.tag.caseInsensitiveCompare(lastProvider) == .orderedSame
            }.map(\.slug))
            if !sticky.isEmpty {
                let pins = picks.filter { pinned.contains($0.slug) }
                let rest = picks.filter { !pinned.contains($0.slug) }
                picks = pins + rest.filter { sticky.contains($0.slug) } + rest.filter { !sticky.contains($0.slug) }
            }
        }
        var seen: Set<String> = []
        let order = picks.map(\.tag).filter { seen.insert($0).inserted }.prefix(8)
        if !order.isEmpty { p["order"] = .array(order.map { .string($0) }) }
        return .object(p)
    }

    /// Providers in the exact order Halo sends, followed by endpoints excluded from that order.
    static func rank(_ eps: [EndpointInfo], rules: RoutingRules, model: ModelRouting? = nil,
                     tier: ServiceTier = .standard) -> [(EndpointInfo, RankStatus)] {
        let effective = effectiveRules(eps, rules: rules, model: model, tier: tier)
        let pins = model?.pinned ?? []
        let eligible = eps.indices.filter { i in
            let ep = eps[i]
            return ep.tier == tier && !isBlocked(ep, rules: rules, model: model)
                && passesHardFilters(ep, rules: effective)
        }
        let pinned = eligible.filter { pins.contains(eps[$0].slug) }.sorted { a, b in
            let ap = pins.firstIndex(of: eps[a].slug) ?? 0
            let bp = pins.firstIndex(of: eps[b].slug) ?? 0
            return ap == bp ? isOrderedBefore(eps[a], eps[b], sort: effective.sort, a: a, b: b) : ap < bp
        }
        let rest = eligible.filter { !pins.contains(eps[$0].slug) }
        let fast = rest.filter { meetsSoftThresholds(eps[$0], rules: effective) }
        let slow = rest.filter { !meetsSoftThresholds(eps[$0], rules: effective) }
        let sortedRest = sortIndices(fast, eps: eps, sort: effective.sort)
            + sortIndices(slow, eps: eps, sort: effective.sort)
        let ordered = pinned + sortedRest
        var result: [(EndpointInfo, RankStatus)] = ordered.enumerated().map {
            (eps[$0.element], .pick($0.offset + 1))
        }
        let picked = Set(ordered)
        result += eps.indices.filter { !picked.contains($0) }.map { i in
            let ep = eps[i]
            let reason: String
            if ep.tier != tier { reason = "other tier" }
            else if isBlocked(ep, rules: rules, model: model) { reason = "blocked" }
            else if !passesPrecision(ep, precision: effective.precision) { reason = precisionReason(ep.quant) }
            else { reason = "over max price" }
            return (ep, .skipped(reason: reason))
        }
        return result
    }

    static func meetsSoftThresholds(_ ep: EndpointInfo, rules: RoutingRules) -> Bool {
        if let minimum = rules.minThroughput, ep.tps ?? -.infinity < minimum { return false }
        if let maximum = rules.maxLatency, ep.latency ?? .infinity > maximum { return false }
        return true
    }

    /// Explains a hard filter Halo had to relax to keep the model usable.
    static func hardFilterWarning(_ eps: [EndpointInfo], rules: RoutingRules,
                                  model: ModelRouting? = nil, tier: ServiceTier = .standard) -> String? {
        let effective = effectiveRules(eps, rules: rules, model: model, tier: tier)
        var dropped: [String] = []
        if (rules.maxPrompt != nil || rules.maxCompletion != nil)
            && effective.maxPrompt == nil && effective.maxCompletion == nil { dropped.append("price limit") }
        if rules.precision != .any && effective.precision == .any { dropped.append("precision filter") }
        guard !dropped.isEmpty else { return nil }
        return "No provider fits — \(dropped.joined(separator: " and ")) ignored for this model"
    }

    private static func effectiveRules(_ eps: [EndpointInfo], rules: RoutingRules,
                                       model: ModelRouting?, tier: ServiceTier) -> RoutingRules {
        let candidates = eps.filter { $0.tier == tier && !isBlocked($0, rules: rules, model: model) }
        guard !candidates.isEmpty else { return rules }
        if candidates.contains(where: { passesHardFilters($0, rules: rules) }) { return rules }
        var effective = rules
        effective.maxPrompt = nil
        effective.maxCompletion = nil
        if candidates.contains(where: { passesHardFilters($0, rules: effective) }) { return effective }
        effective.precision = .any
        return effective
    }

    private static func isBlocked(_ ep: EndpointInfo, rules: RoutingRules, model: ModelRouting?) -> Bool {
        if model?.pinned.contains(ep.slug) == true { return false }
        return rules.blocked.contains(ep.slug) || model?.blocked.contains(ep.slug) == true
    }

    private static func passesHardFilters(_ ep: EndpointInfo, rules: RoutingRules) -> Bool {
        passesPrecision(ep, precision: rules.precision)
            && rules.maxPrompt.map { ep.prompt <= $0 } != false
            && rules.maxCompletion.map { ep.completion <= $0 } != false
    }

    private static func passesPrecision(_ ep: EndpointInfo, precision: Precision) -> Bool {
        precision.allowed?.contains(ep.quant) ?? true
    }

    private static func precisionReason(_ quant: String) -> String {
        if quant.contains("4") { return "4-bit" }
        if quant.contains("6") { return "6-bit" }
        if quant.contains("8") { return "8-bit" }
        return quant
    }

    private static func sortIndices(_ indices: [Int], eps: [EndpointInfo], sort: Sort) -> [Int] {
        indices.sorted { isOrderedBefore(eps[$0], eps[$1], sort: sort, a: $0, b: $1) }
    }

    private static func isOrderedBefore(_ lhs: EndpointInfo, _ rhs: EndpointInfo,
                                        sort: Sort, a: Int, b: Int) -> Bool {
        switch sort {
        case .price:
            // A typical chat is input-heavy: three input tokens for every output token.
            let l = lhs.prompt * 3 + lhs.completion
            let r = rhs.prompt * 3 + rhs.completion
            if l != r { return l < r }
        case .throughput:
            if lhs.tps != rhs.tps { return lhs.tps ?? -.infinity > rhs.tps ?? -.infinity }
        case .latency:
            if lhs.latency != rhs.latency { return lhs.latency ?? .infinity < rhs.latency ?? .infinity }
        case .none:
            return a < b
        }
        if lhs.tag != rhs.tag { return lhs.tag < rhs.tag }
        return a < b
    }
}

enum RoutingPreset: String, CaseIterable, Identifiable, Sendable {
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

    var subtitle: String {
        switch self {
        case .balanced: return "Cheapest host that's fast and not dumbed down"
        case .cheapest: return "Lowest price, whatever the speed"
        case .fastest: return "Highest tok/s, whatever the price"
        case .quality: return "Full precision only, then cheapest fast"
        case .openRouter: return "Let OpenRouter balance it"
        }
    }

    var rules: RoutingRules {
        switch self {
        case .balanced:
            return RoutingRules()
        case .cheapest:
            return RoutingRules(sort: .price, minThroughput: nil, maxLatency: nil, precision: .any)
        case .fastest:
            return RoutingRules(sort: .throughput, minThroughput: nil, maxLatency: nil, precision: .eightBit)
        case .quality:
            return RoutingRules(precision: .full)
        case .openRouter:
            return RoutingRules(sort: .none, minThroughput: nil, maxLatency: nil, precision: .any)
        }
    }
}
