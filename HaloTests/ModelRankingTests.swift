import XCTest
@testable import Halo

final class ModelRankingTests: XCTestCase {
    private func model(_ id: String, iq: Double?, input: Double, output: Double, created: Double = 0, coding: Double? = nil) -> ORModel {
        var json: [String: Any] = [
            "id": id, "name": "Lab: \(id)", "created": created,
            "pricing": ["prompt": String(input / 1_000_000), "completion": String(output / 1_000_000)],
        ]
        var aa: [String: Any] = [:]
        if let iq { aa["intelligence_index"] = iq }
        if let coding { aa["coding_index"] = coding }
        if !aa.isEmpty { json["benchmarks"] = ["artificial_analysis": aa] }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ORModel.self, from: data)
    }

    /// Scores and prices from the live catalog on 2026-10-24.
    private var catalog: [ORModel] {
        [
            model("anthropic/claude-opus-5.5", iq: 57.6, input: 4, output: 20),
            model("anthropic/claude-sonnet-5.5", iq: 56.0, input: 2, output: 10),
            model("anthropic/claude-sonnet-5.5:batch", iq: 56.0, input: 1, output: 5),
            model("xiaomi/mimo-v2.6-pro", iq: 46.3, input: 0.435, output: 0.87),
            model("z-ai/glm-5.3-flash", iq: 41.8, input: 0.15, output: 0.5),
            model("z-ai/glm-5.3-flash:batch", iq: 41.8, input: 0.05, output: 0.18),
            model("xiaomi/mimo-v2.6-flash", iq: 37.9, input: 0.14, output: 0.28),
            model("inclusionai/ling-3.0-flash", iq: 20.1, input: 0.021, output: 0.063),
            model("someone/free-model:free", iq: 30, input: 0, output: 0),
        ]
    }

    func testValueLeavesOutWeakModelsHoweverCheap() {
        let scores = ModelRanking.valueScores(catalog, catalog: catalog)
        XCTAssertNil(scores["inclusionai/ling-3.0-flash"], "20 is far below 65% of the best (57.6)")
        XCTAssertNotNil(scores["xiaomi/mimo-v2.6-flash"], "37.9 clears the bar")
        XCTAssertNil(scores["z-ai/glm-5.3-flash:batch"], "batch variants aren't chat models")
        XCTAssertNil(scores["someone/free-model:free"])
        XCTAssertGreaterThan(scores["z-ai/glm-5.3-flash"]!, scores["anthropic/claude-sonnet-5.5"]!)
    }

    func testValueBarIgnoresTheSearch() {
        // Searching only weak models mustn't make the weakest of them "good value".
        let weak = catalog.filter { $0.id.contains("ling") }
        XCTAssertTrue(ModelRanking.valueScores(weak, catalog: catalog).isEmpty)
    }

    func testTopPicksMergeReasons() {
        let models = [
            model("anthropic/smart", iq: 60, input: 3, output: 15, created: 1, coding: 50),
            model("z-ai/cheap", iq: 50, input: 0.1, output: 0.4, created: 2),
            model("smalllab/cheaper", iq: 50, input: 0.05, output: 0.2, created: 0),
        ]
        let picks = ModelRanking.topPicks(models)
        XCTAssertEqual(picks.first { $0.id == "anthropic/smart" }?.reasons, [.smartest, .coding])
        XCTAssertEqual(picks.first { $0.id == "z-ai/cheap" }?.reasons, [.value, .newest], "the value pick comes from a big lab")
    }

    func testNewModels() {
        let models = [model("openai/old", iq: nil, input: 1, output: 1, created: 100),
                      model("openai/new", iq: nil, input: 1, output: 1, created: 300),
                      model("inclusionai/ling-9", iq: nil, input: 1, output: 1, created: 300)]
        XCTAssertEqual(ModelRanking.newModels(models, since: Date(timeIntervalSince1970: 200)), ["openai/new"], "small labs aren't flagged")
        XCTAssertTrue(ModelRanking.newModels(models, since: nil).isEmpty)
    }

    func testReleaseStamp() {
        XCTAssertEqual(ModelRanking.splitReleaseStamp("DeepSeek V4.1 Flash 1017")?.name, "DeepSeek V4.1 Flash")
        XCTAssertEqual(ModelRanking.splitReleaseStamp("DeepSeek V4.1 Flash 1017")?.stamp, "1017")
        XCTAssertNil(ModelRanking.splitReleaseStamp("GPT-6 Luna"))
        XCTAssertNil(ModelRanking.splitReleaseStamp("Model 2024"))
        XCTAssertEqual(ModelRanking.splitReleaseStamp("Gemini Pro (2025-10-17)")?.stamp, "2025-10-17")
    }
}
