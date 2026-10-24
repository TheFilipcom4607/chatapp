import Foundation

/// Artificial Analysis arena Elo for image, video and voice models, keyed by OpenRouter model id.
/// The repo's media-arena workflow (.github/workflows/media-arena.yml) reads AA's API twice a day
/// and publishes it on the arena-data branch. It replaces the bundled `MediaModelResearch` snapshot
/// board by board; the snapshot stays for when it hasn't loaded.
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

    static let url = URL(string: "https://raw.githubusercontent.com/TheFilipcom4607/chatapp/arena-data/media-arena.json")!

    /// The published file, which also carries what the app doesn't use (each match's AA name, the
    /// rows that matched nothing).
    static func decode(_ data: Data) throws -> MediaArenaFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MediaArenaFeed.self, from: data)
    }

    func elo(_ board: MediaModelResearch.Board, _ id: String) -> Double? { boards[board.endpoint]?[id]?.elo }

    /// "Oct 24, 2026", in the reader's format.
    var asOf: String { updatedAt.formatted(date: .abbreviated, time: .omitted) }
}
