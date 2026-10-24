import XCTest
import SwiftData
@testable import Halo

@MainActor
final class SearchOptionsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try ModelContainer(for: Conversation.self, Message.self, Persona.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    private func params(_ config: SearchConfig, model: String = "openai/gpt-6") -> [String: JSONValue] {
        guard case .object(let p) = config.toolParameters(modelID: model) else { XCTFail("not an object"); return [:] }
        return p
    }

    // MARK: Parameters

    func testDepthsSetResultsContextAndBudget() {
        let quick = params(SearchConfig(depth: .quick))
        XCTAssertEqual(quick["max_results"], 3)
        XCTAssertEqual(quick["search_context_size"], "low")
        XCTAssertEqual(SearchConfig(depth: .quick).maxToolCalls, 4)

        let standard = params(SearchConfig())
        XCTAssertEqual(standard["max_results"], 6)
        XCTAssertEqual(standard["search_context_size"], "medium")
        XCTAssertEqual(SearchConfig().maxToolCalls, 8)

        let deep = params(SearchConfig(depth: .deep))
        XCTAssertEqual(deep["max_results"], 10)
        XCTAssertEqual(deep["search_context_size"], "high")
        XCTAssertEqual(SearchConfig(depth: .deep).maxToolCalls, 16)
    }

    func testEngineAndModeGoOnlyWhenChosen() {
        let auto = params(SearchConfig(depth: .deep))
        XCTAssertNil(auto["engine"])
        XCTAssertNil(auto["mode"])

        let exa = params(SearchConfig(engine: .exa, depth: .deep))
        XCTAssertEqual(exa["engine"], "exa")
        XCTAssertEqual(exa["mode"], "deep")

        let parallel = params(SearchConfig(engine: .parallel, depth: .quick))
        XCTAssertEqual(parallel["mode"], "turbo")

        let perplexity = params(SearchConfig(engine: .perplexity))
        XCTAssertEqual(perplexity["engine"], "perplexity")
        XCTAssertNil(perplexity["mode"])
    }

    func testDomainFilterSendsOneList() {
        let only = params(SearchConfig(filter: .only, domains: ["arxiv.org"]))
        XCTAssertEqual(only["allowed_domains"], ["arxiv.org"])
        XCTAssertNil(only["excluded_domains"])

        let exclude = params(SearchConfig(filter: .exclude, domains: ["pinterest.com"]))
        XCTAssertEqual(exclude["excluded_domains"], ["pinterest.com"])
        XCTAssertNil(exclude["allowed_domains"])

        let off = params(SearchConfig(filter: .none, domains: ["pinterest.com"]))
        XCTAssertNil(off["allowed_domains"])
        XCTAssertNil(off["excluded_domains"])

        // Gemini's own search rejects filters; on Automatic OpenRouter switches to Exa, so the filter stays.
        let geminiNative = params(SearchConfig(engine: .native, filter: .exclude, domains: ["a.com"]), model: "google/gemini-4-argon")
        XCTAssertNil(geminiNative["excluded_domains"])
        let geminiAuto = params(SearchConfig(filter: .exclude, domains: ["a.com"]), model: "google/gemini-4-argon")
        XCTAssertEqual(geminiAuto["excluded_domains"], ["a.com"])
    }

    func testDomainsNormalize() {
        XCTAssertEqual(DomainFilterMode.normalize("  https://www.Reddit.com/r/swift "), "reddit.com")
        XCTAssertEqual(DomainFilterMode.normalize("en.wikipedia.org"), "en.wikipedia.org")
        XCTAssertNil(DomainFilterMode.normalize("reddit"))
        XCTAssertNil(DomainFilterMode.normalize(""))
    }

    // MARK: Cost

    func testCostPerSearch() throws {
        XCTAssertEqual(SearchConfig(engine: .exa, depth: .quick).estimatedCostPerSearch(model: nil)!, 0.007, accuracy: 1e-9)
        XCTAssertEqual(SearchConfig(engine: .exa, depth: .deep).estimatedCostPerSearch(model: nil)!, 0.012, accuracy: 1e-9)
        XCTAssertEqual(SearchConfig(engine: .parallel, depth: .quick).estimatedCostPerSearch(model: nil)!, 0.001, accuracy: 1e-9)
        XCTAssertEqual(SearchConfig(engine: .parallel, depth: .deep).estimatedCostPerSearch(model: nil)!, 0.005, accuracy: 1e-9)
        XCTAssertEqual(SearchConfig(engine: .perplexity).estimatedCostPerSearch(model: nil)!, 0.005, accuracy: 1e-9)
        // Firecrawl: $0.005 a search plus $0.0125 for each of 6 results.
        XCTAssertEqual(SearchConfig(engine: .firecrawl).estimatedCostPerSearch(model: nil)!, 0.08, accuracy: 1e-9)
        // Automatic on a model without its own search runs Exa's default mode, whatever the depth.
        XCTAssertEqual(SearchConfig(depth: .deep).estimatedCostPerSearch(model: nil)!, 0.007, accuracy: 1e-9)

        let json = #"{"id":"openai/gpt-6","name":"GPT-6","pricing":{"prompt":"0","completion":"0","web_search":"0.01"}}"#
        let native = try JSONDecoder().decode(ORModel.self, from: Data(json.utf8))
        XCTAssertEqual(SearchConfig().estimatedCostPerSearch(model: native)!, 0.01, accuracy: 1e-9)
        XCTAssertEqual(SearchConfig(engine: .exa).estimatedCostPerSearch(model: native)!, 0.007, accuracy: 1e-9)
    }

    func testPriceFormat() {
        XCTAssertEqual(SearchPrices.format(0.007), "$0.007")
        XCTAssertEqual(SearchPrices.format(0.08), "$0.08")
        XCTAssertEqual(SearchPrices.format(0.0675), "$0.068")
        XCTAssertEqual(SearchPrices.format(0.1), "$0.10")
    }

    // MARK: Storage and requests

    func testDepthAndEngineDefaultsAndRoundTrip() throws {
        let c = Conversation(modelID: "m")
        XCTAssertEqual(c.searchDepth, .standard)
        c.searchDepth = .deep
        XCTAssertEqual(c.searchDepthRaw, "deep")

        let p = Persona(name: "R", icon: "", colorHex: "", systemPrompt: "", modelID: nil, reasoningEffort: nil,
                        capabilities: [.search], alwaysSearch: false, isBuiltin: false, sortIndex: 0)
        XCTAssertNil(p.searchEngine)
        XCTAssertEqual(p.searchDepth, .standard)

        let reply = Message(role: .assistant)
        XCTAssertNil(reply.searchConfig)
        reply.searchConfig = SearchConfig(engine: .exa, depth: .deep, filter: .exclude, domains: ["a.com"])
        XCTAssertEqual(reply.searchConfig, SearchConfig(engine: .exa, depth: .deep, filter: .exclude, domains: ["a.com"]))
    }

    func testRequestUsesTheChatsDepthAndThePersonasEngine() throws {
        let persona = Persona(name: "R", icon: "", colorHex: "", systemPrompt: "", modelID: nil, reasoningEffort: nil,
                              capabilities: [.search], alwaysSearch: false, isBuiltin: false, sortIndex: 0)
        persona.searchEngine = .parallel
        context.insert(persona)
        let c = Conversation(modelID: "test/unknown-model", personaID: persona.id, searchMode: .auto, searchDepth: .deep)
        context.insert(c)
        let m = Message(role: .user, text: "Hi")
        c.append(m)
        context.insert(m)
        let builder = RequestBuilder(conversation: c, persona: persona, settings: AppSettings(),
                                     catalog: ModelCatalog(client: OpenRouterClient(keyProvider: { nil })),
                                     artifacts: [], includeTitleInstruction: false)
        let request = builder.build()
        let body = try XCTUnwrap(JSONValue.parse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self)))
        XCTAssertEqual(body["max_tool_calls"], 16)
        let search = body["tools"]?.arrayValue?.first { $0["type"]?.stringValue == "openrouter:web_search" }
        XCTAssertEqual(search?["parameters"]?["engine"], "parallel")
        XCTAssertEqual(search?["parameters"]?["mode"], "advanced")
        XCTAssertEqual(search?["parameters"]?["max_results"], 10)
    }
}
