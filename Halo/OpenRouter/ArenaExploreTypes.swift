import Foundation

/// OpenRouter's own benchmark for an image, video or voice model, from the unofficial frontend API
/// behind openrouter.ai's model pages (`/api/frontend/v1/arena/explore/models/{slug}?tab=…`). Every
/// model gets the same prompts ("challenges"), each with a few checks that judge models mark pass or
/// fail, plus "style" prompts that show its range. Loosely typed, so a new field can't break it.
struct ArenaExplore: Decodable, Hashable, Sendable {
    var pages: [Page]
    var standing: Standing?

    struct Page: Decodable, Hashable, Sendable {
        var challenge: Challenge?
    }

    struct Challenge: Decodable, Hashable, Sendable, Identifiable {
        /// "challenge" for a test with checks, "style" for a showcase.
        var kind: String
        var slug: String
        var name: String
        var navLabel: String?
        /// What it tests and why models get it wrong.
        var description: String?
        var variants: [Variant]
        var id: String { slug }
        var title: String { navLabel ?? name }
        var isShowcase: Bool { kind == "style" }

        /// The first variant with a result, which the card shows.
        var lead: (variant: Variant, cell: Cell)? {
            for v in variants { if let c = v.cells.first { return (v, c) } }
            return nil
        }

        /// Checks passed and checked across every variant.
        var tally: (passed: Int, total: Int) {
            let checks = variants.flatMap { $0.cells.flatMap { $0.score?.checks ?? [] } }
            return (checks.filter(\.pass).count, checks.count)
        }
    }

    struct Variant: Decodable, Hashable, Sendable, Identifiable {
        var slug: String
        var name: String
        var prompt: String?
        /// Images given to the model with the prompt (edits, references).
        var inputAssets: [Asset]?
        var cells: [Cell]
        var id: String { slug }
    }

    /// This model's result on one variant.
    struct Cell: Decodable, Hashable, Sendable {
        var provider: String?
        var asset: Asset?
        var costUsd: Double?
        var durationMs: Double?
        var score: Score?
    }

    struct Asset: Decodable, Hashable, Sendable {
        var url: String
        var thumbnailUrl: String?
        var frameThumbnailUrls: [String]?
        var mediaType: String
        var width: Int?
        var height: Int?
        /// Length of a voice clip.
        var durationMs: Double?
        var voice: String?

        var isVideo: Bool { mediaType.hasPrefix("video/") }
        var isAudio: Bool { mediaType.hasPrefix("audio/") }
        /// A still to show: the thumbnail, a video's first frame, or an image itself.
        var previewURL: URL? {
            (thumbnailUrl ?? frameThumbnailUrls?.first ?? (mediaType.hasPrefix("image/") ? url : nil)).flatMap(URL.init(string:))
        }
    }

    struct Score: Decodable, Hashable, Sendable {
        var checks: [Check]
    }

    struct Check: Decodable, Hashable, Sendable {
        var label: String
        var pass: Bool
    }

    struct Standing: Decodable, Hashable, Sendable {
        var evalsRun: Int?
        var checksPassed: Int
        var checksTotal: Int
        var rankOnChecks: Rank?
        var rankOnCost: Rank?
        var rankOnSpeed: Rank?
        /// Rank on each challenge, by its slug.
        var challenges: [String: Rank?]?
    }

    struct Rank: Decodable, Hashable, Sendable {
        var position: Int
        var of: Int
        var tied: Bool?
    }

    var challenges: [Challenge] { pages.compactMap(\.challenge).filter { !$0.isShowcase && $0.lead != nil } }
    var showcases: [Challenge] { pages.compactMap(\.challenge).filter { $0.isShowcase && $0.lead != nil } }

    func rank(of challenge: Challenge) -> Rank? { standing?.challenges?[challenge.slug] ?? nil }

    /// "1st", "2nd", "33rd", "11th".
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
