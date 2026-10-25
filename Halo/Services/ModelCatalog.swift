import Foundation
import Observation

/// Cached OpenRouter catalogs: chat models, image, video and speech models.
@MainActor
@Observable
final class ModelCatalog {
    private(set) var models: [ORModel] = []
    private(set) var imageModels: [ImageModelInfo] = []
    private(set) var videoModels: [VideoModelInfo] = []
    private(set) var speechModels: [ORModel] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    /// Artificial Analysis intelligence per thinking level: canonical slug → effort → score.
    private(set) var effortScores: [String: [String: Double]] = [:]
    private var effortScoresFetchedAt: Date?
    private var effortScoresLoading = false
    /// Artificial Analysis media arenas: model type ("text-to-video", …) → model id → Elo.
    private(set) var mediaArena: [String: [String: Double]] = [:]
    /// Every Artificial Analysis benchmark per canonical slug, at the model's smartest effort.
    private var benchmarks: [String: [String: Double]] = [:]
    /// AA's media arenas and chat model speeds as the repo's workflow publishes them; nil until first loaded.
    private(set) var mediaArenaFeed: MediaArenaFeed?
    private(set) var chatModelStats: ChatModelStats?
    private var publishedFetchedAt: Date?
    private var publishedLoading = false
    /// Design Arena scores for image models (the image list itself doesn't carry them).
    private(set) var imageArena: [String: [ORModel.ArenaScore]] = [:]
    /// Canonical slugs of image models, from the same list (the image list itself doesn't carry them).
    private var imageSlugs: [String: String] = [:]
    /// OpenRouter's benchmark per media model, by "tab|slug", once looked up; a miss is kept as nil.
    private var arenaExplores: [String: ArenaExplore?] = [:]
    private var byID: [String: ORModel] = [:]
    /// OpenRouter's price per image (estimated for token-billed models); see `imagePriceEstimate`.
    private var imagePrices: [String: Double] = [:]
    /// Image models OpenRouter bills by token, whose price above is a guess.
    private var tokenPricedImages: Set<String> = []
    /// Image models whose endpoint list came back with no price (some are billed but not listed).
    private var unpricedImages: Set<String> = []
    /// What the last image from each model really cost, per image, from the response's usage.
    private var lastImageCosts: [String: Double] = [:]
    private var imagePricesFetchedAt: Date?
    private var imagePricesLoading = false
    /// Price per tier for models whose endpoints have been looked up; only those with a tier besides
    /// Standard have more than one entry.
    private(set) var tierPrices: [String: [ServiceTier: TierPrice]] = [:]
    private var tiersFetchedAt: [String: Date] = [:]
    private var tiersLoading: Set<String> = []

    private let client: OpenRouterClient

    init(client: OpenRouterClient) {
        self.client = client
        loadCache()
        loadEffortCache()
        loadTierCache()
        loadImagePriceCache()
        loadPublishedCache()
        lastImageCosts = UserDefaults.standard.dictionary(forKey: Self.lastImageCostsKey) as? [String: Double] ?? [:]
    }

    private static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private struct CacheFile: Codable {
        var date: Date
        var models: [ORModel]
        var speech: [ORModel]
    }

    private func loadCache() {
        let url = Self.cacheDir.appendingPathComponent("models-v4.json")
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        apply(models: cache.models)
        speechModels = cache.speech
    }

    private func saveCache() {
        let url = Self.cacheDir.appendingPathComponent("models-v4.json")
        let cache = CacheFile(date: .now, models: models, speech: speechModels)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url) }
        UserDefaults.standard.set(Date(), forKey: "modelsRefreshedAt")
    }

    private func apply(models: [ORModel]) {
        // ":batch" variants only answer through OpenRouter's async Batch API, never a chat request, so
        // they stay out of every list. They're still looked up by ID, for a chat that used one.
        self.models = models.filter { !$0.id.hasSuffix(":batch") }
        byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var isStale: Bool {
        guard let date = UserDefaults.standard.object(forKey: "modelsRefreshedAt") as? Date else { return true }
        return Date().timeIntervalSince(date) > 60 * 60 * 12 || models.isEmpty
    }

    func refreshIfNeeded() async {
        if isStale {
            await refresh()
        } else {
            Task { await refreshEffortScores() }
            Task { await refreshPublished() }
        }
        if imageModels.isEmpty || videoModels.isEmpty { await refreshMediaModels() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // Unofficial and optional: runs on its own so it can't hold up or fail the catalog.
        Task { await refreshEffortScores() }
        Task { await refreshPublished() }
        do {
            async let text = client.models(outputModality: "text")
            // The speech list is optional: don't lose the chat catalog if only it fails.
            async let speech = try? client.models(outputModality: "speech")
            let t = try await text
            let s = await speech
            apply(models: t)
            if let s { speechModels = s }
            lastError = nil
            saveCache()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshMediaModels() async {
        async let images = try? client.imageModels()
        async let videos = try? client.videoModels()
        // The chat-style list of image models is where their Design Arena scores live.
        async let rated = try? client.models(outputModality: "image")
        let (i, v, r) = await (images, videos, rated)
        if let i { imageModels = i }
        if let v { videoModels = v }
        if let r {
            imageArena = Dictionary(r.compactMap { m in m.benchmarks?.designArena.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
            imageSlugs = Dictionary(r.compactMap { m in m.canonicalSlug.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        // The pickers rank by price, so have prices ready before anyone opens one.
        if i != nil { Task { await loadAllImagePrices() } }
    }

    func model(_ id: String) -> ORModel? { byID[id] }

    /// OpenRouter's own benchmark of an image, video or voice model; nil when it has none or the
    /// lookup failed. Kept for the session once found.
    func arenaExplore(_ kind: MediaKind, _ id: String) async -> ArenaExplore? {
        let slug: String? = switch kind {
        case .image: imageSlugs[id]
        case .video: videoModel(id)?.canonicalSlug
        case .speech: speechModel(id)?.canonicalSlug
        }
        let tab = switch kind {
        case .image: "image"
        case .video: "video"
        case .speech: "speech"
        }
        guard let slug else { return nil }
        let key = "\(tab)|\(slug)"
        if let cached = arenaExplores[key] { return cached }
        do {
            let result = try await client.arenaExplore(slug: slug, tab: tab)
            arenaExplores[key] = .some(result)
            return result
        } catch {
            // Not kept: offline now needn't mean nothing later.
            return nil
        }
    }

    func displayName(_ id: String) -> String {
        if let m = byID[id] { return m.shortName }
        if let m = imageModels.first(where: { $0.id == id }) { return m.shortName }
        if let m = videoModels.first(where: { $0.id == id }) { return m.shortName }
        if let m = speechModels.first(where: { $0.id == id }) { return m.shortName }
        let slug = id.split(separator: "/").last.map(String.init) ?? id
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// The name to show where a media model is picked. Some image models are also chat models,
    /// whose catalog name is longer ("Nano Banana 2 (Gemini 3.1 Flash Image)").
    func mediaName(_ kind: MediaKind, _ id: String) -> String {
        switch kind {
        case .image: return imageModel(id)?.shortName ?? displayName(id)
        case .video: return videoModel(id)?.shortName ?? displayName(id)
        case .speech: return speechModel(id)?.shortName ?? displayName(id)
        }
    }

    func imageModel(_ id: String) -> ImageModelInfo? { imageModels.first { $0.id == id } }
    func videoModel(_ id: String) -> VideoModelInfo? { videoModels.first { $0.id == id } }
    func speechModel(_ id: String) -> ORModel? { speechModels.first { $0.id == id } }

    // MARK: Per-effort scores

    func effortScores(for model: ORModel) -> [String: Double] {
        model.canonicalSlug.flatMap { effortScores[$0] } ?? [:]
    }

    /// Every benchmark Artificial Analysis ran on the model, by key ("gpqa", "hle", …): indexes on a
    /// 0–100 scale, the rest as fractions.
    func benchmarks(for model: ORModel) -> [String: Double] {
        model.canonicalSlug.flatMap { benchmarks[$0] } ?? [:]
    }

    /// How fast Artificial Analysis measured the model; nil when it hasn't, or the file hasn't loaded.
    func measuredSpeed(for model: ORModel) -> ChatModelStats.Entry? {
        model.canonicalSlug.flatMap { chatModelStats?.models[$0] }
    }

    /// Fetches per-effort scores (no more than every 12 hours unless forced). Failures keep the
    /// previous cache. True when new scores came in.
    @discardableResult
    func refreshEffortScores(force: Bool = false) async -> Bool {
        if !force, let at = effortScoresFetchedAt, Date().timeIntervalSince(at) < 60 * 60 * 12 { return false }
        guard !effortScoresLoading else { return false }
        effortScoresLoading = true
        defer { effortScoresLoading = false }
        guard let rows = try? await client.effortBenchmarks() else { return false }
        var scores: [String: [String: Double]] = [:]
        var media: [String: [String: Double]] = [:]
        var best: [String: [String: Double]] = [:]
        for row in rows {
            if let type = row.benchmarkData?.modelType, type != "llm", let elo = row.benchmarkData?.elo {
                // A model can appear several times (resolutions, preview builds): keep its best.
                media[type, default: [:]][row.modelID] = max(elo, media[type]?[row.modelID] ?? 0)
                continue
            }
            guard let score = row.intelligence else { continue }
            // The smartest effort's benchmarks, as OpenRouter's own scores describe that effort.
            if score > best[row.permaslug]?["artificial_analysis_intelligence_index"] ?? -1 { best[row.permaslug] = row.evaluations }
            guard let effort = row.effort else { continue }
            scores[row.permaslug, default: [:]][effort] = max(score, scores[row.permaslug]?[effort] ?? 0)
        }
        guard !scores.isEmpty else { return false }
        effortScores = scores
        benchmarks = best
        mediaArena = media
        effortScoresFetchedAt = .now
        saveEffortCache()
        return true
    }

    private struct EffortCacheFile: Codable {
        var date: Date
        var scores: [String: [String: Double]]
        var media: [String: [String: Double]]?
        var benchmarks: [String: [String: Double]]?
    }

    private static var effortCacheURL: URL { cacheDir.appendingPathComponent("aa-efforts-v1.json") }

    private func loadEffortCache() {
        guard let data = try? Data(contentsOf: Self.effortCacheURL),
              let cache = try? JSONDecoder().decode(EffortCacheFile.self, from: data) else { return }
        effortScores = cache.scores
        mediaArena = cache.media ?? [:]
        benchmarks = cache.benchmarks ?? [:]
        // A cache from before media arenas or benchmarks were kept: fetch again to fill them in.
        effortScoresFetchedAt = cache.media == nil || cache.benchmarks == nil ? nil : cache.date
    }

    private func saveEffortCache() {
        let cache = EffortCacheFile(date: effortScoresFetchedAt ?? .now, scores: effortScores, media: mediaArena, benchmarks: benchmarks)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.effortCacheURL) }
    }

    // MARK: Published stats

    /// When the workflow last changed the published ratings; nil before they first load.
    var ratingsUpdatedAt: Date? { [mediaArenaFeed?.updatedAt, chatModelStats?.updatedAt].compactMap { $0 }.max() }
    /// Settings' "Model ratings": the published ratings and AA's scores now, past the 12-hour wait.
    /// True when either came in.
    func refreshRatingsNow() async -> Bool {
        async let published = refreshPublished(force: true)
        async let scores = refreshEffortScores(force: true)
        let (p, s) = await (published, scores)
        return p || s
    }

    /// Fetches the media arenas and chat model speeds the repo publishes (no more than every 12
    /// hours unless forced). A file that fails keeps its previous cache. True when either came in.
    @discardableResult
    func refreshPublished(force: Bool = false) async -> Bool {
        if !force, let at = publishedFetchedAt, Date().timeIntervalSince(at) < 60 * 60 * 12 { return false }
        guard !publishedLoading else { return false }
        publishedLoading = true
        defer { publishedLoading = false }
        async let media = Self.fetchPublished(MediaArenaFeed.url, MediaArenaFeed.decode)
        async let stats = Self.fetchPublished(ChatModelStats.url, ChatModelStats.decode)
        let (m, s) = await (media, stats)
        if let m { mediaArenaFeed = m }
        if let s { chatModelStats = s }
        guard m != nil || s != nil else { return false }
        publishedFetchedAt = .now
        savePublishedCache()
        return true
    }

    private static func fetchPublished<T>(_ url: URL, _ decode: (Data) throws -> T) async -> T? {
        // Past the phone's cache: a manual refresh should see what the workflow just published.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? decode(result.0)
    }

    /// When the scores on a board were read: the feed's date, or the bundled snapshot's.
    func arenaAsOf(_ board: MediaModelResearch.Board) -> String {
        if let feed = mediaArenaFeed, feed.boards[board.endpoint] != nil { return feed.asOf }
        return MediaModelResearch.asOf
    }

    private struct PublishedCacheFile: Codable {
        var date: Date
        var media: MediaArenaFeed?
        var chat: ChatModelStats?
    }

    private static var publishedCacheURL: URL { cacheDir.appendingPathComponent("published-stats-v1.json") }

    private func loadPublishedCache() {
        guard let data = try? Data(contentsOf: Self.publishedCacheURL),
              let cache = try? JSONDecoder().decode(PublishedCacheFile.self, from: data) else { return }
        mediaArenaFeed = cache.media
        chatModelStats = cache.chat
        publishedFetchedAt = cache.date
    }

    private func savePublishedCache() {
        let cache = PublishedCacheFile(date: publishedFetchedAt ?? .now, media: mediaArenaFeed, chat: chatModelStats)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.publishedCacheURL) }
    }

    // MARK: Service tiers

    /// The tiers a model offers, cheapest price each; nil until looked up.
    func tiers(_ id: String) -> [ServiceTier: TierPrice]? { tierPrices[id] }

    /// Looks up a model's endpoints (no more than every 12 hours) to learn its tiers.
    func loadTiers(_ id: String) async {
        if let at = tiersFetchedAt[id], Date().timeIntervalSince(at) < 60 * 60 * 12 { return }
        guard !tiersLoading.contains(id) else { return }
        tiersLoading.insert(id)
        defer { tiersLoading.remove(id) }
        guard let endpoints = try? await client.endpoints(modelID: id) else { return }
        tierPrices[id] = endpoints.tierPrices
        tiersFetchedAt[id] = .now
        saveTierCache()
    }

    private struct TierCacheEntry: Codable {
        var date: Date
        var prices: [String: TierPrice]
    }

    private static var tierCacheURL: URL { cacheDir.appendingPathComponent("tiers-v1.json") }

    private func loadTierCache() {
        guard let data = try? Data(contentsOf: Self.tierCacheURL),
              let cache = try? JSONDecoder().decode([String: TierCacheEntry].self, from: data) else { return }
        for (id, entry) in cache {
            tierPrices[id] = Dictionary(uniqueKeysWithValues: entry.prices.compactMap { k, v in ServiceTier(rawValue: k).map { ($0, v) } })
            tiersFetchedAt[id] = entry.date
        }
    }

    private func saveTierCache() {
        var cache: [String: TierCacheEntry] = [:]
        for (id, prices) in tierPrices {
            cache[id] = TierCacheEntry(date: tiersFetchedAt[id] ?? .now,
                                       prices: Dictionary(uniqueKeysWithValues: prices.map { ($0.key.rawValue, $0.value) }))
        }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.tierCacheURL) }
    }

    private static let lastImageCostsKey = "lastImageCosts"

    /// The best known price for one ~1K image: OpenRouter's, unless it bills by token, where the
    /// creator's researched price beats the app's guess at the token count. With no listed price,
    /// what the last image from the model cost.
    func imagePriceEstimate(_ id: String) -> Double? {
        if tokenPricedImages.contains(id), let researched = MediaModelResearch.imagePrice[id] { return researched }
        return imagePrices[id] ?? lastImageCosts[id]
    }

    /// The estimate is what the last image cost, not a listed price.
    func isImagePriceLearned(_ id: String) -> Bool { imagePrices[id] == nil && lastImageCosts[id] != nil }

    /// Looked up and found to have no price, and none known from use. Not true while prices load.
    func isImagePriceUnlisted(_ id: String) -> Bool { imagePrices[id] == nil && lastImageCosts[id] == nil && unpricedImages.contains(id) }

    /// Remembers what a generation cost, so a model with no listed price can still show one.
    func recordImageCost(_ id: String, total: Double, count: Int) {
        guard total > 0, count > 0 else { return }
        lastImageCosts[id] = total / Double(count)
        UserDefaults.standard.set(lastImageCosts, forKey: Self.lastImageCostsKey)
    }

    /// For a token-billed model, the quality its price estimate stands for: the researched price is
    /// the creator's 1K price at high quality, the token guess is about a medium image. Nil for a
    /// model priced per image, whose price doesn't move with quality.
    func imagePriceQuality(_ id: String) -> String? {
        guard tokenPricedImages.contains(id) else { return nil }
        return MediaModelResearch.imagePrice[id] != nil ? "high" : "medium"
    }

    func imagePrice(_ id: String) async -> Double? {
        if imagePrices[id] != nil { return imagePriceEstimate(id) }
        guard let endpoints = try? await client.imageEndpoints(modelID: id) else { return imagePriceEstimate(id) }
        guard let p = endpoints.estimatedCostPerImage else {
            unpricedImages.insert(id)
            saveImagePriceCache()
            return imagePriceEstimate(id)
        }
        imagePrices[id] = p
        unpricedImages.remove(id)
        if endpoints.isTokenPriced { tokenPricedImages.insert(id) }
        saveImagePriceCache()
        return imagePriceEstimate(id)
    }

    /// Every image model's price, so the picker can compare them; one request per model, a few at a
    /// time, no more than every 12 hours.
    func loadAllImagePrices() async {
        if let at = imagePricesFetchedAt, Date().timeIntervalSince(at) < 60 * 60 * 12,
           imageModels.allSatisfy({ imagePrices[$0.id] != nil || unpricedImages.contains($0.id) }) { return }
        guard !imagePricesLoading else { return }
        imagePricesLoading = true
        defer { imagePricesLoading = false }
        let ids = imageModels.map(\.id)
        let client = client
        await withTaskGroup(of: (String, ImageEndpoints?).self) { group in
            var pending = ids[...]
            for _ in 0..<6 {
                guard let id = pending.popFirst() else { break }
                group.addTask { (id, try? await client.imageEndpoints(modelID: id)) }
            }
            for await (id, endpoints) in group {
                if let endpoints {
                    if let price = endpoints.estimatedCostPerImage {
                        imagePrices[id] = price
                        unpricedImages.remove(id)
                        if endpoints.isTokenPriced { tokenPricedImages.insert(id) } else { tokenPricedImages.remove(id) }
                    } else {
                        unpricedImages.insert(id)
                    }
                }
                if let id = pending.popFirst() {
                    group.addTask { (id, try? await client.imageEndpoints(modelID: id)) }
                }
            }
        }
        imagePricesFetchedAt = .now
        saveImagePriceCache()
    }

    private struct PriceCacheFile: Codable {
        var date: Date
        var prices: [String: Double]
        var tokenPriced: Set<String>
        /// Absent in caches written before it existed.
        var unpriced: Set<String>?
    }

    private static var imagePriceCacheURL: URL { cacheDir.appendingPathComponent("image-prices-v2.json") }

    private func loadImagePriceCache() {
        guard let data = try? Data(contentsOf: Self.imagePriceCacheURL),
              let cache = try? JSONDecoder().decode(PriceCacheFile.self, from: data) else { return }
        imagePrices = cache.prices
        tokenPricedImages = cache.tokenPriced
        unpricedImages = cache.unpriced ?? []
        imagePricesFetchedAt = cache.date
    }

    private func saveImagePriceCache() {
        let cache = PriceCacheFile(date: imagePricesFetchedAt ?? .distantPast, prices: imagePrices, tokenPriced: tokenPricedImages, unpriced: unpricedImages)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.imagePriceCacheURL) }
    }
}
