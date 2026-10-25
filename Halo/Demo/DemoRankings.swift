import Foundation

/// Made-up rankings for `-demo` runs on the demo key, which the Data API rejects: realistic
/// shapes for screenshots, not real figures.
@MainActor
enum DemoRankings {
    static var applies: Bool { DemoSeeder.isDemo && KeyStore.shared.apiKey == "sk-or-demo" }

    /// (slug, tokens a day in billions, weekly growth).
    private static let models: [(String, Double, Double)] = [
        ("anthropic/claude-sonnet-5.5-20260928", 310, 0.03),
        ("deepseek/deepseek-v4.1-flash-20261017", 260, 0.12),
        ("google/gemini-3.8-flash-20260902", 240, -0.01),
        ("anthropic/claude-opus-5.5-20260921", 190, 0.04),
        ("openai/gpt-6.1-sol-20260929", 170, 0.06),
        ("z-ai/glm-5.3-flash-20260826", 120, 0.05),
        ("openai/gpt-6-luna-20260922", 110, 0.02),
        ("xiaomi/mimo-v2.6-flash-20260921", 95, 0.09),
        ("moonshotai/kimi-k3-20260715", 80, -0.03),
        ("google/gemini-4-argon-20261013", 75, 0.2),
        ("anthropic/claude-haiku-5.5-20261007", 70, 0.08),
        ("z-ai/glm-5.3-20260816", 60, 0.01),
        ("minimax/minimax-m3-20260531", 45, -0.04),
        ("tencent/hy4-preview-20260827", 40, 0.07),
        ("meta/muse-spark-1.3-contributor-20260902", 35, 0.0),
        ("stepfun/step-5-preview-20261008", 25, 0.15),
        ("xiaomi/mimo-v2.6-pro-20260921", 22, 0.04),
        ("upstage/solar-mini4-20260922", 12, -0.02),
    ]

    static func daily() -> RankingsDaily {
        let (startString, endString) = RankingsStore.dayRange(days: RankingsStore.weeks * 7)
        guard let start = RankingsStore.day(startString), let end = RankingsStore.day(endString) else { return RankingsDaily(data: []) }
        let days = Int((end.timeIntervalSince(start) / 86_400).rounded()) + 1
        var rows: [RankingsDaily.Row] = []
        for d in 0..<days {
            let date = RankingsStore.dayString(start.addingTimeInterval(Double(d) * 86_400))
            let weeksAgo = Double(days - 1 - d) / 7
            var other = 0.0
            for (i, (slug, base, growth)) in models.enumerated() {
                // A model released after the day it'd count from has no row yet.
                if let released = RankingsStore.day(String(slug.suffix(8)).inserting("-", at: [4, 6])), released > start.addingTimeInterval(Double(d) * 86_400) { continue }
                let wobble = 1 + 0.08 * sin(Double(d) * 0.9 + Double(i))
                let tokens = base * 1e9 * pow(1 + growth, -weeksAgo) * wobble
                rows.append(.init(date: date, modelPermaslug: slug, totalTokens: FlexibleDouble(tokens)))
                other += tokens * 0.35
            }
            rows.append(.init(date: date, modelPermaslug: UsageStats.otherSlug, totalTokens: FlexibleDouble(other)))
        }
        return RankingsDaily(data: rows, meta: DatasetMeta(asOf: ISO8601DateFormatter().string(from: .now), startDate: startString, endDate: endString))
    }

    static func tasks() -> TaskClassifications {
        func tag(_ key: String, _ name: String, _ macro: String, _ share: Double, _ models: [(String, Double)]) -> TaskClassifications.Tag {
            .init(tag: key, displayName: name, macroCategory: macro, usageShare: share, tokenShare: share, categoryUsageShare: nil,
                  models: models.map { .init(id: $0.0, tagUsageShare: $0.1, tagTokenShare: $0.1) })
        }
        let sonnet = "anthropic/claude-sonnet-5.5", opus = "anthropic/claude-opus-5.5", flash = "deepseek/deepseek-v4.1-flash-1017",
            gemini = "google/gemini-3.8-flash", sol = "openai/gpt-6.1-sol", glm = "z-ai/glm-5.3-flash", luna = "openai/gpt-6-luna"
        return TaskClassifications(data: .init(
            windowDays: 7, asOf: RankingsStore.dayRange(days: 1).end,
            classifications: [
                tag("coding_agent", "Agentic coding", "technical", 0.31, [(sonnet, 0.34), (opus, 0.18), (sol, 0.14), (flash, 0.09)]),
                tag("code_review", "Code review", "technical", 0.07, [(opus, 0.29), (sonnet, 0.25), (sol, 0.12), (glm, 0.06)]),
                tag("data_extraction", "Data extraction", "technical", 0.06, [(gemini, 0.31), (luna, 0.17), (flash, 0.15), (glm, 0.08)]),
                tag("roleplay", "Roleplay", "creative", 0.14, [(flash, 0.27), (glm, 0.18), (gemini, 0.11), (sonnet, 0.07)]),
                tag("fiction", "Fiction writing", "creative", 0.05, [(sonnet, 0.22), (opus, 0.19), (flash, 0.13), (gemini, 0.07)]),
                tag("translation", "Translation", "language", 0.06, [(gemini, 0.36), (luna, 0.14), (flash, 0.12), (glm, 0.05)]),
                tag("qa", "Questions & answers", "general", 0.12, [(gemini, 0.21), (sol, 0.16), (flash, 0.15), (sonnet, 0.1)]),
                tag("research", "Research", "general", 0.05, [(opus, 0.24), (sol, 0.2), (gemini, 0.12), (sonnet, 0.1)]),
            ],
            macroCategories: [
                .init(key: "technical", label: "Technical", usageShare: 0.44, tokenShare: 0.58),
                .init(key: "creative", label: "Creative", usageShare: 0.19, tokenShare: 0.2),
                .init(key: "general", label: "General", usageShare: 0.17, tokenShare: 0.11),
                .init(key: "language", label: "Language", usageShare: 0.06, tokenShare: 0.04),
            ]))
    }

    static func apps(_ sort: String) -> AppRankings {
        let names = sort == "popular"
            ? ["Kilo Code", "Cline", "Roo Code", "SillyTavern", "liteLLM", "Janitor AI", "Open WebUI", "Zed", "Aider", "OpenHands", "Chub AI", "Continue"]
            : ["Zed", "OpenHands", "Goose", "Aider", "Open WebUI", "Continue", "Crush", "Void"]
        return AppRankings(data: names.enumerated().map { i, name in
            let tokens = 4.2e12 * pow(0.68, Double(i))
            return .init(rank: i + 1, appID: FlexibleString("\(i)"), appName: name, totalTokens: FlexibleDouble(tokens),
                         totalRequests: FlexibleDouble(tokens / 38_000))
        })
    }

    static func board(_ board: RankingsStore.Board) -> BenchmarkList {
        let ids = ["anthropic/claude-opus-5.5", "openai/gpt-6.1-sol", "google/gemini-4-argon", "anthropic/claude-sonnet-5.5",
                   "moonshotai/kimi-k3.1-pro", "z-ai/glm-5.3", "deepseek/deepseek-v4.1-flash-1017", "openai/gpt-6-luna"]
        let seed = Double(board.key.count)
        let items: [JSONValue] = ids.enumerated().map { i, id in
            var o: [String: JSONValue] = ["model_permaslug": .string(id)]
            if board.isElo {
                o["elo"] = .number(1310 - Double(i) * 22 - seed)
                o["win_rate"] = .number(0.71 - Double(i) * 0.04)
                o["avg_generation_time_ms"] = .number(42_000 + Double(i) * 6_500)
            } else {
                o["primary_score"] = .number(0.86 - Double(i) * 0.045 - seed / 300)
                o["primary_metric"] = .string("accuracy")
                o["avg_cost_per_task"] = .number(0.12 / Double(i + 1))
                o["avg_latency_per_task_ms"] = .number(31_000 + Double(i) * 4_000)
            }
            return .object(o)
        }
        return BenchmarkList(data: items, meta: .object(["citation": .string("Demo data, not real results.")]))
    }
}

private extension String {
    /// "20260921" → "2026-09-21".
    func inserting(_ separator: Character, at offsets: [Int]) -> String {
        var s = self
        for offset in offsets.reversed() where offset < s.count { s.insert(separator, at: s.index(s.startIndex, offsetBy: offset)) }
        return s
    }
}
