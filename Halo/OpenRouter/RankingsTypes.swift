import Foundation

// OpenRouter's Data API (openrouter.ai/docs/cookbook/administration/data-api): the datasets behind
// openrouter.ai/rankings. Every endpoint takes the inference key, at 30 calls a minute and 500 a day.

/// `meta` on the dataset endpoints.
struct DatasetMeta: Codable, Hashable, Sendable {
    var asOf: String?
    var startDate: String?
    var endDate: String?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of", startDate = "start_date", endDate = "end_date"
    }
}

/// `GET datasets/rankings-daily`: the top 50 public models by tokens each day, plus an "other" row.
struct RankingsDaily: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Sendable {
        /// "2026-10-24", UTC.
        var date: String
        /// The model's canonical slug ("openai/gpt-6.1-sol-20260801"), or "other".
        var modelPermaslug: String
        /// Sent as a string for 64-bit safety; a Double holds it closely enough to chart.
        var totalTokens: FlexibleDouble

        enum CodingKeys: String, CodingKey {
            case date, modelPermaslug = "model_permaslug", totalTokens = "total_tokens"
        }

        var tokens: Double { totalTokens.value ?? 0 }
    }

    var data: [Row]
    var meta: DatasetMeta?
}

/// `GET datasets/app-rankings`.
struct AppRankings: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Sendable, Identifiable {
        var rank: Int
        var appID: FlexibleString?
        var appName: String
        var totalTokens: FlexibleDouble
        var totalRequests: FlexibleDouble?

        enum CodingKeys: String, CodingKey {
            case rank, appID = "app_id", appName = "app_name", totalTokens = "total_tokens", totalRequests = "total_requests"
        }

        var id: Int { rank }
    }

    var data: [Row]
    var meta: DatasetMeta?
}

/// `GET classifications/task`: what requests were for over the last 7 days, as shares (0–1) only.
struct TaskClassifications: Codable, Hashable, Sendable {
    struct Payload: Codable, Hashable, Sendable {
        var windowDays: Int?
        var asOf: String?
        var classifications: [Tag]
        var macroCategories: [Macro]?

        enum CodingKeys: String, CodingKey {
            case windowDays = "window_days", asOf = "as_of", classifications
            case macroCategories = "macro_categories"
        }
    }

    struct Tag: Codable, Hashable, Sendable, Identifiable {
        var tag: String
        var displayName: String
        var macroCategory: String?
        /// Of all requests.
        var usageShare: Double?
        var tokenShare: Double?
        /// Of the requests in its macro category.
        var categoryUsageShare: Double?
        var models: [TagModel]

        enum CodingKeys: String, CodingKey {
            case tag, models
            case displayName = "display_name", macroCategory = "macro_category"
            case usageShare = "usage_share", tokenShare = "token_share"
            case categoryUsageShare = "category_usage_share"
        }

        var id: String { tag }
    }

    struct TagModel: Codable, Hashable, Sendable {
        var id: String
        /// Of the tag's requests.
        var tagUsageShare: Double?
        var tagTokenShare: Double?

        enum CodingKeys: String, CodingKey {
            case id, tagUsageShare = "tag_usage_share", tagTokenShare = "tag_token_share"
        }
    }

    struct Macro: Codable, Hashable, Sendable, Identifiable {
        var key: String
        var label: String
        var usageShare: Double?
        var tokenShare: Double?

        enum CodingKeys: String, CodingKey {
            case key, label, usageShare = "usage_share", tokenShare = "token_share"
        }

        var id: String { key }
    }

    var data: Payload
}

/// `GET benchmarks`. Items differ by source, so they're kept loose and read by `BenchmarkItem`.
struct BenchmarkList: Codable, Hashable, Sendable {
    var data: [JSONValue]
    var meta: JSONValue?

    var citation: String? { meta?["citation"]?.stringValue }
    var asOf: String? { meta?["as_of"]?.stringValue }
}

/// One benchmark result, read out of whichever fields its source sends.
struct BenchmarkItem: Hashable, Sendable, Identifiable {
    /// The model's slug as sent: an id ("openai/gpt-6.1-sol") or a canonical slug.
    var model: String
    var name: String?
    var score: Double
    /// "accuracy", "elo"…, when sent.
    var metric: String?
    var costPerTask: Double?
    var latencyMs: Double?
    var winRate: Double?

    var id: String { model }

    init?(_ json: JSONValue, scoreKeys: [String]) {
        let modelKeys = ["model_permaslug", "permaslug", "model_slug", "model_id", "canonical_slug", "slug", "model", "id"]
        guard let model = modelKeys.lazy.compactMap({ json[$0]?.stringValue }).first,
              let score = scoreKeys.lazy.compactMap({ json[$0]?.doubleValue }).first else { return nil }
        self.model = model
        self.score = score
        name = ["model_name", "name", "display_name"].lazy.compactMap { json[$0]?.stringValue }.first
        metric = json["primary_metric"]?.stringValue
        costPerTask = json["avg_cost_per_task"]?.doubleValue
        latencyMs = json["avg_latency_per_task_ms"]?.doubleValue ?? json["avg_generation_time_ms"]?.doubleValue
        winRate = json["win_rate"]?.doubleValue
    }
}
