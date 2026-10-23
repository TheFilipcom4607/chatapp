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
    private var byID: [String: ORModel] = [:]
    private var imagePrices: [String: Double] = [:]

    private let client: OpenRouterClient

    init(client: OpenRouterClient) {
        self.client = client
        loadCache()
        loadEffortCache()
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
        let url = Self.cacheDir.appendingPathComponent("models-v2.json")
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        apply(models: cache.models)
        speechModels = cache.speech
    }

    private func saveCache() {
        let url = Self.cacheDir.appendingPathComponent("models-v2.json")
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
        let (i, v) = await (images, videos)
        if let i { imageModels = i }
        if let v { videoModels = v }
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
        for row in rows {
            guard let effort = row.effort, let score = row.intelligence else { continue }
            scores[row.permaslug, default: [:]][effort] = max(score, scores[row.permaslug]?[effort] ?? 0)
        }
        guard !scores.isEmpty else { return }
        effortScores = scores
        effortScoresFetchedAt = .now
        saveEffortCache()
    }

    private struct EffortCacheFile: Codable {
        var date: Date
        var scores: [String: [String: Double]]
    }

    private static var effortCacheURL: URL { cacheDir.appendingPathComponent("aa-efforts-v1.json") }

    private func loadEffortCache() {
        guard let data = try? Data(contentsOf: Self.effortCacheURL),
              let cache = try? JSONDecoder().decode(EffortCacheFile.self, from: data) else { return }
        effortScores = cache.scores
        effortScoresFetchedAt = cache.date
    }

    private func saveEffortCache() {
        let cache = EffortCacheFile(date: effortScoresFetchedAt ?? .now, scores: effortScores)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.effortCacheURL) }
    }

    func imagePrice(_ id: String) async -> Double? {
        if let p = imagePrices[id] { return p }
        guard let endpoints = try? await client.imageEndpoints(modelID: id), let p = endpoints.estimatedCostPerImage else { return nil }
        imagePrices[id] = p
        return p
    }
}
