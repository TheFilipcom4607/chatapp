import XCTest
@testable import Halo

final class MediaModelTests: XCTestCase {
    private func model(_ id: String, name: String? = nil, price: Double?, elo: Double? = nil, tier: Int = 0,
                       created: Double = 0, unavailable: String? = nil) -> MediaModelSummary {
        MediaModelSummary(id: id, name: name ?? id, lab: "Lab", created: created, price: price, priceUnit: "/image",
                          rating: elo.map { MediaRating(source: "Arena", board: "image", elo: $0, tier: tier) },
                          features: [], note: nil, unavailableReason: unavailable)
    }

    func testPicks() {
        var models = [
            model("top", price: 0.13, elo: 1355, created: 1),
            model("close", price: 0.025, elo: 1305, created: 2),
            model("far", price: 0.01, elo: 1100, created: 3),          // rated, but too far below the top
            model("cheap", price: 0.002, created: 4),
            model("new", price: 0.05, created: 9),
            model("refuses", price: 0.001, created: 10, unavailable: "Needs a reference image"),
        ]
        MediaPicks.rank(&models)
        XCTAssertEqual(models.compactMap(\.rating?.rank), [1, 2, 3])
        let picks = MediaPicks.compute(models)
        XCTAssertEqual(picks.map(\.role), [.best, .value, .cheapest, .newest])
        XCTAssertEqual(picks.map(\.id), ["top", "close", "cheap", "new"])
        XCTAssertEqual(picks[1].detail, "almost as good, 5× cheaper")   // $0.13 vs $0.025
    }

    func testPriceLabelForModelsWithoutAListedPrice() {
        var m = model("muse", price: nil)
        XCTAssertNil(m.priceLabel)                       // still loading
        m.priceUnlisted = true
        XCTAssertEqual(m.priceLabel, "No price listed")
        m = model("muse", price: 0.01)
        m.priceIsLearned = true
        XCTAssertEqual(m.priceLabel, "~$0.010/image")
        XCTAssertEqual(model("listed", price: 0.039).priceLabel, "$0.039/image")
    }

    func testLearnedPricesDoNotWinPicks() {
        var learned = model("muse", price: 0.001, elo: 1300, created: 1)
        learned.priceIsLearned = true
        var models = [model("top", price: 0.13, elo: 1355, created: 2), learned, model("listed", price: 0.04, created: 3)]
        MediaPicks.rank(&models)
        let picks = MediaPicks.compute(models)
        // Muse is within the value window and cheapest, but its price is a single sample.
        XCTAssertEqual(picks.map(\.id), ["top", "listed"])
    }

    func testPicksListAModelOnce() {
        var models = [model("only", price: 0.04, elo: 1200, created: 5)]
        MediaPicks.rank(&models)
        XCTAssertEqual(MediaPicks.compute(models).map(\.role), [.best])
    }

    func testSecondArenaRanksAfterTheFirst() {
        var models = [model("aa", price: 0.1, elo: 1400, tier: 1), model("da", price: 0.1, elo: 1200, tier: 0)]
        MediaPicks.rank(&models)
        XCTAssertEqual(models.first { $0.id == "da" }?.rating?.rank, 1)
        XCTAssertEqual(models.first { $0.id == "aa" }?.rating?.rank, 2)
    }

    func testOlderVersionsAreSuperseded() {
        let models = [
            model("r41", name: "Recraft V4.1 Pro Vector", price: 0.3, created: 2),
            model("r4", name: "Recraft V4 Pro Vector", price: 0.3, created: 1),
            model("r3", name: "Recraft V3", price: 0.04, elo: 869, created: 0),   // rated: stays
            model("r41plain", name: "Recraft V4.1", price: 0.04, created: 2),
            model("mai25", name: "MAI-Image-2.5", price: 0.04, created: 1),
            model("mai26", name: "MAI-Image-2.6", price: 0.04, created: 2),
            model("selected", name: "MAI-Image-2.4", price: 0.04, created: 0),
            // Released later, but a lower version: 3 Pro stays, 2.1 Pro goes.
            model("q3pro", name: "Qwen Image 3 Pro", price: 0.04, created: 1),
            model("q21pro", name: "Qwen Image 2.1 Pro", price: 0.046, created: 5),
            // Another shape of name, not an older version.
            model("gpt2", name: "GPT Image 2", price: 0.039, created: 3),
            model("gpt54", name: "GPT-5.4 Image 2", price: 0.039, created: 2),
        ]
        XCTAssertEqual(MediaPicks.superseded(models, keeping: "selected"), ["r4", "mai25", "q21pro"])
    }

    func testImageShortName() throws {
        func name(_ full: String) throws -> String {
            let json = #"{"id":"x","name":"\#(full)"}"#
            return try JSONDecoder().decode(ImageModelInfo.self, from: Data(json.utf8)).shortName
        }
        XCTAssertEqual(try name("Google: Nano Banana 2 (Gemini 3.1 Flash Image)"), "Nano Banana 2")
        XCTAssertEqual(try name("Google: Nano Banana 2 (Gemini 3.1 Flash Image Preview)"), "Nano Banana 2 Preview")
        XCTAssertEqual(try name("Krea: K3 Edit"), "K3 Edit")
    }

    func testVideoTokenPricing() {
        let json = #"{"id":"bytedance/seedance-2.0","name":"ByteDance: Seedance 2.0","pricing_skus":{"video_tokens":"0.000007","video_tokens_without_audio":"0.000007"}}"#
        let m = try! JSONDecoder().decode(VideoModelInfo.self, from: Data(json.utf8))
        // 1280 × 720 × 24 / 1024 = 21,600 tokens a second.
        XCTAssertEqual(m.estimatedCost(seconds: 5, resolution: "720p", audio: false) ?? 0, 0.000007 * 21_600 * 5, accuracy: 1e-9)
    }

    func testSpeechFormatFromError() {
        XCTAssertEqual(SpeechRequest.requiredFormat(in: #"Gemini TTS only supports response_format="pcm". Got "mp3"."#), "pcm")
        XCTAssertNil(SpeechRequest.requiredFormat(in: "Rate limited"))
    }

    func testWAVHeader() {
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let wav = WAV.wrap(pcm: pcm, sampleRate: 24_000)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        XCTAssertEqual(u32(4), UInt32(36 + pcm.count))
        XCTAssertEqual(u32(24), 24_000)            // sample rate
        XCTAssertEqual(u32(28), 48_000)            // byte rate: 24 kHz × 2 bytes, mono
        XCTAssertEqual(u32(40), UInt32(pcm.count)) // data size
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
        XCTAssertEqual(WAV.sampleRate(contentType: "audio/pcm;rate=16000"), 16_000)
        XCTAssertEqual(WAV.sampleRate(contentType: "audio/pcm"), 24_000)
    }

    func testWaveformLevels() {
        let samples: [Float] = Array(repeating: 0.5, count: 100) + Array(repeating: 0, count: 100) + Array(repeating: 0.25, count: 100)
        let levels = samples.withUnsafeBufferPointer { Waveform.levels($0, count: 3) }
        XCTAssertEqual(levels[0], 1, accuracy: 0.001)
        XCTAssertEqual(levels[1], 0, accuracy: 0.001)
        XCTAssertEqual(levels[2], pow(0.5, 0.6), accuracy: 0.001)
    }

    func testImageModelKnobs() throws {
        let json = #"{"id":"openai/gpt-image-2.5-sunburst","name":"OpenAI: GPT Image 2.5 Sunburst","supports_streaming":true,"supported_parameters":{"quality":{"type":"enum","values":["auto","low","medium","high","xhigh","max"]},"background":{"type":"enum","values":["auto","transparent","opaque"]}}}"#
        let info = try JSONDecoder().decode(ImageModelInfo.self, from: Data(json.utf8))
        XCTAssertTrue(info.streams)
        XCTAssertTrue(info.supportsTransparency)
        XCTAssertEqual(ImageQuality.defaultValue(for: info), "auto")
        XCTAssertEqual(ImageQuality.label("xhigh"), "Extra high")

        let grok = #"{"id":"x-ai/grok","name":"Grok","supported_parameters":{"quality":{"type":"enum","values":["low","medium"]},"background":{"type":"enum","values":["auto","opaque"]}}}"#
        let g = try JSONDecoder().decode(ImageModelInfo.self, from: Data(grok.utf8))
        XCTAssertFalse(g.streams)
        XCTAssertFalse(g.supportsTransparency)
        XCTAssertEqual(ImageQuality.defaultValue(for: g), "medium")
    }

    func testImageQualityCost() {
        XCTAssertEqual(ImageQuality.costFactor("auto", base: "high").factor, 1)
        XCTAssertEqual(ImageQuality.costFactor("high", base: "high").factor, 1)
        XCTAssertEqual(ImageQuality.costFactor("low", base: "high").factor, 272.0 / 4160, accuracy: 0.001)
        XCTAssertEqual(ImageQuality.costFactor("high", base: "medium").factor, 4160.0 / 1056, accuracy: 0.001)
        XCTAssertTrue(ImageQuality.costFactor("max", base: "high").atLeast)
    }

    func testImageStreamEvents() throws {
        let partial = #"{"type":"image_generation.partial_image","partial_image_index":0,"b64_json":"AAAA"}"#
        let p = try JSONDecoder().decode(ImageStreamEvent.self, from: Data(partial.utf8))
        XCTAssertEqual(p.type, "image_generation.partial_image")
        XCTAssertEqual(p.b64JSON, "AAAA")
        let done = #"{"type":"image_generation.completed","b64_json":"BBBB","media_type":"image/png","created":1,"usage":{"cost":0.04}}"#
        let d = try JSONDecoder().decode(ImageStreamEvent.self, from: Data(done.utf8))
        XCTAssertEqual(d.mediaType, "image/png")
        XCTAssertEqual(d.usage?.cost, 0.04)
        let err = #"{"type":"error","error":{"message":"Generation failed","code":"server_error"}}"#
        XCTAssertEqual(try JSONDecoder().decode(ImageStreamEvent.self, from: Data(err.utf8)).error?.message, "Generation failed")
    }

    func testImageRequestEncodesKnobs() throws {
        let req = ImageGenerationRequest(model: "m", prompt: "p", quality: "high", background: "transparent", stream: true)
        let obj = try JSONSerialization.jsonObject(with: OpenRouterClient.encoder.encode(req)) as? [String: Any]
        XCTAssertEqual(obj?["quality"] as? String, "high")
        XCTAssertEqual(obj?["background"] as? String, "transparent")
        XCTAssertEqual(obj?["stream"] as? Bool, true)
        let plain = try JSONSerialization.jsonObject(with: OpenRouterClient.encoder.encode(ImageGenerationRequest(model: "m", prompt: "p"))) as? [String: Any]
        XCTAssertNil(plain?["quality"])
        XCTAssertNil(plain?["stream"])
    }

    func testMediaArenaFeedDecodesThePublishedFile() throws {
        // As tools/media-arena/build.py writes it.
        let json = #"""
        {"boards": {"image-editing": {"openai/gpt-image-2": {"aa": "GPT Image 2 (high)", "elo": 1136, "via": "base name"}},
                    "text-to-image": {"openai/gpt-image-2.5-sunburst": {"aa": "GPT Image 2.5 Sunburst", "elo": 1222.5, "via": "name"}}},
         "source": "Artificial Analysis", "source_url": "https://artificialanalysis.ai",
         "unmatched": {"text-to-image": [{"elo": 1250, "id": "x", "name": "Riverflow 2.0"}]},
         "updated_at": "2026-10-24T05:23:00Z"}
        """#
        let feed = try MediaArenaFeed.decode(Data(json.utf8))
        XCTAssertEqual(feed.elo(.textToImage, "openai/gpt-image-2.5-sunburst"), 1222.5)
        XCTAssertEqual(feed.elo(.imageEditing, "openai/gpt-image-2"), 1136)   // "image editing" is "image-editing" in the API
        XCTAssertNil(feed.elo(.textToVideo, "google/veo-3.1"))
        XCTAssertEqual(feed.updatedAt, Date(timeIntervalSince1970: 1_792_819_380))
        // The app caches it with a plain encoder.
        XCTAssertEqual(try JSONDecoder().decode(MediaArenaFeed.self, from: JSONEncoder().encode(feed)), feed)
    }

    func testAlternatives() {
        var models = [
            model("mine", price: 0.10, elo: 1200),
            model("better", price: 0.105, elo: 1260),         // +60 Elo for about the price
            model("pricier", price: 0.30, elo: 1300),         // better, but 3× the price
            model("cheaper", price: 0.02, elo: 1190),         // about as good, 5× cheaper
            model("cheapest-but-worse", price: 0.001, elo: 1100),
            model("other-scale", price: 0.001, elo: 1250, tier: 1),
            model("refuses", price: 0.001, elo: 1250, unavailable: "Needs a reference image"),
        ]
        MediaPicks.rank(&models)
        let alts = MediaPicks.alternatives(to: models[0], among: models)
        XCTAssertEqual(alts.map(\.kind), [.better, .cheaper])
        XCTAssertEqual(alts.map(\.id), ["better", "cheaper"])
        XCTAssertEqual(alts[0].detail, "+60 Elo, similar price")
        XCTAssertEqual(alts[1].detail, "−10 Elo, 5× cheaper")
        // Nothing to compare an unrated or unpriced model with.
        XCTAssertEqual(MediaPicks.alternatives(to: model("unrated", price: 0.1), among: models), [])
        XCTAssertEqual(MediaPicks.alternatives(to: model("unpriced", price: nil, elo: 1200), among: models), [])
    }

    func testVideoDurations() {
        XCTAssertEqual(MediaModelDetailView.durations([4, 5, 6, 7, 8]), "4–8 s")
        XCTAssertEqual(MediaModelDetailView.durations([10, 5]), "5, 10 s")
        XCTAssertEqual(MediaModelDetailView.durations([4, 6, 8]), "4, 6, 8 s")
        XCTAssertEqual(MediaModelDetailView.durations([]), "")
    }

    func testDesignArenaGroups() {
        let scores = [
            ORModel.ArenaScore(arena: "agents", category: "spreadsheet", elo: 1283, winRate: 51.2, rank: 6),
            ORModel.ArenaScore(arena: "models", category: "website", elo: 1307, winRate: 55.8, rank: 13),
            ORModel.ArenaScore(arena: "models", category: "3d", elo: 1347, winRate: 42.7, rank: 9),
            ORModel.ArenaScore(arena: "models", category: "codecategories", elo: 1294, winRate: 48.6, rank: 17),
        ]
        let groups = DesignArena.groups(scores)
        XCTAssertEqual(groups.map(\.title), ["Models arena", "Agents arena"])
        // The all-coding score first, then the highest Elo.
        XCTAssertEqual(groups[0].scores.map(\.category), ["codecategories", "3d", "website"])
        // One arena needs no title.
        XCTAssertEqual(DesignArena.groups(Array(scores.dropFirst())).map(\.title), [nil])
        XCTAssertEqual(DesignArena.name("gamedev"), "Game development")
        XCTAssertEqual(DesignArena.name("new-category"), "New category")
        XCTAssertEqual(DesignArena.caption(scores[1]), "56% won · #13")
        XCTAssertNil(DesignArena.caption(ORModel.ArenaScore(category: "image", elo: 1200)))
    }

    func testArenaExploreDecodesOpenRoutersBenchmark() throws {
        // Trimmed from /api/frontend/v1/arena/explore/models/openai/gpt-image-2.5-sunburst-20260908?tab=image.
        let json = #"""
        {"data":{"pages":[
          {"challenge":{"kind":"challenge","modality":"image","slug":"full-glass","name":"Full wine glass","navLabel":"Full wine glass",
            "description":"Models default to a third full.","variantAxisName":"Subject","variants":[{"slug":"full-glass","name":"Full wine glass",
            "prompt":"A wine glass filled to the brim.","inputAssets":[],"cells":[{"model":{"permaslug":"openai/x","name":"X","author":"openai"},
            "provider":"OpenAI","asset":{"url":"https://model-assets.openrouter.ai/a.png","thumbnailUrl":"https://model-assets.openrouter.ai/a.webp",
            "mediaType":"image/png","width":1024,"height":1024},"costUsd":0.00615,"durationMs":12268,
            "score":{"checks":[{"label":"Filled to the brim","pass":true},{"label":"White wine","pass":false}],"judges":[]}}]}]}},
          {"challenge":{"kind":"challenge","slug":"punctuation","name":"Punctuation","variants":[
            {"slug":"a","name":"Statement","prompt":"Open till nine.","cells":[{"provider":null,"asset":{"url":"https://x/a.wav","mediaType":"audio/wav",
              "durationMs":2800,"voice":"george","transcript":"Open till nine.","peaks":[0.1,0.2]},"score":{"checks":[{"label":"Reads it","pass":true}]}}]},
            {"slug":"b","name":"Question","cells":[]}]}},
          {"challenge":{"kind":"style","slug":"portraits","name":"Portraits","variants":[{"slug":"p","name":"Headshot","cells":[]}]}},
          {"somethingNew":{}}
        ],
        "standing":{"rosterCount":59,"evalsRun":15,"gradedRun":15,"checksPassed":70,"checksTotal":81,"meanFidelity":0.86,
          "rankOnChecks":{"position":5,"of":55,"tied":false},"rankOnCost":null,"rankOnSpeed":{"position":33,"of":55},
          "challenges":{"full-glass":{"position":1,"of":59,"tied":true},"punctuation":null}}}}
        """#
        let explore = try JSONDecoder().decode(DataEnvelope<ArenaExplore>.self, from: Data(json.utf8)).data
        XCTAssertEqual(explore.challenges.map(\.slug), ["full-glass", "punctuation"])
        XCTAssertEqual(explore.showcases, [])                     // a style prompt with no result is left out
        let glass = explore.challenges[0]
        XCTAssertEqual(glass.tally.passed, 1)
        XCTAssertEqual(glass.tally.total, 2)
        XCTAssertEqual(glass.lead?.cell.asset?.previewURL?.absoluteString, "https://model-assets.openrouter.ai/a.webp")
        XCTAssertEqual(explore.rank(of: glass)?.position, 1)
        XCTAssertNil(explore.rank(of: explore.challenges[1]))
        XCTAssertEqual(explore.challenges[1].lead?.cell.asset?.isAudio, true)
        XCTAssertNil(explore.challenges[1].lead?.cell.asset?.previewURL)

        let stats = MediaBenchmarkSection.stats(try XCTUnwrap(explore.standing))
        XCTAssertEqual(stats.map(\.label), ["Checks passed", "Overall rank", "Speed rank"])
        XCTAssertEqual(stats.map(\.value), ["70 of 81", "5th", "33rd"])
        XCTAssertEqual(stats.map(\.detail), ["across 15 prompts", "of 55 on checks", "of 55, fastest first"])
    }

    func testOrdinals() {
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 33, 101, 111].map(ArenaExplore.ordinal),
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "33rd", "101st", "111th"])
    }
}
