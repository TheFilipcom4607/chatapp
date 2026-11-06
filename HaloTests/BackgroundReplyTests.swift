import XCTest
@testable import Halo

/// The pieces that let a reply written on the background session be replayed and saved.
final class BackgroundReplyTests: XCTestCase {

    private let streamText = """
    : OPENROUTER PROCESSING

    data: {"id":"gen-1","model":"openai/gpt-5","provider":"OpenAI","choices":[{"index":0,"delta":{"reasoning":"Think"}}]}

    data: {"id":"gen-1","choices":[{"index":0,"delta":{"content":"<title>Hi there</title>Hel"}}]}

    data: {"id":"gen-1","choices":[{"index":0,"delta":{"content":"lo ✨"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13,"cost":0.01}}

    data: [DONE]

    """

    func testSplitterHoldsPartialLines() {
        var splitter = SSELineSplitter()
        XCTAssertEqual(splitter.feed(Data("data: a\ndata: b".utf8)), ["data: a"])
        XCTAssertEqual(splitter.feed(Data("c\r\n\n".utf8)), ["data: bc\r", ""])
        XCTAssertEqual(splitter.flush(), [])
        XCTAssertEqual(splitter.feed(Data("tail".utf8)), [])
        XCTAssertEqual(splitter.flush(), ["tail"])
    }

    func testSplitterKeepsMultibyteCharactersAcrossChunks() {
        let bytes = Array("data: ✨\n".utf8)
        var splitter = SSELineSplitter()
        var lines: [String] = []
        // One byte at a time, so the sparkle's three bytes arrive in separate pieces.
        for byte in bytes { lines += splitter.feed(Data([byte])) }
        XCTAssertEqual(lines, ["data: ✨"])
    }

    func testStepsDecodeChunksAndDone() throws {
        let decoder = JSONDecoder()
        if case .event(.keepAlive)? = try OpenRouterClient.chatStreamStep(": OPENROUTER PROCESSING", decoder: decoder) {} else { XCTFail("comment") }
        if case .done? = try OpenRouterClient.chatStreamStep("data: [DONE]", decoder: decoder) {} else { XCTFail("done") }
        XCTAssertNil(try OpenRouterClient.chatStreamStep("", decoder: decoder))
        XCTAssertThrowsError(try OpenRouterClient.chatStreamStep(#"data: {"error":{"code":"server_error","message":"Provider disconnected"},"choices":[]}"#, decoder: decoder))
    }

    func testAccumulatorBuildsTheReplyFromReplayedLines() throws {
        var splitter = SSELineSplitter()
        let decoder = JSONDecoder()
        var reply = ChatEngine.ReplyAccumulator(titleEnabled: true)
        var shown = ""
        // Arbitrary chunk boundaries, as the daemon may hand data over.
        let data = Data(streamText.utf8)
        var lines: [String] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + 7, data.count)
            lines += splitter.feed(data.subdata(in: offset..<end))
            offset = end
        }
        lines += splitter.flush()
        loop: for line in lines {
            switch try OpenRouterClient.chatStreamStep(line, decoder: decoder) {
            case .event(let event): shown += reply.ingest(event).text
            case .done: break loop
            case nil: continue
            }
        }
        let (outcome, tail) = reply.finish()
        shown += tail
        XCTAssertEqual(outcome.text, "Hello ✨")
        XCTAssertEqual(shown, "Hello ✨")
        XCTAssertEqual(outcome.title, "Hi there")
        XCTAssertEqual(outcome.reasoning, "Think")
        XCTAssertEqual(outcome.generationID, "gen-1")
        XCTAssertEqual(outcome.provider, "OpenAI")
        XCTAssertEqual(outcome.finishReason, "stop")
        XCTAssertEqual(outcome.usage?.cost, 0.01)
        XCTAssertTrue(outcome.toolCalls.isEmpty)
    }

    func testAccumulatorCollectsToolCalls() throws {
        let decoder = JSONDecoder()
        var reply = ChatEngine.ReplyAccumulator(titleEnabled: false)
        let lines = [
            #"data: {"id":"g","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\"q"}}]}}]}"#,
            #"data: {"id":"g","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":\"x\"}"}}]},"finish_reason":"tool_calls"}]}"#,
        ]
        var sawTools = false
        for line in lines {
            if case .event(let event)? = try OpenRouterClient.chatStreamStep(line, decoder: decoder) {
                sawTools = reply.ingest(event).tools || sawTools
            }
        }
        XCTAssertTrue(sawTools)
        XCTAssertEqual(reply.lastToolName, "web_search")
        let outcome = reply.finish().outcome
        XCTAssertEqual(outcome.toolCalls.count, 1)
        XCTAssertEqual(outcome.toolCalls.first?.id, "call_1")
        XCTAssertEqual(outcome.toolCalls.first?.function.arguments, #"{"q":"x"}"#)
    }
}
