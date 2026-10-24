import Foundation

/// OpenRouter's search prices, USD per search, from its web search docs. Native search is priced
/// per model in the catalog (`pricing.web_search`).
enum SearchPrices {
    /// Exa by mode (fast and auto cost the same; deep costs more).
    static let exaFast = 0.007
    static let exaAuto = 0.007
    static let exaDeep = 0.012
    /// Parallel by mode.
    static let parallelTurbo = 0.001
    static let parallelBasic = 0.005
    static let parallelAdvanced = 0.005
    static let perplexity = 0.005
    /// Firecrawl charges per search plus per result returned.
    static let firecrawlSearch = 0.005
    static let firecrawlPerResult = 0.0125
    /// Exa and Parallel include 10 results, then charge per extra one.
    static let includedResults = 10
    static let extraResult = 0.001

    /// "$0.007", "$0.08": enough digits for a fraction of a cent, without trailing zeros.
    static func format(_ value: Double) -> String {
        var s = String(format: "%.3f", value)
        while s.hasSuffix("0"), s.split(separator: ".").last.map({ $0.count > 2 }) == true { s.removeLast() }
        return "$" + s
    }
}

/// Who runs a chat's web searches. `auto` is the model's own search where it has one, else Exa.
enum SearchEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, native, exa, parallel, perplexity, firecrawl

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .native: return "Model's own"
        case .exa: return "Exa"
        case .parallel: return "Parallel"
        case .perplexity: return "Perplexity"
        case .firecrawl: return "Firecrawl"
        }
    }
    var detail: String {
        switch self {
        case .auto: return "The model's own search where it has one, else Exa"
        case .native: return "OpenAI, Claude, Gemini or Grok's search; else Exa"
        case .exa: return "Fast, with quoted excerpts; Deep digs further"
        case .parallel: return "Cheapest quick searches"
        case .perplexity: return "Ranked results from Perplexity"
        case .firecrawl: return "Charged per result, so the priciest"
        }
    }
}

/// How hard a search digs: how many results, how much of each page, and how many searches a reply may run.
enum SearchDepth: String, Codable, CaseIterable, Sendable, Identifiable {
    case quick, standard, deep

    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: return "Quick"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }
    var detail: String {
        switch self {
        case .quick: return "Fast, a few sources"
        case .standard: return "A good spread of sources"
        case .deep: return "More sources, read further"
        }
    }

    var maxResults: Int {
        switch self {
        case .quick: return 3
        case .standard: return 6
        case .deep: return 10
        }
    }
    var contextSize: String {
        switch self {
        case .quick: return "low"
        case .standard: return "medium"
        case .deep: return "high"
        }
    }
    var exaMode: String {
        switch self {
        case .quick: return "fast"
        case .standard: return "auto"
        case .deep: return "deep"
        }
    }
    var parallelMode: String {
        switch self {
        case .quick: return "turbo"
        case .standard: return "basic"
        case .deep: return "advanced"
        }
    }
    /// Searches per reply; only Claude's own search honours it.
    var maxUses: Int {
        switch self {
        case .quick: return 2
        case .standard: return 5
        case .deep: return 10
        }
    }
    /// The request's `max_tool_calls`, shared by every server tool.
    var maxToolCalls: Int {
        switch self {
        case .quick: return 4
        case .standard: return 8
        case .deep: return 16
        }
    }
}

/// Which sites searches may use. One list in one mode: most engines reject both lists at once.
enum DomainFilterMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, only, exclude

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Any site"
        case .only: return "Only these sites"
        case .exclude: return "Never these sites"
        }
    }

    /// "https://www.Example.com/path" → "example.com"; nil when nothing is left.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.contains(".") && !s.contains(" ") ? s : nil
    }
}

/// Everything that shapes a chat's `openrouter:web_search` tool.
struct SearchConfig: Codable, Hashable, Sendable {
    var engine: SearchEngine = .auto
    var depth: SearchDepth = .standard
    var filter: DomainFilterMode = .none
    var domains: [String] = []

    /// Google's own search rejects domain filters, and `native` won't fall back to Exa for them.
    private func dropsFilter(modelID: String) -> Bool {
        engine == .native && modelID.hasPrefix("google/")
    }

    func toolParameters(modelID: String) -> JSONValue {
        var p: [String: JSONValue] = [
            "max_results": .number(Double(min(depth.maxResults, engine == .perplexity ? 20 : 25))),
            "search_context_size": .string(depth.contextSize),
            "max_uses": .number(Double(depth.maxUses)),
        ]
        if engine != .auto { p["engine"] = .string(engine.rawValue) }
        // Modes only mean something to Exa and Parallel, so they go only when one is chosen outright.
        if engine == .exa { p["mode"] = .string(depth.exaMode) }
        if engine == .parallel { p["mode"] = .string(depth.parallelMode) }
        if !domains.isEmpty, !dropsFilter(modelID: modelID) {
            switch filter {
            case .none: break
            case .only: p["allowed_domains"] = .array(domains.map { .string($0) })
            case .exclude: p["excluded_domains"] = .array(domains.map { .string($0) })
            }
        }
        return .object(p)
    }

    var maxToolCalls: Int { depth.maxToolCalls }

    /// The legacy `web` plugin, for models that can't call tools.
    var pluginParameters: JSONValue {
        var p: [String: JSONValue] = ["id": "web", "max_results": .number(Double(depth.maxResults))]
        if engine != .auto { p["engine"] = .string(engine.rawValue) }
        return .object(p)
    }

    /// Roughly what one search costs, before the model's own tokens. Nil when unknown (a model's own
    /// search with no listed price).
    func estimatedCostPerSearch(model: ORModel?) -> Double? {
        let native = model?.pricing?.webSearch?.value.flatMap { $0 > 0 ? $0 : nil }
        switch engine {
        case .auto: return native ?? exaCost
        case .native: return native ?? exaCost
        case .exa: return exaCost
        case .parallel:
            let base: Double = switch depth {
            case .quick: SearchPrices.parallelTurbo
            case .standard: SearchPrices.parallelBasic
            case .deep: SearchPrices.parallelAdvanced
            }
            return base + extraResults
        case .perplexity: return SearchPrices.perplexity
        case .firecrawl: return SearchPrices.firecrawlSearch + SearchPrices.firecrawlPerResult * Double(depth.maxResults)
        }
    }

    /// Exa as OpenRouter runs it on `auto`: mode `auto`, unless Exa is chosen and the depth picks a mode.
    private var exaCost: Double {
        let base: Double = switch engine == .exa ? depth : .standard {
        case .quick: SearchPrices.exaFast
        case .standard: SearchPrices.exaAuto
        case .deep: SearchPrices.exaDeep
        }
        return base + extraResults
    }

    private var extraResults: Double {
        Double(max(0, depth.maxResults - SearchPrices.includedResults)) * SearchPrices.extraResult
    }

    /// Stored on a reply so its details can price the searches it ran.
    var encoded: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    init(encoded: String) throws { self = try JSONDecoder().decode(Self.self, from: Data(encoded.utf8)) }
    init(engine: SearchEngine = .auto, depth: SearchDepth = .standard, filter: DomainFilterMode = .none, domains: [String] = []) {
        self.engine = engine
        self.depth = depth
        self.filter = filter
        self.domains = domains
    }
}
