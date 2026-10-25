import Foundation
import Observation

/// openrouter.ai/rankings in the app: OpenRouter's Data API datasets, cached on disk. Each is
/// fetched when the screen opens and it's over three hours old; the API allows 500 calls a day.
@MainActor
@Observable
final class RankingsStore {
    /// One of the benchmark boards the API serves.
    struct Board: Hashable, Identifiable, Sendable {
        let key: String
        let title: String
        let params: [String: String]
        /// Fields that may hold the score, first found wins.
        let scoreKeys: [String]
        /// Elo rather than a 0–1 or 0–100 score.
        var isElo = false
        var id: String { key }

        static let all: [Board] = [
            evals("gpqa_diamond", "GPQA Diamond"),
            evals("tau_bench_verified_airline", "τ-bench airline"),
            evals("search_browsecomp", "BrowseComp"),
            evals("search_hle", "HLE + search"),
            evals("search_dsqa", "DSQA"),
            evals("search_widesearch", "WideSearch"),
            Board(key: "design-arena", title: "Design Arena", params: ["source": "design-arena", "arena": "models"],
                  scoreKeys: ["elo"], isElo: true),
        ]

        private static func evals(_ type: String, _ title: String) -> Board {
            Board(key: type, title: title, params: ["source": "openrouter", "benchmark_type": type],
                  scoreKeys: ["primary_score", "score"])
        }
    }

    private(set) var daily: RankingsDaily?
    private(set) var tasks: TaskClassifications?
    /// By sort, "popular" or "trending".
    private(set) var apps: [String: AppRankings] = [:]
    private(set) var benchmarks: [String: BenchmarkList] = [:]
    /// The last failure per dataset key ("daily", "tasks", "apps-popular", a board's key).
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    private var fetchedAt: [String: Date] = [:]
    /// Weeks of daily usage fetched; the charts show them all.
    static let weeks = 26

    private let client: OpenRouterClient

    init(client: OpenRouterClient) {
        self.client = client
        loadCache()
    }

    /// The usage, task and popular-app datasets.
    func refresh(force: Bool = false) async {
        if DemoRankings.applies {
            daily = DemoRankings.daily()
            tasks = DemoRankings.tasks()
            apps["popular"] = DemoRankings.apps("popular")
            return
        }
        let (start, end) = Self.dayRange(days: Self.weeks * 7)
        async let d: Void = load("daily", force: force, { [client] in try await client.rankingsDaily(start: start, end: end) }) { self.daily = $0 }
        async let t: Void = load("tasks", force: force, { [client] in try await client.taskClassifications() }) { self.tasks = $0 }
        async let a: Void = loadApps("popular", force: force)
        _ = await (d, t, a)
    }

    func loadApps(_ sort: String, force: Bool = false) async {
        if DemoRankings.applies { apps[sort] = DemoRankings.apps(sort); return }
        await load("apps-\(sort)", force: force, { [client] in try await client.appRankings(sort: sort) }) { self.apps[sort] = $0 }
    }

    func loadBoard(_ board: Board, force: Bool = false) async {
        if DemoRankings.applies { benchmarks[board.key] = DemoRankings.board(board); return }
        await load(board.key, force: force, { [client] in try await client.benchmarks(board.params) }) { self.benchmarks[board.key] = $0 }
    }

    func items(_ board: Board) -> [BenchmarkItem] {
        (benchmarks[board.key]?.data ?? [])
            .compactMap { BenchmarkItem($0, scoreKeys: board.scoreKeys) }
            .sorted { $0.score > $1.score }
    }

    /// Runs one fetch unless it's fresh or already running; `apply` lands the result on the store.
    private func load<T: Sendable>(_ key: String, force: Bool, _ fetch: @Sendable () async throws -> T, apply: @MainActor (T) -> Void) async {
        if !force, let at = fetchedAt[key], Date().timeIntervalSince(at) < 60 * 60 * 3 { return }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            apply(try await fetch())
            errors[key] = nil
            fetchedAt[key] = .now
            saveCache()
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    // MARK: Days

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func day(_ string: String) -> Date? { dayFormatter.date(from: string) }
    nonisolated static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// The `days` UTC days ending yesterday, the last complete one.
    nonisolated static func dayRange(days: Int, now: Date = .now) -> (start: String, end: String) {
        let end = now.addingTimeInterval(-86_400)
        let start = end.addingTimeInterval(-Double(days - 1) * 86_400)
        return (dayString(start), dayString(end))
    }

    // MARK: Cache

    private struct CacheFile: Codable {
        var daily: RankingsDaily?
        var tasks: TaskClassifications?
        var apps: [String: AppRankings]
        var benchmarks: [String: BenchmarkList]
        var fetchedAt: [String: Date]
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("rankings-v1.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        daily = cache.daily
        tasks = cache.tasks
        apps = cache.apps
        benchmarks = cache.benchmarks
        fetchedAt = cache.fetchedAt
    }

    private func saveCache() {
        let cache = CacheFile(daily: daily, tasks: tasks, apps: apps, benchmarks: benchmarks, fetchedAt: fetchedAt)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheURL) }
    }
}

/// Weekly sums of the daily usage rows. Week 0 is the seven days ending on the latest day.
struct UsageStats {
    struct Entry: Identifiable, Hashable {
        let slug: String
        let tokens: Double
        /// Of every token that week, the "other" row's included.
        let share: Double
        /// The week before; nil when it wasn't in that week's top 50.
        let previous: Double?
        var id: String { slug }
        var change: Double? { previous.flatMap { $0 > 0 ? tokens / $0 - 1 : nil } }
    }

    /// The row covering every model past the top 50.
    static let otherSlug = "other"

    let latestDay: Date?
    /// Week index → slug → tokens.
    let weekly: [[String: Double]]
    /// Slug → tokens per day, oldest first, over the last 30 days (0 where a day is missing).
    let daily: [String: [Double]]

    init(rows: [RankingsDaily.Row], weeks: Int) {
        let dated = rows.compactMap { row in RankingsStore.day(row.date).map { (row, $0) } }
        let latest = dated.map(\.1).max()
        latestDay = latest
        var weekly = Array(repeating: [String: Double](), count: weeks)
        var daily: [String: [Double]] = [:]
        if let latest {
            for (row, date) in dated {
                let age = Int((latest.timeIntervalSince(date) / 86_400).rounded())
                if age / 7 < weeks { weekly[age / 7][row.modelPermaslug, default: 0] += row.tokens }
                if age < 30 {
                    daily[row.modelPermaslug, default: Array(repeating: 0, count: 30)][29 - age] += row.tokens
                }
            }
        }
        self.weekly = weekly
        self.daily = daily
    }

    /// The Monday-or-whatever first day of a week, for chart axes.
    func weekStart(_ week: Int) -> Date {
        (latestDay ?? .now).addingTimeInterval(-Double(week * 7 + 6) * 86_400)
    }

    func total(_ week: Int) -> Double { weekly[safe: week]?.values.reduce(0, +) ?? 0 }

    /// The week's models, most tokens first, without the "other" row.
    func ranking(week: Int = 0) -> [Entry] {
        guard let tokens = weekly[safe: week] else { return [] }
        let total = total(week)
        let previous = weekly[safe: week + 1]
        return tokens.filter { $0.key != Self.otherSlug }
            .sorted { $0.value > $1.value }
            .map { Entry(slug: $0.key, tokens: $0.value, share: total > 0 ? $0.value / total : 0, previous: previous?[$0.key]) }
    }

    /// Tokens per group each week, for a share or stack chart. Rows `group` returns nil for are left
    /// out, and so are the shares they'd take.
    func grouped(_ group: (String) -> String?) -> [[String: Double]] {
        weekly.map { week in
            var sums: [String: Double] = [:]
            for (slug, tokens) in week { if let key = group(slug) { sums[key, default: 0] += tokens } }
            return sums
        }
    }

    /// The lab in a slug: "openai/gpt-6.1-sol-20260801" → "openai".
    static func lab(_ slug: String) -> String? {
        slug == otherSlug ? nil : slug.split(separator: "/").first.map(String.init)
    }

    /// A readable name for a slug no catalog model has: "acme/super-model-2-20260801" → "Super Model 2".
    static func fallbackName(_ slug: String) -> String {
        var name = slug.split(separator: "/").last.map(String.init) ?? slug
        if let r = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(r) }
        return name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// The models nothing beats on both price and score: cheaper ones all score lower.
enum ParetoFrontier {
    struct Point: Hashable, Identifiable {
        let id: String
        let price: Double
        let score: Double
    }

    /// Frontier points, cheapest first.
    static func frontier(_ points: [Point]) -> [Point] {
        var best = -Double.infinity
        var result: [Point] = []
        for p in points.sorted(by: { $0.price != $1.price ? $0.price < $1.price : $0.score > $1.score }) where p.score > best {
            best = p.score
            result.append(p)
        }
        return result
    }
}

enum RankingsFormat {
    /// 1.2T, 340B, 12M tokens.
    static func tokens(_ value: Double) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (size, suffix) in units where value >= size {
            let v = value / size
            return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + suffix
        }
        return String(format: "%.0f", value)
    }

    /// 0.123 → "12.3%"; under 1% keeps two decimals.
    static func share(_ value: Double) -> String {
        let pct = value * 100
        return pct < 1 ? String(format: "%.2f%%", pct) : String(format: "%.1f%%", pct)
    }

    /// +12% / −8%.
    static func change(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return pct >= 0 ? "+\(pct)%" : "−\(-pct)%"
    }
}
