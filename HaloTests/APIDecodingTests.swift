import XCTest
@testable import Halo

final class APIDecodingTests: XCTestCase {

    func testKeyInfo() throws {
        let json = #"{"data":{"label":"sk-or-v1-au7...890","limit":100,"limit_remaining":74.5,"limit_reset":"monthly","include_byok_in_limit":false,"usage":25.5,"usage_daily":1.5,"usage_weekly":5.5,"usage_monthly":25.5,"byok_usage":0,"is_free_tier":false,"rate_limit":{"note":"x"}}}"#
        let info = try JSONDecoder().decode(DataEnvelope<KeyInfo>.self, from: Data(json.utf8)).data
        XCTAssertEqual(info.limitRemaining, 74.5)
        XCTAssertEqual(info.usageDaily, 1.5)
    }

    func testCredits() throws {
        let json = #"{"data":{"total_credits":100.5,"total_usage":25.75}}"#
        let c = try JSONDecoder().decode(DataEnvelope<CreditsInfo>.self, from: Data(json.utf8)).data
        XCTAssertEqual(c.balance, 74.75, accuracy: 0.0001)
    }

    func testModel() throws {
        let json = #"{"data":[{"id":"anthropic/claude-opus-5.5","canonical_slug":"anthropic/claude-opus-5.5-20260101","name":"Anthropic: Claude Opus 5.5","created":1692901234,"description":"d","context_length":1000000,"architecture":{"modality":"text->text","input_modalities":["text","image","file"],"output_modalities":["text"],"tokenizer":"Claude"},"pricing":{"prompt":"0.000004","completion":"0.00002","request":"0","image":"0","discount":0},"top_provider":{"context_length":1000000,"max_completion_tokens":128000,"is_moderated":true},"supported_parameters":["tools","reasoning"],"reasoning":{"mandatory":true,"supported_efforts":["max","high","none"],"default_effort":"high"},"links":{"details":"/x"},"benchmarks":{"design_arena":[{"arena":"models","category":"website","elo":1327,"win_rate":56.3,"rank":5}],"artificial_analysis":{"intelligence_index":61.4,"coding_index":77,"agentic_index":51}}}]}"#
        let list = try JSONDecoder().decode(ModelList<ORModel>.self, from: Data(json.utf8))
        let m = try XCTUnwrap(list.data.first)
        XCTAssertEqual(m.shortName, "Claude Opus 5.5")
        XCTAssertEqual(m.providerName, "Anthropic")
        XCTAssertTrue(m.supportsTools)
        XCTAssertTrue(m.supportsVision)
        XCTAssertTrue(m.supportsFiles)
        XCTAssertEqual(m.promptPricePerMillion ?? 0, 4, accuracy: 0.0001)
        XCTAssertEqual(m.reasoningEfforts, ["max", "high"])
        XCTAssertFalse(m.isFree)
        XCTAssertEqual(m.canonicalSlug, "anthropic/claude-opus-5.5-20260101")
        XCTAssertEqual(m.intelligence, 61.4)
        XCTAssertEqual(m.coding, 77)
        XCTAssertEqual(m.agentic, 51)
    }

    func testEffortBenchmarks() throws {
        let json = #"""
        {"data":[
          {"permaslug":"a/s","aa_name":"Claude Sonnet 5.5 (Low, Default Fallback)","benchmark_data":{"evaluations":{"artificial_analysis_intelligence_index":35.9,"artificial_analysis_coding_index":40}}},
          {"permaslug":"a/s","aa_name":"Claude Sonnet 5.5 (Max, Default Fallback)","benchmark_data":{"evaluations":{"artificial_analysis_intelligence_index":56}}},
          {"permaslug":"a/h","aa_name":"Claude Haiku 5.5 (Non-reasoning)","benchmark_data":{"evaluations":{"artificial_analysis_intelligence_index":20.1}}},
          {"permaslug":"a/h","aa_name":"Claude Haiku 5.5 (Reasoning)","benchmark_data":{"evaluations":{"artificial_analysis_intelligence_index":30.2}}},
          {"permaslug":"a/o","aa_name":"Old Model (High)","benchmark_data":{"pricing":{}}},
          {"permaslug":"a/p","aa_name":"Plain Model","benchmark_data":{"evaluations":{"artificial_analysis_intelligence_index":12}}}
        ]}
        """#
        let rows = try JSONDecoder().decode(ModelList<AAEffortRow>.self, from: Data(json.utf8)).data
        XCTAssertEqual(rows.map(\.effort), ["low", "max", "none", nil, "high", nil])
        XCTAssertEqual(rows[0].intelligence, 35.9)
        XCTAssertEqual(rows[1].intelligence, 56)
        XCTAssertNil(rows[4].intelligence)
        // What the catalog keeps: rows with both an effort and a score.
        let kept = rows.filter { $0.effort != nil && $0.intelligence != nil }
        XCTAssertEqual(kept.map(\.aaName), ["Claude Sonnet 5.5 (Low, Default Fallback)", "Claude Sonnet 5.5 (Max, Default Fallback)", "Claude Haiku 5.5 (Non-reasoning)"])
    }

    func testImageResponse() throws {
        let json = #"{"created":1748372400,"data":[{"b64_json":"aGVsbG8=","media_type":"image/png"}],"usage":{"prompt_tokens":0,"completion_tokens":4175,"total_tokens":4175,"cost":0.04,"is_byok":false}}"#
        let r = try JSONDecoder().decode(ImageGenerationResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.data.first?.mediaType, "image/png")
        XCTAssertEqual(r.usage?.cost, 0.04)
    }

    func testImageModelsAndEndpoints() throws {
        let json = #"{"data":[{"id":"qwen/qwen-image-2.1-turbo","name":"Qwen: Qwen Image 2.1 Turbo","description":"d","created":1,"architecture":{"input_modalities":["text","image"],"output_modalities":["image"]},"supported_parameters":{"resolution":{"type":"enum","values":["1K","2K"]},"aspect_ratio":{"type":"enum","values":["1:1","16:9"]},"n":{"type":"range","min":1,"max":6},"input_references":{"type":"range","min":0,"max":4},"seed":{"type":"boolean"}},"supports_streaming":false,"endpoints":"/x"}]}"#
        let models = try JSONDecoder().decode(ModelList<ImageModelInfo>.self, from: Data(json.utf8)).data
        XCTAssertEqual(models.first?.aspectRatios, ["1:1", "16:9"])
        XCTAssertTrue(models.first?.supportsReferences ?? false)

        let ep = #"{"id":"bytedance-seed/seedream-4.5","endpoints":[{"provider_name":"Seed","pricing":[{"billable":"output_image","unit":"image","cost_usd":0.04},{"billable":"input_image","unit":"image","cost_usd":0}]}]}"#
        let e = try JSONDecoder().decode(ImageEndpoints.self, from: Data(ep.utf8))
        XCTAssertEqual(e.estimatedCostPerImage ?? 0, 0.04, accuracy: 0.0001)
    }

    func testVideo() throws {
        let job = #"{"id":"gen-vid-1","polling_url":"/api/v1/videos/gen-vid-1","status":"pending"}"#
        let j = try JSONDecoder().decode(VideoJob.self, from: Data(job.utf8))
        XCTAssertFalse(j.isTerminal)
        let done = #"{"id":"v","status":"completed","unsigned_urls":["https://openrouter.ai/api/v1/videos/abc/content?index=0"],"urls":["https://signed"],"expires_at":1,"usage":{"cost":0.25,"is_byok":false}}"#
        let d = try JSONDecoder().decode(VideoJob.self, from: Data(done.utf8))
        XCTAssertTrue(d.isTerminal)
        XCTAssertEqual(d.usage?.cost, 0.25)
        let failed = #"{"id":"v","status":"failed","error":"Content policy"}"#
        XCTAssertEqual(try JSONDecoder().decode(VideoJob.self, from: Data(failed.utf8)).error, "Content policy")

        let model = #"{"id":"google/veo-3.1","name":"Google: Veo 3.1","supported_durations":[4,6,8],"supported_resolutions":["720p","1080p","4K"],"supported_aspect_ratios":["16:9"],"supported_frame_images":["first_frame"],"generate_audio":true,"pricing_skus":{"duration_seconds_with_audio":"0.40","duration_seconds_with_audio_4k":"0.60","duration_seconds_without_audio":"0.20","duration_seconds_without_audio_4k":"0.40"}}"#
        let m = try JSONDecoder().decode(VideoModelInfo.self, from: Data(model.utf8))
        XCTAssertEqual(m.estimatedCost(seconds: 8, resolution: "1080p", audio: true) ?? 0, 3.2, accuracy: 0.001)
        XCTAssertEqual(m.estimatedCost(seconds: 8, resolution: "4K", audio: false) ?? 0, 3.2, accuracy: 0.001)

        let grok = #"{"id":"x-ai/grok-imagine-video-1.5-lite","name":"x","pricing_skus":{"cents_per_image_input":"1","cents_per_video_output_second_480p":"2","cents_per_video_output_second_720p":"3","cents_per_video_output_second_1080p":"14"}}"#
        let g = try JSONDecoder().decode(VideoModelInfo.self, from: Data(grok.utf8))
        XCTAssertEqual(g.estimatedCost(seconds: 10, resolution: "720p", audio: false) ?? 0, 0.3, accuracy: 0.001)
    }

    func testNonStreamingCompletion() throws {
        let json = #"{"id":"gen-1","model":"m","choices":[{"message":{"role":"assistant","content":"Hi","tool_calls":[{"id":"c","type":"function","function":{"name":"run_code","arguments":"{\"code\":\"1\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"cost":0.001}}"#
        let c = try JSONDecoder().decode(ChatCompletion.self, from: Data(json.utf8))
        XCTAssertEqual(c.choices?.first?.message?.toolCalls?.first?.name, "run_code")
        XCTAssertEqual(c.usage?.cost, 0.001)
    }
}
