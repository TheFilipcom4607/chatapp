import Foundation

// MARK: - Models catalog

struct ORModel: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var contextLength: Int?
    var created: Double?
    var pricing: Pricing?
    var architecture: Architecture?
    var supportedParameters: [String]?
    var reasoning: ReasoningInfo?
    var supportedVoices: [String]?
    var topProvider: TopProvider?
    var canonicalSlug: String?
    var benchmarks: Benchmarks?

    enum CodingKeys: String, CodingKey {
        case id, name, description, created, pricing, architecture, reasoning, benchmarks
        case canonicalSlug = "canonical_slug"
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
        case supportedVoices = "supported_voices"
        case topProvider = "top_provider"
    }

    struct Pricing: Codable, Hashable, Sendable {
        var prompt: FlexibleDouble?
        var completion: FlexibleDouble?
        var request: FlexibleDouble?
        var image: FlexibleDouble?
        var webSearch: FlexibleDouble?
        var inputCacheRead: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case prompt, completion, request, image
            case webSearch = "web_search"
            case inputCacheRead = "input_cache_read"
        }
    }

    struct Architecture: Codable, Hashable, Sendable {
        var inputModalities: [String]?
        var outputModalities: [String]?
        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    struct ReasoningInfo: Codable, Hashable, Sendable {
        var supportedEfforts: [String]?
        var defaultEffort: String?
        var mandatory: Bool?
        enum CodingKeys: String, CodingKey {
            case mandatory
            case supportedEfforts = "supported_efforts"
            case defaultEffort = "default_effort"
        }
    }

    struct TopProvider: Codable, Hashable, Sendable {
        var maxCompletionTokens: Int?
        enum CodingKeys: String, CodingKey { case maxCompletionTokens = "max_completion_tokens" }
    }

    /// Only Artificial Analysis is decoded; `design_arena` is ignored.
    struct Benchmarks: Codable, Hashable, Sendable {
        var artificialAnalysis: AAScores?
        enum CodingKeys: String, CodingKey { case artificialAnalysis = "artificial_analysis" }
    }

    /// Artificial Analysis indexes at the model's best effort.
    struct AAScores: Codable, Hashable, Sendable {
        var intelligenceIndex: Double?
        var codingIndex: Double?
        var agenticIndex: Double?
        enum CodingKeys: String, CodingKey {
            case intelligenceIndex = "intelligence_index"
            case codingIndex = "coding_index"
            case agenticIndex = "agentic_index"
        }
    }

    // Convenience

    /// "Anthropic: Claude Sonnet 5.5" → "Claude Sonnet 5.5"
    var shortName: String {
        if let r = name.range(of: ": ") { return String(name[r.upperBound...]) }
        return name
    }
    var providerName: String {
        if let r = name.range(of: ": ") { return String(name[..<r.lowerBound]) }
        return id.split(separator: "/").first.map(String.init)?.capitalized ?? ""
    }
    var supportsTools: Bool { supportedParameters?.contains("tools") ?? false }
    var supportsReasoning: Bool { supportedParameters?.contains("reasoning") ?? false }
    var supportsVision: Bool { architecture?.inputModalities?.contains("image") ?? false }
    var supportsFiles: Bool { architecture?.inputModalities?.contains("file") ?? false }
    var supportsAudioInput: Bool { architecture?.inputModalities?.contains("audio") ?? false }
    var isFree: Bool { id.hasSuffix(":free") || ((pricing?.prompt?.value ?? 1) == 0 && (pricing?.completion?.value ?? 1) == 0) }
    /// Routers such as openrouter/auto are priced "-1": it depends on the model they pick.
    var hasVariablePrice: Bool { (pricing?.prompt?.value ?? 0) < 0 || (pricing?.completion?.value ?? 0) < 0 }
    /// Nil when unknown, including a router's "-1".
    var promptPricePerMillion: Double? { pricing?.prompt?.value.flatMap { $0 < 0 ? nil : $0 * 1_000_000 } }
    var completionPricePerMillion: Double? { pricing?.completion?.value.flatMap { $0 < 0 ? nil : $0 * 1_000_000 } }
    var intelligence: Double? { benchmarks?.artificialAnalysis?.intelligenceIndex }
    var coding: Double? { benchmarks?.artificialAnalysis?.codingIndex }
    var agentic: Double? { benchmarks?.artificialAnalysis?.agenticIndex }
    /// Search that ignores case, spaces and punctuation, so "gpt 6" and "gpt6" find "GPT-6".
    func matches(search query: String) -> Bool {
        let q = Self.searchKey(query)
        guard !q.isEmpty else { return id.localizedCaseInsensitiveContains(query) || name.localizedCaseInsensitiveContains(query) }
        return Self.searchKey(id).contains(q) || Self.searchKey(name).contains(q)
    }
    private static func searchKey(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    var reasoningEfforts: [String] {
        guard supportsReasoning else { return [] }
        let efforts = reasoning?.supportedEfforts ?? ["high", "medium", "low"]
        return reasoning?.mandatory == true ? efforts.filter { $0 != "none" } : efforts
    }
}

struct ModelList<T: Decodable & Sendable>: Decodable, Sendable {
    var data: [T]
}

/// One row of OpenRouter's unofficial per-effort Artificial Analysis list, e.g.
/// "Claude Sonnet 5.5 (High, Default Fallback)" for `anthropic/claude-sonnet-5.5-20260928`.
struct AAEffortRow: Decodable, Sendable {
    var permaslug: String
    var aaName: String
    var benchmarkData: BenchmarkData?

    enum CodingKeys: String, CodingKey {
        case permaslug
        case aaName = "aa_name"
        case benchmarkData = "benchmark_data"
    }

    struct BenchmarkData: Decodable, Sendable {
        var evaluations: Evaluations?
    }

    struct Evaluations: Decodable, Sendable {
        var intelligenceIndex: Double?
        enum CodingKeys: String, CodingKey { case intelligenceIndex = "artificial_analysis_intelligence_index" }
    }

    var intelligence: Double? { benchmarkData?.evaluations?.intelligenceIndex }

    /// The effort named first in the parentheses, as the API spells it; nil for "(Reasoning)",
    /// dates, "Preview" and the like.
    var effort: String? {
        guard let open = aaName.firstIndex(of: "(") else { return nil }
        let inside = aaName[aaName.index(after: open)...].prefix { $0 != "," && $0 != ")" }
        let word = inside.trimmingCharacters(in: .whitespaces).lowercased()
        switch word {
        case "low", "minimal", "medium", "high", "xhigh", "max": return word
        case "non-reasoning": return "none"
        default: return nil
        }
    }
}

// MARK: - Image models (/images/models)

struct ImageModelInfo: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var architecture: ORModel.Architecture?
    var supportedParameters: [String: ParamDescriptor]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, architecture
        case supportedParameters = "supported_parameters"
    }

    struct ParamDescriptor: Decodable, Hashable, Sendable {
        var type: String?
        var values: [String]?
        var min: Double?
        var max: Double?
    }

    var shortName: String {
        if let r = name.range(of: ": ") { return String(name[r.upperBound...]) }
        return name
    }
    var aspectRatios: [String] { supportedParameters?["aspect_ratio"]?.values ?? [] }
    var resolutions: [String] { supportedParameters?["resolution"]?.values ?? [] }
    var supportsReferences: Bool { (supportedParameters?["input_references"]?.max ?? 0) > 0 }
}

/// `/models/{id}/endpoints`: every provider endpoint for a chat model, one per tier it sells.
struct ModelEndpoints: Decodable, Sendable {
    var data: Payload

    struct Payload: Decodable, Sendable {
        var endpoints: [Endpoint]
    }

    struct Endpoint: Decodable, Sendable {
        var pricing: ORModel.Pricing?
        var serviceTier: String?
        enum CodingKeys: String, CodingKey {
            case pricing
            case serviceTier = "service_tier"
        }
    }

    /// The cheapest price for each tier on offer.
    var tierPrices: [ServiceTier: TierPrice] {
        var result: [ServiceTier: TierPrice] = [:]
        for e in data.endpoints {
            guard let tier = ServiceTier(rawValue: e.serviceTier ?? "standard"),
                  let p = e.pricing?.prompt?.value, let c = e.pricing?.completion?.value else { continue }
            let price = TierPrice(prompt: p * 1_000_000, completion: c * 1_000_000)
            if let old = result[tier], old.prompt + old.completion <= price.prompt + price.completion { continue }
            result[tier] = price
        }
        return result
    }
}

struct ImageEndpoints: Decodable, Sendable {
    var id: String
    var endpoints: [Endpoint]

    struct Endpoint: Decodable, Sendable {
        var providerName: String?
        var pricing: [PriceItem]?
        enum CodingKeys: String, CodingKey {
            case pricing
            case providerName = "provider_name"
        }
    }

    struct PriceItem: Decodable, Sendable {
        var billable: String?
        var unit: String?
        var costUSD: Double?
        enum CodingKeys: String, CodingKey {
            case billable, unit
            case costUSD = "cost_usd"
        }
    }

    /// Rough per-image estimate. Token-priced models are assumed ~1300 output tokens (≈1K image).
    var estimatedCostPerImage: Double? {
        let prices = endpoints.compactMap { e -> Double? in
            guard let item = e.pricing?.first(where: { $0.billable == "output_image" }), let cost = item.costUSD else { return nil }
            switch item.unit {
            case "image": return cost
            case "megapixel": return cost * 1.05
            case "token": return cost * 1300
            default: return cost
            }
        }
        return prices.min()
    }
}

// MARK: - Images (/images)

struct ImageGenerationRequest: Encodable, Sendable {
    var model: String
    var prompt: String
    var aspectRatio: String?
    var resolution: String?
    var n: Int?
    var inputReferences: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case model, prompt, resolution, n
        case aspectRatio = "aspect_ratio"
        case inputReferences = "input_references"
    }
}

struct ImageGenerationResponse: Decodable, Sendable {
    var data: [Item]
    var usage: Usage?

    struct Item: Decodable, Sendable {
        var b64JSON: String?
        var url: String?
        var mediaType: String?
        enum CodingKeys: String, CodingKey {
            case url
            case b64JSON = "b64_json"
            case mediaType = "media_type"
        }
    }
}

// MARK: - Speech (/audio/speech)

struct SpeechRequest: Encodable, Sendable {
    var model: String
    var input: String
    var voice: String?
    var instructions: String?
    var responseFormat: String = "mp3"
    var speed: Double?

    enum CodingKeys: String, CodingKey {
        case model, input, voice, instructions, speed
        case responseFormat = "response_format"
    }
}

// MARK: - Video (/videos)

struct VideoModelInfo: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var supportedResolutions: [String]?
    var supportedAspectRatios: [String]?
    var supportedDurations: [Int]?
    var supportedFrameImages: [String]?
    var generateAudio: Bool?
    var pricingSkus: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case supportedResolutions = "supported_resolutions"
        case supportedAspectRatios = "supported_aspect_ratios"
        case supportedDurations = "supported_durations"
        case supportedFrameImages = "supported_frame_images"
        case generateAudio = "generate_audio"
        case pricingSkus = "pricing_skus"
    }

    var shortName: String {
        if let r = name.range(of: ": ") { return String(name[r.upperBound...]) }
        return name
    }
    var supportsFirstFrame: Bool { supportedFrameImages?.contains("first_frame") ?? false }

    /// Best-effort cost estimate from the SKU map (formats vary per provider).
    func estimatedCost(seconds: Int, resolution: String?, audio: Bool) -> Double? {
        guard let skus = pricingSkus, !skus.isEmpty else { return nil }
        let res = (resolution ?? "").lowercased()
        func value(_ key: String) -> Double? { skus[key].flatMap(Double.init) }
        // Prefer keys mentioning seconds and the chosen resolution / audio mode.
        let secondKeys = skus.keys.filter { $0.contains("second") }
        if !secondKeys.isEmpty {
            func score(_ k: String) -> Int {
                var s = 0
                if !res.isEmpty, k.contains(res) { s += 4 }
                if audio, k.contains("with_audio") { s += 2 }
                if !audio, k.contains("without_audio") { s += 2 }
                if k.contains("reference") || k.contains("input") { s -= 5 }
                // Penalize resolution-specific keys that don't match.
                for r in ["480p", "720p", "768p", "1080p", "2k", "4k"] where r != res && k.contains(r) { s -= 3 }
                return s
            }
            if let best = secondKeys.max(by: { score($0) < score($1) }), var per = value(best) {
                if best.hasPrefix("cents") { per /= 100 }
                return per * Double(seconds)
            }
        }
        if let generate = value("generate") { return generate }
        return nil
    }
}

struct VideoGenerationRequest: Encodable, Sendable {
    var model: String
    var prompt: String
    var duration: Int?
    var resolution: String?
    var aspectRatio: String?
    var generateAudio: Bool?
    var frameImages: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case model, prompt, duration, resolution
        case aspectRatio = "aspect_ratio"
        case generateAudio = "generate_audio"
        case frameImages = "frame_images"
    }
}

struct VideoJob: Decodable, Sendable {
    var id: String
    var pollingURL: String?
    var status: String
    var urls: [String]?
    var unsignedURLs: [String]?
    var error: String?
    var usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, status, urls, error, usage
        case pollingURL = "polling_url"
        case unsignedURLs = "unsigned_urls"
    }

    var isTerminal: Bool { ["completed", "failed", "cancelled", "expired"].contains(status) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pollingURL = try c.decodeIfPresent(String.self, forKey: .pollingURL)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        urls = try c.decodeIfPresent([String].self, forKey: .urls)
        unsignedURLs = try c.decodeIfPresent([String].self, forKey: .unsignedURLs)
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        // `error` is documented as a string but tolerate objects.
        if let s = try? c.decodeIfPresent(String.self, forKey: .error) { error = s }
        else if let o = try? c.decodeIfPresent(APIErrorBody.self, forKey: .error) { error = o.message }
        else { error = nil }
    }
}

// MARK: - Account

struct KeyInfo: Decodable, Sendable, Hashable {
    var label: String?
    var limit: Double?
    var limitRemaining: Double?
    var limitReset: String?
    var usage: Double?
    var usageDaily: Double?
    var usageWeekly: Double?
    var usageMonthly: Double?
    var isFreeTier: Bool?

    enum CodingKeys: String, CodingKey {
        case label, limit, usage
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case isFreeTier = "is_free_tier"
    }
}

struct DataEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    var data: T
}

struct CreditsInfo: Decodable, Sendable, Hashable {
    var totalCredits: Double
    var totalUsage: Double
    var balance: Double { totalCredits - totalUsage }

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

struct GenerationStats: Decodable, Sendable, Hashable {
    var id: String?
    var model: String?
    var providerName: String?
    var totalCost: Double?
    var latency: Double?
    var generationTime: Double?
    var tokensPrompt: Int?
    var tokensCompletion: Int?
    var nativeTokensReasoning: Int?
    var nativeTokensCached: Int?

    enum CodingKeys: String, CodingKey {
        case id, model, latency
        case providerName = "provider_name"
        case totalCost = "total_cost"
        case generationTime = "generation_time"
        case tokensPrompt = "tokens_prompt"
        case tokensCompletion = "tokens_completion"
        case nativeTokensReasoning = "native_tokens_reasoning"
        case nativeTokensCached = "native_tokens_cached"
    }
}

struct OAuthKeyResponse: Decodable, Sendable {
    var key: String
    var userID: String?
    enum CodingKeys: String, CodingKey {
        case key
        case userID = "user_id"
    }
}
