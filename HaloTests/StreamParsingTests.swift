import XCTest
@testable import Halo

final class StreamParsingTests: XCTestCase {

    func testSSELines() {
        XCTAssertEqual(SSEParser.parse(line: ": OPENROUTER PROCESSING"), .comment("OPENROUTER PROCESSING"))
        XCTAssertEqual(SSEParser.parse(line: "data: [DONE]"), .done)
        XCTAssertEqual(SSEParser.parse(line: "data: {\"a\":1}\r"), .data("{\"a\":1}"))
        XCTAssertEqual(SSEParser.parse(line: "data:{\"a\":1}"), .data("{\"a\":1}"))
        XCTAssertNil(SSEParser.parse(line: ""))
        XCTAssertNil(SSEParser.parse(line: "event: ping"))
    }

    func testDecodeContentChunk() throws {
        let json = #"{"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"openai/gpt-4o","provider":"OpenAI","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel","reasoning":null,"reasoning_details":[],"tool_calls":[]},"finish_reason":null,"native_finish_reason":null}]}"#
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: Data(json.utf8))
        XCTAssertEqual(chunk.id, "gen-1")
        XCTAssertEqual(chunk.provider, "OpenAI")
        XCTAssertEqual(chunk.choices?.first?.delta?.content, "Hel")
        XCTAssertNil(chunk.choices?.first?.finishReason)
    }

    func testDecodeUsageChunk() throws {
        let json = #"{"id":"gen-abc","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":"stop","native_finish_reason":"stop"}],"usage":{"prompt_tokens":194,"completion_tokens":2,"total_tokens":196,"prompt_tokens_details":{"cached_tokens":10,"cache_write_tokens":100,"audio_tokens":0,"video_tokens":0},"completion_tokens_details":{"reasoning_tokens":5,"audio_tokens":0,"image_tokens":0,"accepted_prediction_tokens":null},"cost":0.95,"is_byok":false,"cost_details":{"upstream_inference_cost":null},"server_tool_use_details":{"web_search_requests":2}}}"#
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: Data(json.utf8))
        XCTAssertEqual(chunk.usage?.cost, 0.95)
        XCTAssertEqual(chunk.usage?.promptTokens, 194)
        XCTAssertEqual(chunk.usage?.cachedTokens, 10)
        XCTAssertEqual(chunk.usage?.reasoningTokens, 5)
        XCTAssertEqual(chunk.usage?.webSearches, 2)
        XCTAssertEqual(chunk.choices?.first?.finishReason, "stop")
    }

    func testDecodeMidStreamError() throws {
        let json = #"{"id":"cmpl-abc123","object":"chat.completion.chunk","created":1,"model":"openai/gpt-4o","provider":"openai","error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: Data(json.utf8))
        XCTAssertEqual(chunk.error?.message, "Provider disconnected unexpectedly")
        XCTAssertEqual(chunk.error?.code?.value, "server_error")
        let json2 = #"{"error":{"code":402,"message":"Insufficient credits"}}"#
        let env = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(json2.utf8))
        XCTAssertEqual(env.error.code?.value, "402")
    }

    func testToolCallAccumulatorInterleaved() throws {
        var acc = ToolCallAccumulator()
        func d(_ s: String) throws -> ToolCallDelta { try JSONDecoder().decode(ToolCallDelta.self, from: Data(s.utf8)) }
        acc.add(try d(#"{"index":0,"id":"call_a","type":"function","function":{"name":"generate_image","arguments":""}}"#))
        acc.add(try d(#"{"index":1,"id":"call_b","type":"function","function":{"name":"run_code","arguments":"{\"lang"}}"#))
        acc.add(try d(#"{"index":0,"function":{"arguments":"{\"prompt\":\"a cat"}}"#))
        acc.add(try d(#"{"index":1,"function":{"arguments":"uage\":\"python\"}"}}"#))
        acc.add(try d(#"{"index":0,"function":{"arguments":"\"}"}}"#))
        let calls = acc.finalized()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].id, "call_a")
        XCTAssertEqual(calls[0].name, "generate_image")
        XCTAssertEqual(calls[0].argumentsJSON["prompt"]?.stringValue, "a cat")
        XCTAssertEqual(calls[1].argumentsJSON["language"]?.stringValue, "python")
    }

    func testToolCallAccumulatorRepeatedName() throws {
        var acc = ToolCallAccumulator()
        func d(_ s: String) throws -> ToolCallDelta { try JSONDecoder().decode(ToolCallDelta.self, from: Data(s.utf8)) }
        acc.add(try d(#"{"index":0,"id":"x","function":{"name":"run_code","arguments":"{}"}}"#))
        acc.add(try d(#"{"index":0,"function":{"name":"run_code"}}"#))
        XCTAssertEqual(acc.finalized().first?.name, "run_code")
    }

    func testPartialJSON() {
        let partial = ##"{"title":"My \"Doc\"","type":"markdown","content":"# Hello\nWor"##
        let fields = PartialJSON.stringFields(partial)
        XCTAssertEqual(fields["title"], "My \"Doc\"")
        XCTAssertEqual(fields["type"], "markdown")
        XCTAssertEqual(fields["content"], "# Hello\nWor")

        let withNested = #"{"edits":[{"find":"a","replace":"b"}],"count":3,"summary":"Fix é typo"}"#
        let f2 = PartialJSON.stringFields(withNested)
        XCTAssertEqual(f2["summary"], "Fix é typo")
        XCTAssertNil(f2["edits"])

        XCTAssertEqual(PartialJSON.stringFields(#"{"content":"abc\"#)["content"], "abc")
        XCTAssertEqual(PartialJSON.stringFields("").count, 0)
        XCTAssertEqual(PartialJSON.stringFields(#"{"emoji":"😀"}"#)["emoji"], "😀")
    }

    func testTitleExtractorAcrossChunks() {
        var t = TitleExtractor()
        var shown = ""
        for piece in ["  <ti", "tle>Paris", " trip ideas</t", "itle>\n\nHere are", " some ideas."] {
            shown += t.feed(piece)
        }
        shown += t.finish()
        XCTAssertEqual(t.title, "Paris trip ideas")
        XCTAssertEqual(shown, "Here are some ideas.")
    }

    func testTitleExtractorNoTitle() {
        var t = TitleExtractor()
        var shown = ""
        for piece in ["He", "llo there"] { shown += t.feed(piece) }
        shown += t.finish()
        XCTAssertNil(t.title)
        XCTAssertEqual(shown, "Hello there")
    }

    func testTitleExtractorShortReply() {
        var t = TitleExtractor()
        var shown = t.feed("<t")
        shown += t.finish()
        XCTAssertEqual(shown, "<t")
    }

    func testTitleFallback() {
        XCTAssertEqual(TitleExtractor.fallback(from: "\nhi"), "hi")
        XCTAssertEqual(TitleExtractor.fallback(from: ""), "New chat")
    }

    func testRequestEncoding() throws {
        var req = ChatRequest(model: "anthropic/claude-sonnet-5.5", messages: [
            .system("sys"),
            .user(parts: [.text("look", cacheControl: false), .imageURL("data:image/jpeg;base64,AAA", detail: "auto"),
                          .file(filename: "a.pdf", data: "data:application/pdf;base64,BBB")]),
            .assistant(nil, toolCalls: [ToolCall(id: "c1", function: .init(name: "run_code", arguments: "{}"))]),
            .tool(callID: "c1", content: "ok"),
        ])
        req.tools = [
            .function(name: "run_code", description: "Run", parameters: ["type": "object", "additionalProperties": false]),
            .server(type: "openrouter:web_search", parameters: ["max_results": 5]),
        ]
        req.reasoning = ReasoningConfig(effort: "high")
        req.cacheControl = ["type": "ephemeral"]
        req.sessionID = "s1"
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(JSONValue.parse(String(decoding: data, as: UTF8.self)))
        XCTAssertEqual(obj["model"]?.stringValue, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(obj["reasoning"]?["effort"]?.stringValue, "high")
        XCTAssertEqual(obj["session_id"]?.stringValue, "s1")
        XCTAssertEqual(obj["cache_control"]?["type"]?.stringValue, "ephemeral")
        XCTAssertEqual(obj["tools"]?[0]?["function"]?["parameters"]?["additionalProperties"]?.boolValue, false)
        XCTAssertEqual(obj["tools"]?[1]?["type"]?.stringValue, "openrouter:web_search")
        let user = obj["messages"]?[1]
        XCTAssertEqual(user?["content"]?[1]?["type"]?.stringValue, "image_url")
        XCTAssertEqual(user?["content"]?[2]?["file"]?["file_data"]?.stringValue, "data:application/pdf;base64,BBB")
        let assistant = obj["messages"]?[2]
        XCTAssertEqual(assistant?["content"], .null)
        XCTAssertEqual(assistant?["tool_calls"]?[0]?["function"]?["name"]?.stringValue, "run_code")
        XCTAssertEqual(obj["messages"]?[3]?["tool_call_id"]?.stringValue, "c1")
    }

    func testCitations() {
        let ann: [JSONValue] = [
            ["type": "url_citation", "url_citation": ["url": "https://www.example.com/a", "title": "Example", "content": "snip"]],
            ["type": "url_citation", "url_citation": ["url": "https://www.example.com/a", "title": "Dup"]],
            ["type": "file", "file": ["hash": "x"]],
        ]
        let c = Citation.from(annotations: ann)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.host, "example.com")
    }
}

final class ReasoningMergeTests: XCTestCase {
    func testMergesFragmentsByIndex() {
        var details: [JSONValue] = []
        ReasoningDetailsMerger.merge(&details, [["type": "reasoning.text", "text": "Let me ", "index": 0, "format": "anthropic-claude-v1", "signature": .null]])
        ReasoningDetailsMerger.merge(&details, [["type": "reasoning.text", "text": "think.", "index": 0]])
        ReasoningDetailsMerger.merge(&details, [["type": "reasoning.text", "text": "", "index": 0, "signature": "sig123"]])
        ReasoningDetailsMerger.merge(&details, [["type": "reasoning.encrypted", "data": "abc", "index": 1]])
        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(details[0]["text"]?.stringValue, "Let me think.")
        XCTAssertEqual(details[0]["signature"]?.stringValue, "sig123")
        XCTAssertEqual(details[0]["format"]?.stringValue, "anthropic-claude-v1")
        XCTAssertEqual(details[1]["data"]?.stringValue, "abc")
    }
}
