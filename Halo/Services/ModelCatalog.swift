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
    /// Design Arena scores for image models (the image list itself doesn't carry them).
    private(set) var imageArena: [String: [ORModel.ArenaScore]] = [:]
    private var byID: [String: ORModel] = [:]
    private(set) var imagePrices: [String: Double] = [:]
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
        let url = Self.cacheDir.appendingPathComponent("models-v3.json")
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        apply(models: cache.models)
        speechModels = cache.speech
    }

    private func saveCache() {
        let url = Self.cacheDir.appendingPathComponent("models-v3.json")
        let cache = CacheFile(date: .now, models: models, speech: speechModels)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url) }
        UserDefaults.standard.set(Date(), forKey: "modelsRefreshedAt")
    }

    private func apply(models: [ORModel]) {
        self.models = models
        byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var isStale: Bool {
        guard let date = UserDefaults.standard.object(forKey: "modelsRefreshedAt") as? Date else { return true }
        return Date().timeIntervalSince(date) > 60 * 60 * 12 || models.isEmpty
    }

    func refreshIfNeeded() async {
        if isStale { await refresh() } else { Task { await refreshEffortScores() } }
        if imageModels.isEmpty || videoModels.isEmpty { await refreshMediaModels() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // Unofficial and optional: runs on its own so it can't hold up or fail the catalog.
        Task { await refreshEffortScores() }
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
        }
        // The pickers rank by price, so have prices ready before anyone opens one.
        if i != nil { Task { await loadAllImagePrices() } }
    }

    func model(_ id: String) -> ORModel? { byID[id] }

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

    /// Fetches per-effort scores (no more than every 12 hours). Failures keep the previous cache.
    func refreshEffortScores() async {
        if let at = effortScoresFetchedAt, Date().timeIntervalSince(at) < 60 * 60 * 12 { return }
        guard !effortScoresLoading else { return }
        effortScoresLoading = true
        defer { effortScoresLoading = false }
        guard let rows = try? await client.effortBenchmarks() else { return }
        var scores: [String: [String: Double]] = [:]
        var media: [String: [String: Double]] = [:]
        for row in rows {
            if let type = row.benchmarkData?.modelType, type != "llm", let elo = row.benchmarkData?.elo {
                // A model can appear several times (resolutions, preview builds): keep its best.
                media[type, default: [:]][row.modelID] = max(elo, media[type]?[row.modelID] ?? 0)
                continue
            }
            guard let effort = row.effort, let score = row.intelligence else { continue }
            scores[row.permaslug, default: [:]][effort] = max(score, scores[row.permaslug]?[effort] ?? 0)
        }
        guard !scores.isEmpty else { return }
        effortScores = scores
        mediaArena = media
        effortScoresFetchedAt = .now
        saveEffortCache()
    }

    private struct EffortCacheFile: Codable {
        var date: Date
        var scores: [String: [String: Double]]
        var media: [String: [String: Double]]?
    }

    private static var effortCacheURL: URL { cacheDir.appendingPathComponent("aa-efforts-v1.json") }

    private func loadEffortCache() {
        guard let data = try? Data(contentsOf: Self.effortCacheURL),
              let cache = try? JSONDecoder().decode(EffortCacheFile.self, from: data) else { return }
        effortScores = cache.scores
        mediaArena = cache.media ?? [:]
        // A cache from before media arenas were kept: fetch again to fill them in.
        effortScoresFetchedAt = cache.media == nil ? nil : cache.date
    }

    private func saveEffortCache() {
        let cache = EffortCacheFile(date: effortScoresFetchedAt ?? .now, scores: effortScores, media: mediaArena)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.effortCacheURL) }
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

    func imagePrice(_ id: String) async -> Double? {
        if let p = imagePrices[id] { return p }
        guard let endpoints = try? await client.imageEndpoints(modelID: id), let p = endpoints.estimatedCostPerImage else { return nil }
        imagePrices[id] = p
        saveImagePriceCache()
        return p
    }

    /// Every image model's price, so the picker can compare them; one request per model, a few at a
    /// time, no more than every 12 hours.
    func loadAllImagePrices() async {
        if let at = imagePricesFetchedAt, Date().timeIntervalSince(at) < 60 * 60 * 12,
           imageModels.allSatisfy({ imagePrices[$0.id] != nil }) { return }
        guard !imagePricesLoading else { return }
        imagePricesLoading = true
        defer { imagePricesLoading = false }
        let ids = imageModels.map(\.id)
        let client = client
        await withTaskGroup(of: (String, Double?).self) { group in
            var pending = ids[...]
            for _ in 0..<6 {
                guard let id = pending.popFirst() else { break }
                group.addTask { (id, try? await client.imageEndpoints(modelID: id).estimatedCostPerImage) }
            }
            for await (id, price) in group {
                if let price { imagePrices[id] = price }
                if let id = pending.popFirst() {
                    group.addTask { (id, try? await client.imageEndpoints(modelID: id).estimatedCostPerImage) }
                }
            }
        }
        imagePricesFetchedAt = .now
        saveImagePriceCache()
    }

    private struct PriceCacheFile: Codable {
        var date: Date
        var prices: [String: Double]
    }

    private static var imagePriceCacheURL: URL { cacheDir.appendingPathComponent("image-prices-v1.json") }

    private func loadImagePriceCache() {
        guard let data = try? Data(contentsOf: Self.imagePriceCacheURL),
              let cache = try? JSONDecoder().decode(PriceCacheFile.self, from: data) else { return }
        imagePrices = cache.prices
        imagePricesFetchedAt = cache.date
    }

    private func saveImagePriceCache() {
        let cache = PriceCacheFile(date: imagePricesFetchedAt ?? .distantPast, prices: imagePrices)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.imagePriceCacheURL) }
    }
}
