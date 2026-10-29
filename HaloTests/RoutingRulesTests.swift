import XCTest
@testable import Halo

final class RoutingRulesTests: XCTestCase {

    func testPresetsSurviveCodableRoundTrip() throws {
        for preset in RoutingPreset.allCases {
            var rules = preset.rules
            rules.blocked = ["together"]
            let decoded = try JSONDecoder().decode(RoutingRules.self, from: JSONEncoder().encode(rules))
            XCTAssertEqual(decoded, rules, preset.rawValue)
            XCTAssertEqual(decoded.matchingPreset, preset, preset.rawValue)
        }
    }

    func testPresetPreferences() {
        let endpoints = [ep("relace"), ep("quantized", quant: "fp4")]
        let balanced = object(RoutingPreset.balanced.rules.preferences(for: "m", endpoints: endpoints))
        XCTAssertEqual(balanced["sort"], "price")
        XCTAssertEqual(balanced["preferred_min_throughput"], 40)
        XCTAssertEqual(balanced["preferred_max_latency"], 3)
        XCTAssertEqual(balanced["allow_fallbacks"], true)
        XCTAssertEqual(order(balanced), ["relace"])
        XCTAssertEqual(balanced["quantizations"]?.arrayValue?.compactMap(\.stringValue), ["fp8"])

        let cheapest = object(RoutingPreset.cheapest.rules.preferences(for: "m", endpoints: endpoints))
        XCTAssertEqual(cheapest["sort"], "price")
        XCTAssertNil(cheapest["preferred_min_throughput"])
        XCTAssertNil(cheapest["preferred_max_latency"])
        XCTAssertNil(cheapest["quantizations"])

        let fastest = object(RoutingPreset.fastest.rules.preferences(for: "m", endpoints: endpoints))
        XCTAssertEqual(fastest["sort"], "throughput")
        XCTAssertNotNil(fastest["quantizations"])

        let qualityEndpoints = [ep("relace", quant: "fp16"), ep("quantized", quant: "fp4")]
        let quality = object(RoutingPreset.quality.rules.preferences(for: "m", endpoints: qualityEndpoints))
        XCTAssertEqual(quality["quantizations"]?.arrayValue?.compactMap(\.stringValue), ["fp16"])
        XCTAssertNil(RoutingPreset.openRouter.rules.preferences(for: "m", endpoints: endpoints))
    }

    func testOpenRouterOnlySendsIndependentPolicies() {
        var rules = RoutingPreset.openRouter.rules
        rules.blocked = ["together"]
        rules.denyDataCollection = true
        let p = object(rules.preferences(for: "m", endpoints: [ep("relace")]))
        XCTAssertEqual(p["ignore"]?.arrayValue, ["together"])
        XCTAssertEqual(p["data_collection"], "deny")
        XCTAssertNil(p["sort"])
        XCTAssertNil(p["order"])
        XCTAssertNil(p["allow_fallbacks"])
    }

    func testUnknownEndpointsKeepPriceButNotPrecisionFilter() {
        let rules = RoutingRules(maxPrompt: 2, maxCompletion: 3)
        let p = object(rules.preferences(for: "m", endpoints: nil))
        XCTAssertEqual(p["max_price"]?["prompt"], 2)
        XCTAssertEqual(p["max_price"]?["completion"], 3)
        XCTAssertNil(p["quantizations"])
        XCTAssertNil(p["order"])
    }

    func testHardFiltersRelaxWhenTheyExcludeEveryProvider() {
        let allFourBit = [ep("one", quant: "fp4"), ep("two", quant: "nvfp4")]
        let p = object(RoutingRules().preferences(for: "m", endpoints: allFourBit))
        XCTAssertNil(p["quantizations"])
        XCTAssertEqual(order(p), ["one", "two"])
        XCTAssertEqual(RoutingRules.hardFilterWarning(allFourBit, rules: RoutingRules()),
                       "No provider fits — precision filter ignored for this model")

        var tooCheap = RoutingRules(maxPrompt: 0.01, maxCompletion: 0.01)
        tooCheap.precision = .any
        let endpoints = [ep("one", prompt: 1, completion: 1)]
        let limited = object(tooCheap.preferences(for: "m", endpoints: endpoints))
        XCTAssertNil(limited["max_price"])
        XCTAssertEqual(RoutingRules.hardFilterWarning(endpoints, rules: tooCheap),
                       "No provider fits — price limit ignored for this model")
    }

    func testPinsBlocksAndOrderCap() {
        let endpoints = (0..<12).map { ep("p\($0)", prompt: Double($0 + 1)) }
        var rules = RoutingPreset.cheapest.rules
        rules.blocked = ["p2", "p11"]
        let model = ModelRouting(pinned: ["p11", "p10"], blocked: ["p2", "p3"])
        let p = object(rules.preferences(for: "m", endpoints: endpoints, model: model))
        XCTAssertEqual(order(p), ["p11", "p10", "p0", "p1", "p4", "p5", "p6", "p7"])
        XCTAssertEqual(p["ignore"]?.arrayValue?.compactMap(\.stringValue), ["p2", "p3"])
    }

    func testStickyProviderFollowsPinsAndHardFilters() {
        var rules = RoutingPreset.cheapest.rules
        rules.stickyPerChat = true
        let endpoints = [ep("cheap", prompt: 1), ep("sticky", prompt: 2), ep("pinned", prompt: 3)]
        let p = object(rules.preferences(for: "m", endpoints: endpoints,
                                         model: ModelRouting(pinned: ["pinned"]), lastProvider: "Sticky"))
        XCTAssertEqual(order(p), ["pinned", "sticky", "cheap"])

        rules.precision = .full
        let withFullPrecision = endpoints + [ep("full", prompt: 4, quant: "fp16")]
        let rejected = object(rules.preferences(for: "m", endpoints: withFullPrecision, lastProvider: "Sticky"))
        XCTAssertNotEqual(order(rejected).first, "sticky")
    }

    func testRankPrefersProvidersMeetingSoftThresholds() {
        let endpoints = [
            ep("cheap-slow", prompt: 1, tps: 20, latency: 4),
            ep("fast-expensive", prompt: 4, tps: 80, latency: 1),
            ep("fast-medium", prompt: 2, tps: 60, latency: 2),
        ]
        let ranked = RoutingRules.rank(endpoints, rules: RoutingRules())
        XCTAssertEqual(picks(ranked), ["fast-medium", "fast-expensive", "cheap-slow"])
        XCTAssertFalse(RoutingRules.meetsSoftThresholds(endpoints[0], rules: RoutingRules()))
    }

    func testRankStatusesAndBlendedPrice() {
        let endpoints = [
            ep("output-cheap", prompt: 4, completion: 1),
            ep("input-cheap", prompt: 1, completion: 3),
            ep("four-bit", prompt: 0.1, quant: "fp4"),
            ep("blocked", prompt: 0.2),
            ep("flex", prompt: 0.3, tier: .flex),
        ]
        let rules = RoutingRules(blocked: ["blocked"])
        let ranked = RoutingRules.rank(endpoints, rules: rules)
        XCTAssertEqual(picks(ranked), ["input-cheap", "output-cheap"])
        XCTAssertEqual(ranked.dropFirst(2).map { $0.1 }, [
            .skipped(reason: "4-bit"), .skipped(reason: "blocked"), .skipped(reason: "other tier"),
        ])
    }

    func testPresetsKeepIndependentSettings() {
        var rules = RoutingRules(maxPrompt: 1, denyDataCollection: true, blocked: ["together"], stickyPerChat: true)
        rules.allowFallbacks = false
        XCTAssertEqual(rules.matchingPreset, .balanced)
        rules.apply(.cheapest)
        XCTAssertEqual(rules.matchingPreset, .cheapest)
        XCTAssertEqual(rules.maxPrompt, 1)
        XCTAssertTrue(rules.denyDataCollection)
        XCTAssertTrue(rules.stickyPerChat)
        XCTAssertFalse(rules.allowFallbacks)
        XCTAssertEqual(rules.blocked, ["together"])
        rules.minThroughput = 100
        XCTAssertNil(rules.matchingPreset)
    }

    func testOpenRouterPresetSendsPriceLimitAndDisabledFallbacks() {
        var rules = RoutingPreset.openRouter.rules
        rules.maxCompletion = 2
        rules.allowFallbacks = false
        let p = object(rules.preferences(for: "m", endpoints: [ep("relace", completion: 1)]))
        XCTAssertEqual(p["max_price"]?["completion"], 2)
        XCTAssertEqual(p["allow_fallbacks"], false)
        XCTAssertNil(p["order"])
        XCTAssertNil(p["sort"])
    }

    /// OpenRouter's endpoint list reports no throughput or latency for most models.
    func testMissingStatsAreNotSlowAndDontFakeAnOrder() {
        let endpoints = [
            ep("alpha", prompt: 3, tps: nil, latency: nil),
            ep("cheap", prompt: 1, tps: nil, latency: nil),
            ep("pinned", prompt: 2, tps: nil, latency: nil),
        ]
        XCTAssertTrue(RoutingRules.meetsSoftThresholds(endpoints[0], rules: RoutingRules()))
        let balanced = object(RoutingRules().preferences(for: "m", endpoints: endpoints))
        XCTAssertEqual(order(balanced), ["cheap", "pinned", "alpha"])

        let fastest = RoutingPreset.fastest.rules
        XCTAssertNil(object(fastest.preferences(for: "m", endpoints: endpoints))["order"])
        let pinned = object(fastest.preferences(for: "m", endpoints: endpoints, model: ModelRouting(pinned: ["pinned"])))
        XCTAssertEqual(order(pinned), ["pinned"])
        XCTAssertEqual(pinned["sort"], "throughput")
    }

    func testPriceTiesBreakOnUptimeNotName() {
        var flaky = ep("a-flaky")
        flaky.uptime = 80
        var solid = ep("z-solid")
        solid.uptime = 100
        XCTAssertEqual(picks(RoutingRules.rank([flaky, solid], rules: RoutingRules())), ["z-solid", "a-flaky"])
    }

    func testRelaxingPrecisionKeepsPriceLimit() {
        let endpoints = [ep("four-bit", prompt: 1, quant: "fp4"), ep("pricey-four-bit", prompt: 9, quant: "fp4")]
        let rules = RoutingRules(maxPrompt: 2)
        let p = object(rules.preferences(for: "m", endpoints: endpoints))
        XCTAssertEqual(p["max_price"]?["prompt"], 2)
        XCTAssertNil(p["quantizations"])
        XCTAssertEqual(order(p), ["four-bit"])
        XCTAssertEqual(RoutingRules.hardFilterWarning(endpoints, rules: rules),
                       "No provider fits — precision filter ignored for this model")
    }

    func testEndpointInfoDecoding() throws {
        let json = #"{"data":{"endpoints":[{"provider_name":"Z.AI","tag":"z-ai/fp8","quantization":"fp8","uptime_last_30m":99.5,"throughput_last_30m":64.2,"latency_last_30m":{"p50":1.25},"pricing":{"prompt":"0.00000015","completion":"0.0000005"}},{"provider_name":"Null Stats","tag":"null-stats","throughput_last_30m":null,"latency_last_30m":null,"pricing":{"prompt":"0.000001","completion":"0.000002"}}]}}"#
        let endpoints = try JSONDecoder().decode(ModelEndpoints.self, from: Data(json.utf8)).infos
        XCTAssertEqual(endpoints[0].slug, "z-ai")
        XCTAssertEqual(endpoints[0].name, "Z.AI")
        XCTAssertEqual(endpoints[0].tag, "z-ai/fp8")
        XCTAssertEqual(endpoints[0].tps ?? 0, 64.2, accuracy: 0.0001)
        XCTAssertEqual(endpoints[0].latency ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(endpoints[0].uptime ?? 0, 99.5, accuracy: 0.0001)
        XCTAssertEqual(endpoints[0].prompt, 0.15, accuracy: 0.0001)
        XCTAssertNil(endpoints[1].tps)
        XCTAssertNil(endpoints[1].latency)
        XCTAssertEqual(endpoints[1].quant, "unknown")
    }

    func testFrontendStatsDecoding() throws {
        let json = #"{"data":[{"provider_slug":"wafer/us","stats":{"p50_latency":413,"p50_throughput":121}},{"provider_slug":"sail-research/us","stats":null},{"provider_slug":"relace","stats":{"p50_latency":1154.5,"p50_throughput":null}}]}"#
        let stats = try JSONDecoder().decode(EndpointStatsList.self, from: Data(json.utf8)).byTag
        XCTAssertEqual(stats["wafer/us"]?.tps, 121)
        XCTAssertEqual(stats["wafer/us"]?.latency ?? 0, 0.413, accuracy: 0.0001)
        XCTAssertNil(stats["sail-research/us"])
        XCTAssertNil(stats["relace"]?.tps ?? nil)

        let endpoints = #"{"data":{"endpoints":[{"name":"Relace | z-ai/glm-5.3-flash-20260826","tag":"relace","pricing":{"prompt":"0","completion":"0"}}]}}"#
        XCTAssertEqual(try JSONDecoder().decode(ModelEndpoints.self, from: Data(endpoints.utf8)).permaslug,
                       "z-ai/glm-5.3-flash-20260826")
    }

    private func ep(_ slug: String, prompt: Double = 1, completion: Double = 1,
                    quant: String = "fp8", tps: Double? = 60, latency: Double? = 1,
                    tier: ServiceTier = .standard) -> EndpointInfo {
        EndpointInfo(slug: slug, name: slug.capitalized, tier: tier, prompt: prompt,
                     completion: completion, quant: quant, tps: tps, latency: latency)
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        value?.objectValue ?? [:]
    }

    private func order(_ p: [String: JSONValue]) -> [String] {
        p["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func picks(_ ranked: [(EndpointInfo, RoutingRules.RankStatus)]) -> [String] {
        ranked.compactMap { endpoint, status in
            if case .pick = status { return endpoint.slug }
            return nil
        }
    }
}
