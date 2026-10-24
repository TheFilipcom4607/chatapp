import XCTest
@testable import Halo

final class ModelInsightsTests: XCTestCase {
    private func model(_ id: String, iq: Double?, input: Double, output: Double, slug: String? = nil) -> ORModel {
        var json: [String: Any] = [
            "id": id, "name": "Lab: \(id)", "canonical_slug": slug ?? id,
            "pricing": ["prompt": String(input / 1_000_000), "completion": String(output / 1_000_000)],
        ]
        if let iq { json["benchmarks"] = ["artificial_analysis": ["intelligence_index": iq]] }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ORModel.self, from: data)
    }

    // Blended prices (3:1) in the comments.
    private lazy var mid = model("lab/mid", iq: 46, input: 2, output: 10)                 // $4
    private lazy var catalog: [ORModel] = [
        model("anthropic/claude-opus-5.5", iq: 57.6, input: 4, output: 20),                 // $8
        model("anthropic/claude-sonnet-5.5", iq: 56, input: 2, output: 10),                 // $4
        model("anthropic/claude-sonnet-5.5:batch", iq: 56, input: 1, output: 5),            // batch-only: never offered
        model("lab/rival", iq: 57, input: 1.6, output: 8),                                  // $3.20
        model("lab/quick", iq: 45, input: 3, output: 12),                                   // $5.25
        model("xiaomi/mimo-v2.6-pro", iq: 46.3, input: 0.435, output: 0.87),                // $0.54
        model("z-ai/glm-5.3-flash", iq: 41.8, input: 0.15, output: 0.5),                    // $0.24
        model("someone/free-model:free", iq: 30, input: 0, output: 0),
        mid,
    ]
    private let speeds: [String: Double] = [
        "lab/mid": 50, "anthropic/claude-sonnet-5.5": 60, "anthropic/claude-opus-5.5": 80, "lab/rival": 90,
        "lab/quick": 110, "xiaomi/mimo-v2.6-pro": 120, "z-ai/glm-5.3-flash": 200,
    ]

    func testAlternatives() {
        let alts = ModelInsights.alternatives(to: mid, among: catalog) { self.speeds[$0.id] }
        XCTAssertEqual(alts.map(\.kind), [.smarter, .cheaper, .faster])
        // Smartest at no more than 10% over the price: the rival beats Sonnet on both counts.
        XCTAssertEqual(alts[0].model.id, "lab/rival")
        XCTAssertEqual(alts[0].detail, "+11 IQ, similar price")
        // Within 2 points and at most two-thirds the price; GLM is too far behind.
        XCTAssertEqual(alts[1].model.id, "xiaomi/mimo-v2.6-pro")
        XCTAssertEqual(alts[1].detail, "same IQ, 7× cheaper")
        // GLM is fastest but too far behind, MiMo and the rival are already listed, Opus costs
        // more than 1.5×: Quick it is.
        XCTAssertEqual(alts[2].model.id, "lab/quick")
        XCTAssertEqual(alts[2].detail, "2.2× faster, −1 IQ")
    }

    func testNoAlternativesWithoutAScoreOrSpeed() {
        XCTAssertTrue(ModelInsights.alternatives(to: model("lab/unscored", iq: nil, input: 1, output: 1), among: catalog) { _ in nil }.isEmpty)
        // Without speeds there's no "faster".
        XCTAssertEqual(ModelInsights.alternatives(to: mid, among: catalog) { _ in nil }.map(\.kind), [.smarter, .cheaper])
    }

    func testPeersSkipBatchAndDuplicates() {
        let peers = ModelInsights.peers(catalog + [model("anthropic/claude-sonnet-5.5-20260928", iq: 56, input: 2, output: 10, slug: "anthropic/claude-sonnet-5.5")])
        XCTAssertFalse(peers.contains { $0.id.hasSuffix(":batch") })
        XCTAssertEqual(peers.filter { $0.canonicalSlug == "anthropic/claude-sonnet-5.5" }.count, 1)
    }

    func testRankAndFormat() {
        XCTAssertEqual(ModelInsights.rank(50, among: [60, 50, 40]).rank, 2)
        XCTAssertEqual(ModelInsights.rank(50, among: [60, 50, 40]).of, 3)
        XCTAssertEqual(ModelInsights.rank(50, among: [50, 50]).rank, 1)   // ties share the better rank
        XCTAssertEqual(ModelInsights.format(0.853, key: "gpqa"), "85%")
        XCTAssertEqual(ModelInsights.format(56, key: "artificial_analysis_math_index"), "56")
        XCTAssertEqual(ModelInsights.times(2.24), "2.2×")
        XCTAssertEqual(ModelInsights.times(7.36), "7×")
        XCTAssertEqual(ModelInsights.priceCompare(0, 4), "free")
        XCTAssertEqual(ModelInsights.priceCompare(8, 4), "2× the price")
        XCTAssertEqual(ModelInsights.iqDelta(-2.4), "−2 IQ")
    }

    func testChatModelStatsDecodesThePublishedFile() throws {
        let json = #"""
        {"models": {"openai/gpt-6-astra-20261001": {"aa": "GPT-6 Astra (Max)", "tps": 89, "ttft": 0.6, "ttfa": 21.3},
                    "lab/plain": {"aa": "Plain", "tps": 40}},
         "source": "Artificial Analysis", "unmatched": ["Not on OpenRouter"], "updated_at": "2026-10-24T05:23:00Z"}
        """#
        let stats = try ChatModelStats.decode(Data(json.utf8))
        XCTAssertEqual(stats.models["openai/gpt-6-astra-20261001"], .init(tps: 89, ttft: 0.6, ttfa: 21.3))
        XCTAssertEqual(stats.models["lab/plain"], .init(tps: 40, ttft: nil, ttfa: nil))
    }
}
