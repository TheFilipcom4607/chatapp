import Foundation

/// What a media model makes. One picker serves all three.
enum MediaKind: String, Identifiable {
    case image, video, speech
    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Image model"
        case .video: return "Video model"
        case .speech: return "Voice model"
        }
    }

    /// The filter chips the browser offers for this kind.
    var filters: [MediaFeature] {
        switch self {
        case .image: return [.edits, .vector, .fourK]
        case .video: return [.fromImage, .audio, .fullHD]
        case .speech: return [.styleControl, .manyVoices]
        }
    }
}

enum MediaFeature: String, CaseIterable, Identifiable {
    case edits = "Edits photos", vector = "Vector", fourK = "4K"
    case fromImage = "From an image", audio = "With audio", fullHD = "1080p"
    case styleControl = "Style control", manyVoices = "20+ voices"
    var id: String { rawValue }
}

/// A rating from a blind-vote arena, ranked against the other models of the same kind.
struct MediaRating: Hashable {
    /// "Design Arena" or "Artificial Analysis".
    let source: String
    /// The arena's category, e.g. "image" or "text-to-video".
    let board: String
    let elo: Double
    /// 0 for the researched board; models rated only by a live feed rank after it, since the
    /// scales don't compare.
    let tier: Int
    /// 1 is the best-rated model in this list.
    var rank = 0
}

struct MediaModelSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let lab: String
    let created: Double?
    let price: Double?
    /// "/image", "/sec" or "/1K chars".
    let priceUnit: String
    var rating: MediaRating?
    let features: Set<MediaFeature>
    let note: String?
    /// Why it can't run here (say, it needs a reference image you didn't give); nil when it can.
    let unavailableReason: String?

    var isUsable: Bool { unavailableReason == nil }
    var priceLabel: String? {
        guard let price else { return nil }
        return price == 0 ? "Free" : Self.formatPrice(price) + priceUnit
    }

    /// Three decimals below 10¢, where the differences live: "$0.007", "$0.078", "$0.13".
    static func formatPrice(_ value: Double) -> String {
        if value == 0 { return "Free" }
        return String(format: value < 0.1 ? "$%.3f" : "$%.2f", value)
    }

    /// The name with version numbers as "#": "Recraft V4.1 Pro Vector" and "Recraft V4 Pro Vector" share
    /// one, so the older can be tucked away. The "#" keeps names of another shape apart: "GPT Image 2"
    /// isn't a version of "GPT-5.4 Image 2".
    var family: String {
        let stripped = name.replacingOccurrences(of: #"\b[vV]?\d+(\.\d+)*\b"#, with: "#", options: .regularExpression)
        return lab + "/" + stripped.split(whereSeparator: { $0 == " " || $0 == "-" }).joined(separator: " ").lowercased()
    }

    /// The first version number in the name, as parts: "Recraft V4.1 Pro" → [4, 1]; empty when none.
    var version: [Int] {
        guard let match = name.firstMatch(of: /\b[vV]?(\d+(?:\.\d+)*)\b/) else { return [] }
        return match.1.split(separator: ".").compactMap { Int($0) }
    }

    /// Released in the last 45 days.
    func isNew(now: Date = .now) -> Bool {
        guard let created else { return false }
        return now.timeIntervalSince1970 - created < 60 * 60 * 24 * 45
    }
}

enum MediaPickRole: String, CaseIterable, Identifiable {
    case best = "Best rated", value = "Best value", cheapest = "Cheapest", newest = "Newest"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .best: return "star"
        case .value: return "hand.thumbsup"
        case .cheapest: return "dollarsign.circle"
        case .newest: return "sparkles"
        }
    }
}

struct MediaPick: Identifiable, Hashable {
    let role: MediaPickRole
    let model: MediaModelSummary
    /// Why it's picked, when the role alone doesn't say: "almost as good, 6× cheaper".
    var detail: String? = nil
    var id: String { model.id }
}

enum MediaPicks {
    /// How far below the best-rated model "best value" may be, in Elo. 100 points is about a
    /// 64% / 36% split in blind votes: close, but noticeably behind.
    static let valueWindow: Double = 100

    /// Best rated, best value (the cheapest model within `valueWindow` of the best), cheapest and
    /// newest, among models that can run here. A model that wins two roles is listed once.
    static func compute(_ models: [MediaModelSummary]) -> [MediaPick] {
        let usable = models.filter(\.isUsable)
        var picks: [MediaPick] = []
        func add(_ role: MediaPickRole, _ model: MediaModelSummary?) {
            guard let model, !picks.contains(where: { $0.id == model.id }) else { return }
            picks.append(MediaPick(role: role, model: model))
        }
        let best = usable.filter { $0.rating != nil }.min { $0.rating!.rank < $1.rating!.rank }
        add(.best, best)
        if let top = best?.rating {
            let close = usable.filter { m in
                guard let r = m.rating, m.price != nil else { return false }
                return r.tier == top.tier && r.elo >= top.elo - valueWindow
            }
            if let value = close.min(by: { $0.price! < $1.price! }), value.id != best?.id {
                // Compared with the best-rated model, which is what "value" is measured against.
                let times = (best?.price).map { $0 / value.price! } ?? 1
                let detail = times >= 1.5 ? "almost as good, \(Int(times.rounded()))× cheaper" : "almost as good"
                picks.append(MediaPick(role: .value, model: value, detail: detail))
            }
        }
        add(.cheapest, usable.filter { $0.price != nil }.min { $0.price! < $1.price! })
        add(.newest, usable.max { ($0.created ?? 0) < ($1.created ?? 0) })
        return picks
    }

    /// Unrated models with a later version of the same family in the list; never `keeping`. Version
    /// numbers decide, not dates: Qwen Image 2.1 Pro came out after Qwen Image 3 Pro but doesn't replace it.
    static func superseded(_ models: [MediaModelSummary], keeping: String) -> Set<String> {
        func isOlder(_ a: MediaModelSummary, than b: MediaModelSummary) -> Bool {
            let va = a.version, vb = b.version
            if !va.isEmpty, !vb.isEmpty, va != vb { return va.lexicographicallyPrecedes(vb) }
            return (a.created ?? 0) < (b.created ?? 0)
        }
        let families = Dictionary(grouping: models, by: \.family)
        return Set(models.filter { m in
            m.rating == nil && m.id != keeping && (families[m.family] ?? []).contains { isOlder(m, than: $0) }
        }.map(\.id))
    }

    /// Ranks rated models: by tier, then Elo. Unrated models keep no rating.
    static func rank(_ models: inout [MediaModelSummary]) {
        let order = models.indices.filter { models[$0].rating != nil }.sorted {
            let a = models[$0].rating!, b = models[$1].rating!
            return a.tier != b.tier ? a.tier < b.tier : a.elo > b.elo
        }
        for (position, index) in order.enumerated() { models[index].rating?.rank = position + 1 }
    }
}

extension ModelCatalog {
    /// Every model of a kind, ready to show: price, rating, features, note, and whether it can run
    /// with or without reference images. Preview builds are dropped when the final one is listed.
    func mediaModels(_ kind: MediaKind, hasReferences: Bool = false) -> [MediaModelSummary] {
        var list: [MediaModelSummary]
        switch kind {
        case .image: list = imageModels.map { imageSummary($0, hasReferences: hasReferences) }
        case .video: list = videoModels.map { videoSummary($0, hasReferences: hasReferences) }
        case .speech: list = speechModels.map(speechSummary)
        }
        // Drop preview builds whose final version is listed; the final one inherits the preview's
        // rating when it has none, since arenas often only ever tested the preview.
        let previews = Dictionary(list.filter { $0.id.hasSuffix("-preview") }.map { (String($0.id.dropLast("-preview".count)), $0) },
                                  uniquingKeysWith: { a, _ in a })
        let ids = Set(list.map(\.id))
        list.removeAll { $0.id.hasSuffix("-preview") && ids.contains(String($0.id.dropLast("-preview".count))) }
        for i in list.indices where list[i].rating == nil { list[i].rating = previews[list[i].id]?.rating }
        MediaPicks.rank(&list)
        return list
    }

    private static func lab(_ name: String, id: String) -> String {
        if let r = name.range(of: ": ") { return String(name[..<r.lowerBound]) }
        return id.split(separator: "/").first.map(String.init)?.capitalized ?? ""
    }

    /// The first score found, in order of trust: the researched board for this job, then the live
    /// feeds. Each source is its own tier, since their scales don't compare.
    private func rating(_ sources: [(source: String, board: String, elo: Double?)]) -> MediaRating? {
        for (tier, s) in sources.enumerated() {
            if let elo = s.elo { return MediaRating(source: s.source, board: s.board, elo: elo, tier: tier) }
        }
        return nil
    }

    private func researched(_ board: MediaModelResearch.Board, _ id: String) -> (source: String, board: String, elo: Double?) {
        ("\(MediaModelResearch.source), \(MediaModelResearch.asOf)", board.rawValue, MediaModelResearch.elo(board, id))
    }

    private func imageSummary(_ m: ImageModelInfo, hasReferences: Bool) -> MediaModelSummary {
        var features: Set<MediaFeature> = []
        if m.supportsReferences { features.insert(.edits) }
        if m.makesVectors { features.insert(.vector) }
        if m.resolutions.contains("4K") { features.insert(.fourK) }
        let reason: String? = if m.requiresReferences && !hasReferences { "Needs a reference image" }
            else if hasReferences && !m.supportsReferences { "Can't use reference images" }
            else { nil }
        let arena = imageArena[m.id]?.first { $0.category == "image" }?.elo
        return MediaModelSummary(
            id: m.id, name: m.shortName, lab: Self.lab(m.name, id: m.id), created: m.created,
            price: imagePriceEstimate(m.id), priceUnit: "/image",
            // With reference images it's an edit, so the editing board ranks.
            rating: rating([researched(hasReferences ? .imageEditing : .textToImage, m.id),
                            ("Artificial Analysis", "text-to-image", mediaArena["text-to-image"]?[m.id]),
                            ("Design Arena", "image", arena)]),
            features: features, note: MediaModelNotes.note(for: m.id), unavailableReason: reason)
    }

    private func videoSummary(_ m: VideoModelInfo, hasReferences: Bool) -> MediaModelSummary {
        var features: Set<MediaFeature> = []
        if m.supportsFirstFrame { features.insert(.fromImage) }
        if m.generateAudio == true { features.insert(.audio) }
        let resolutions = (m.supportedResolutions ?? []).map { $0.lowercased() }
        if resolutions.contains(where: { ["1080p", "2k", "4k"].contains($0) }) { features.insert(.fullHD) }
        let reason: String? = if m.needsVideoInput { "Needs a video to work on" }
            else if hasReferences && !m.supportsFirstFrame { "Can't start from an image" }
            else { nil }
        // Priced at 720p where offered, since that's what most clips use.
        let res = resolutions.contains("720p") ? "720p" : resolutions.first
        return MediaModelSummary(
            id: m.id, name: m.shortName, lab: Self.lab(m.name, id: m.id), created: m.created,
            price: m.estimatedCost(seconds: 1, resolution: res, audio: false), priceUnit: "/sec",
            rating: rating([researched(hasReferences ? .imageToVideo : .textToVideo, m.id),
                            ("Artificial Analysis", "text-to-video", mediaArena["text-to-video"]?[m.id]),
                            ("Artificial Analysis", "image-to-video", mediaArena["image-to-video"]?[m.id])]),
            features: features, note: MediaModelNotes.note(for: m.id), unavailableReason: reason)
    }

    private func speechSummary(_ m: ORModel) -> MediaModelSummary {
        var features: Set<MediaFeature> = []
        if (m.supportedVoices?.count ?? 0) >= 20 { features.insert(.manyVoices) }
        // Gemini voices take free-form directions (tone, pace, accent) alongside the text.
        if m.id.hasPrefix("google/gemini") { features.insert(.styleControl) }
        return MediaModelSummary(
            // The price already says "Free".
            id: m.id, name: m.shortName.replacingOccurrences(of: " (free)", with: ""), lab: m.providerName, created: m.created,
            price: Self.speechPricePer1K(m), priceUnit: "/1K chars",
            rating: rating([researched(.textToSpeech, m.id),
                            ("Artificial Analysis", "text-to-speech", mediaArena["text-to-speech"]?[m.id]),
                            ("Design Arena", "text-to-speech", m.arenaElo("text-to-speech"))]),
            features: features, note: MediaModelNotes.note(for: m.id), unavailableReason: nil)
    }

    /// Rough cost of reading 1,000 characters aloud (about a minute of speech). Most voices bill per
    /// input character; Gemini bills tokens in and audio tokens out (~25 a second); a few bill per
    /// second of audio, which shows as an output price far above any per-token rate.
    static func speechPricePer1K(_ m: ORModel) -> Double? {
        guard let input = m.pricing?.prompt?.value, input >= 0 else { return nil }
        let output = m.pricing?.completion?.value ?? 0
        guard output > 0 else { return input * 1000 }
        let seconds = 65.0
        return input * 250 + (output < 0.0001 ? output * seconds * 25 : output * seconds)
    }
}
