import Foundation

/// The files the repo's media-arena workflow (.github/workflows/media-arena.yml) builds from
/// Artificial Analysis's API twice a day and publishes on the arena-data branch.
enum PublishedStats {
    static let base = URL(string: "https://raw.githubusercontent.com/TheFilipcom4607/chatapp/arena-data/")!

    /// The published files also carry what the app doesn't use (each match's AA name, the rows
    /// that matched nothing).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// Artificial Analysis arena Elo for image, video and voice models, keyed by OpenRouter model id.
/// It replaces the bundled `MediaModelResearch` snapshot board by board; the snapshot stays for
/// when it hasn't loaded.
struct MediaArenaFeed: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let elo: Double
    }

    /// When the scores last changed.
    let updatedAt: Date
    /// AA's board ("text-to-image", "image-editing", …) → OpenRouter id → score.
    let boards: [String: [String: Entry]]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at", boards
    }

    static let url = PublishedStats.base.appendingPathComponent("media-arena.json")

    static func decode(_ data: Data) throws -> MediaArenaFeed { try PublishedStats.decode(Self.self, from: data) }

    func elo(_ board: MediaModelResearch.Board, _ id: String) -> Double? { boards[board.endpoint]?[id]?.elo }

    /// "Oct 24, 2026", in the reader's format.
    var asOf: String { updatedAt.formatted(date: .abbreviated, time: .omitted) }
}

/// How fast chat models run, as Artificial Analysis measures them at each model's own provider
/// with 1K-token prompts, keyed by OpenRouter's canonical slug. Taken at a model's smartest
/// effort, the one its scores describe.
struct ChatModelStats: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Output tokens per second, once tokens flow.
        let tps: Double
        /// Seconds to the first token, thinking included when it streams.
        let ttft: Double?
        /// Seconds to the first token of the answer itself, after any thinking.
        let ttfa: Double?
    }

    let updatedAt: Date
    let models: [String: Entry]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at", models
    }

    static let url = PublishedStats.base.appendingPathComponent("llm-stats.json")

    static func decode(_ data: Data) throws -> ChatModelStats { try PublishedStats.decode(Self.self, from: data) }
}
