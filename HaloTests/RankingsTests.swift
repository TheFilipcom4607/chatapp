import XCTest
@testable import Halo

final class RankingsTests: XCTestCase {

    func testDecodesRankingsDaily() throws {
        let json = #"{"data":[{"date":"2026-10-24","model_permaslug":"openai/gpt-6.1-sol-20260929","total_tokens":"1234567890123"},{"date":"2026-10-24","model_permaslug":"other","total_tokens":"5"}],"meta":{"as_of":"2026-10-25T08:00:00Z","version":"v1","start_date":"2026-09-25","end_date":"2026-10-24"}}"#
        let daily = try JSONDecoder().decode(RankingsDaily.self, from: Data(json.utf8))
        XCTAssertEqual(daily.data.count, 2)
        XCTAssertEqual(daily.data[0].tokens, 1_234_567_890_123)
        XCTAssertEqual(daily.meta?.endDate, "2026-10-24")
    }

    func testDecodesTaskClassifications() throws {
        let json = #"{"data":{"window_days":7,"as_of":"2026-10-24","classifications":[{"tag":"coding_agent","display_name":"Agentic coding","macro_category":"technical","usage_share":0.31,"token_share":0.4,"category_usage_share":0.7,"category_token_share":0.8,"models":[{"id":"anthropic/claude-sonnet-5.5","tag_usage_share":0.34,"tag_token_share":0.3}]}],"macro_categories":[{"key":"technical","label":"Technical","usage_share":0.44,"token_share":0.58}]}}"#
        let tasks = try JSONDecoder().decode(TaskClassifications.self, from: Data(json.utf8))
        XCTAssertEqual(tasks.data.classifications.first?.models.first?.tagUsageShare, 0.34)
        XCTAssertEqual(tasks.data.macroCategories?.first?.label, "Technical")
    }

    func testDecodesAppRankings() throws {
        let json = #"{"data":[{"rank":1,"app_id":42,"app_name":"Cline","total_tokens":"900000000000","total_requests":12345}],"meta":{"as_of":"x"}}"#
        let apps = try JSONDecoder().decode(AppRankings.self, from: Data(json.utf8))
        XCTAssertEqual(apps.data.first?.appID?.value, "42")
        XCTAssertEqual(apps.data.first?.totalTokens.value, 9e11)
    }

    func testBenchmarkItemReadsWhicheverFieldsItGets() throws {
        let json = #"{"data":[{"model_permaslug":"openai/gpt-6.1-sol","primary_score":0.81,"avg_cost_per_task":0.02},{"slug":"x/y","elo":1290,"win_rate":0.6},{"name":"no model"}],"meta":{"citation":"Source: OpenRouter evals"}}"#
        let list = try JSONDecoder().decode(BenchmarkList.self, from: Data(json.utf8))
        XCTAssertEqual(list.citation, "Source: OpenRouter evals")
        let evals = list.data.compactMap { BenchmarkItem($0, scoreKeys: ["primary_score"]) }
        XCTAssertEqual(evals.map(\.model), ["openai/gpt-6.1-sol"])
        XCTAssertEqual(evals.first?.costPerTask, 0.02)
        let arena = list.data.compactMap { BenchmarkItem($0, scoreKeys: ["elo"]) }
        XCTAssertEqual(arena.first?.model, "x/y")
        XCTAssertEqual(arena.first?.winRate, 0.6)
    }

    func testUsageWeeksAndChange() {
        func row(_ date: String, _ slug: String, _ tokens: Double) -> RankingsDaily.Row {
            .init(date: date, modelPermaslug: slug, totalTokens: FlexibleDouble(tokens))
        }
        // Week 0 is Oct 18–24, week 1 Oct 11–17.
        let rows = [
            row("2026-10-24", "a/one", 30), row("2026-10-18", "a/one", 10), row("2026-10-24", "other", 60),
            row("2026-10-17", "a/one", 20), row("2026-10-11", "b/two", 5), row("2026-10-24", "b/two", 0),
        ]
        let stats = UsageStats(rows: rows, weeks: 2)
        XCTAssertEqual(stats.weekly[0]["a/one"], 40)
        XCTAssertEqual(stats.weekly[1]["a/one"], 20)
        let ranking = stats.ranking()
        XCTAssertEqual(ranking.first?.slug, "a/one")
        XCTAssertEqual(ranking.first?.share ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ranking.first?.change ?? 0, 1, accuracy: 1e-9)
        XCTAssertFalse(ranking.contains { $0.slug == UsageStats.otherSlug })
        XCTAssertEqual(stats.daily["a/one"]?.last, 30)
        XCTAssertEqual(stats.grouped(UsageStats.lab)[0], ["a": 40, "b": 0])
    }

    func testSlugHelpers() {
        XCTAssertEqual(UsageStats.lab("openai/gpt-6.1-sol-20260929"), "openai")
        XCTAssertNil(UsageStats.lab("other"))
        XCTAssertEqual(UsageStats.fallbackName("acme/super-model-2-20260801"), "Super Model 2")
    }

    func testParetoFrontier() {
        let points: [ParetoFrontier.Point] = [
            .init(id: "cheap", price: 0.1, score: 20),
            .init(id: "worse", price: 0.5, score: 18),
            .init(id: "mid", price: 1, score: 40),
            .init(id: "tie", price: 1, score: 35),
            .init(id: "top", price: 8, score: 58),
            .init(id: "pricey", price: 30, score: 50),
        ]
        XCTAssertEqual(ParetoFrontier.frontier(points).map(\.id), ["cheap", "mid", "top"])
    }

    func testFormats() {
        XCTAssertEqual(RankingsFormat.tokens(2.1e12), "2.1T")
        XCTAssertEqual(RankingsFormat.tokens(822e9), "822B")
        XCTAssertEqual(RankingsFormat.share(0.118), "11.8%")
        XCTAssertEqual(RankingsFormat.share(0.0042), "0.42%")
        XCTAssertEqual(RankingsFormat.change(-0.08), "−8%")
        XCTAssertEqual(DiscoverView.percentile(5, [1, 2, 5, 9]), 75)
    }
}
