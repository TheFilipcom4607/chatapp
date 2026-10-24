import XCTest
import SwiftData
@testable import Halo

@MainActor
final class ChatPolishTests: XCTestCase {
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

    @discardableResult
    private func append(_ role: MessageRole, _ text: String, to c: Conversation, cost: Double = 0,
                        status: MessageStatus = .complete, tool: ToolStatus? = nil) -> Message {
        let m = Message(role: role, text: text, status: status)
        m.cost = cost
        if let tool { m.toolState = ToolState(name: "generate_image", arguments: "{}", status: tool) }
        c.append(m)
        context.insert(m)
        return m
    }

    // MARK: Search mode

    func testOlderChatsAndPersonasReadTheirSearchMode() {
        let on = Conversation(modelID: "m")
        on.webSearch = true
        XCTAssertEqual(on.searchMode, .auto)
        XCTAssertEqual(Conversation(modelID: "m").searchMode, .off)

        let researcher = Persona(name: "R", icon: "", colorHex: "", systemPrompt: "", modelID: nil, reasoningEffort: nil,
                                 capabilities: [.search], alwaysSearch: true, isBuiltin: true, sortIndex: 0)
        XCTAssertEqual(researcher.searchMode, .always)
        let halo = Persona(name: "H", icon: "", colorHex: "", systemPrompt: "", modelID: nil, reasoningEffort: nil,
                           capabilities: [.search], alwaysSearch: false, isBuiltin: true, sortIndex: 0)
        XCTAssertEqual(halo.searchMode, .auto)
    }

    func testSettingTheModeKeepsTheOldFlagInStep() {
        let c = Conversation(modelID: "m", searchMode: .always)
        XCTAssertTrue(c.webSearch)
        c.searchMode = .off
        XCTAssertFalse(c.webSearch)
        XCTAssertEqual(c.searchModeRaw, "off")
    }

    private func requestBody(_ mode: SearchMode) throws -> (body: String, system: String) {
        let c = Conversation(modelID: "test/unknown-model", searchMode: mode)
        context.insert(c)
        append(.user, "Hi", to: c)
        let builder = RequestBuilder(conversation: c, persona: nil, settings: AppSettings(),
                                     catalog: ModelCatalog(client: OpenRouterClient(keyProvider: { nil })),
                                     artifacts: [], includeTitleInstruction: false)
        let request = builder.build()
        let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        return (body, builder.systemPrompt(toolsSupported: true))
    }

    func testSearchModesShapeTheRequest() throws {
        let off = try requestBody(.off)
        XCTAssertFalse(off.body.contains("openrouter:web_search"))
        XCTAssertTrue(off.system.contains("Web search is off"))

        let auto = try requestBody(.auto)
        XCTAssertTrue(auto.body.contains("openrouter:web_search"))
        XCTAssertFalse(auto.system.contains("before answering each message"))

        let always = try requestBody(.always)
        XCTAssertTrue(always.body.contains("openrouter:web_search"))
        XCTAssertTrue(always.system.contains("Search the web before answering each message."))
    }

    // MARK: Turn footer

    func testTurnFooterSitsAfterTheLastMessageWithTheTurnTotal() {
        let c = Conversation(modelID: "m")
        context.insert(c)
        append(.user, "Draw a fox", to: c)
        let reply = append(.assistant, "Here it is", to: c, cost: 0.01)
        let image = append(.tool, "Generated", to: c, cost: 0.04, tool: .done)
        let summaries = TurnSummary.byLastMessage(c.orderedMessages)
        XCTAssertNil(summaries[reply.id])
        let turn = try! XCTUnwrap(summaries[image.id])
        XCTAssertEqual(turn.cost, 0.05, accuracy: 1e-9)
        XCTAssertEqual(turn.head.id, reply.id)
        XCTAssertTrue(turn.hasFooter)
    }

    func testTurnEndingOnToolsStillGetsAFooterButNotWhilePending() {
        let c = Conversation(modelID: "m")
        context.insert(c)
        append(.user, "q", to: c)
        append(.assistant, "First", to: c)
        append(.tool, "ran", to: c, tool: .done)
        let closing = append(.assistant, "", to: c)
        var turn = try! XCTUnwrap(TurnSummary.byLastMessage(c.orderedMessages)[closing.id])
        XCTAssertTrue(turn.hasFooter)
        XCTAssertEqual(turn.text, "First")

        append(.user, "again", to: c)
        append(.assistant, "Making it", to: c)
        let pending = append(.tool, "", to: c, tool: .awaitingApproval)
        turn = try! XCTUnwrap(TurnSummary.byLastMessage(c.orderedMessages)[pending.id])
        XCTAssertFalse(turn.hasFooter)
    }

    func testATurnsSourcesShowOnceUnderItsLastReply() {
        func cite(_ urls: String...) -> [JSONValue] {
            urls.map { url -> JSONValue in ["type": "url_citation", "url_citation": ["url": .string(url), "title": "t"]] }
        }
        let c = Conversation(modelID: "m")
        context.insert(c)
        append(.user, "What bus is this?", to: c)
        let searching = append(.assistant, "", to: c)
        searching.annotations = cite("https://a.ee", "https://b.ee")
        append(.tool, "page", to: c, tool: .done)
        let answer = append(.assistant, "A Solaris Urbino", to: c)
        answer.annotations = cite("https://b.ee", "https://c.ee")
        let closing = append(.assistant, "", to: c)

        let sources = TurnSummary.sourcesByMessage(TurnSummary.byLastMessage(c.orderedMessages).values, liveID: nil)
        XCTAssertEqual(Array(sources.keys), [answer.id])
        XCTAssertEqual(sources[answer.id]?.map(\.url), ["https://a.ee", "https://b.ee", "https://c.ee"])

        // While the closing reply is streaming, the list waits under it.
        closing.status = .streaming
        XCTAssertEqual(Array(TurnSummary.sourcesByMessage(TurnSummary.byLastMessage(c.orderedMessages).values, liveID: closing.id).keys),
                       [closing.id])
    }

    // MARK: Read aloud text

    func testSpeechTextDropsMarkdown() {
        let md = """
        # Heading
        Some **bold** and *italic* text with `code` and a [link](https://example.com/page).

        ```python
        print("hi")
        ```

        - first item
        - [x] done item

        | A | B |
        |---|---|
        | 1 | 2 |

        $$
        E = mc^2
        $$
        See https://apple.com/iphone for more. snake_case stays.
        """
        let plain = SpeechText.plain(md)
        XCTAssertTrue(plain.hasPrefix("Heading\nSome bold and italic text with code and a link."))
        XCTAssertTrue(plain.contains("Code omitted."))
        XCTAssertFalse(plain.contains("print"))
        XCTAssertTrue(plain.contains("\nfirst item\ndone item"))
        XCTAssertTrue(plain.contains("A, B.\n1, 2."))
        XCTAssertTrue(plain.contains("Formula omitted."))
        XCTAssertFalse(plain.contains("mc^2"))
        XCTAssertTrue(plain.contains("See apple.com for more. snake_case stays."))
    }

    func testSpeechChunksSplitAtParagraphsThenSentences() {
        let para = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces) + "."
        let text = Array(repeating: para, count: 10).joined(separator: "\n\n")
        let chunks = SpeechText.chunks(text, limit: 400)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 400 })
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)

        let long = Array(repeating: "This is one sentence.", count: 50).joined(separator: " ")
        let split = SpeechText.chunks(long, limit: 100)
        XCTAssertTrue(split.allSatisfy { $0.count <= 100 && $0.hasSuffix(".") })
        XCTAssertEqual(split.joined(separator: " "), long)

        let unbroken = String(repeating: "a", count: 250)
        XCTAssertEqual(SpeechText.chunks(unbroken, limit: 100).map(\.count), [100, 100, 50])
    }
}
