import XCTest
@testable import Halo

final class ModelSpeedTests: XCTestCase {
    func testMedians() {
        let samples: [ModelSpeed.Sample] = [
            .init(modelID: "a", latency: 0.5, duration: 2.5, outputTokens: 100),   // 50 tok/s
            .init(modelID: "a", latency: 1.0, duration: 2.0, outputTokens: 100),   // 100 tok/s
            .init(modelID: "a", latency: 3.0, duration: 13.0, outputTokens: 100),  // 10 tok/s: a slow outlier
            .init(modelID: "a", latency: 0.1, duration: 0.2, outputTokens: 5),     // too short to time
            .init(modelID: "b", latency: 2.0, duration: 2.0, outputTokens: 50),    // no streaming time
        ]
        let speeds = ModelSpeed.medians(samples)
        let a = try! XCTUnwrap(speeds["a"])
        XCTAssertEqual(a.tokensPerSecond, 50, accuracy: 0.001)
        XCTAssertEqual(a.timeToFirstToken, 1.0, accuracy: 0.001)
        XCTAssertEqual(a.replies, 3)
        XCTAssertNil(speeds["b"])
        XCTAssertEqual(a.summary, "50 tok/s · 1.0s")
    }

    func testEvenCountMedian() {
        let speeds = ModelSpeed.medians([
            .init(modelID: "a", latency: 1, duration: 3, outputTokens: 100),  // 50 tok/s
            .init(modelID: "a", latency: 2, duration: 3, outputTokens: 100),  // 100 tok/s
        ])
        XCTAssertEqual(speeds["a"]?.tokensPerSecond ?? 0, 75, accuracy: 0.001)
        XCTAssertEqual(speeds["a"]?.timeToFirstToken ?? 0, 1.5, accuracy: 0.001)
    }

    func testThinkingIsLeftOutOfAReplysSpeed() {
        // Thought for 9s, then wrote 400 answer tokens in 2s: 200 tok/s, not 1,400 / 2.
        let m = Message(role: .assistant, text: "answer")
        m.reasoning = "thinking"
        m.latency = 9
        m.duration = 11
        m.usage = Usage(completionTokens: 1_400, completionTokensDetails: .init(reasoningTokens: 1_000))
        XCTAssertEqual(ModelSpeed.answerTokens(m), 400)
        XCTAssertEqual(ModelSpeed.tokensPerSecond(m) ?? 0, 200, accuracy: 0.001)

        // It thought but the provider didn't say for how long: no speed rather than a wrong one.
        m.usage = Usage(completionTokens: 1_400)
        XCTAssertNil(ModelSpeed.tokensPerSecond(m))

        // No thinking at all: every output token is the answer.
        m.reasoning = ""
        XCTAssertEqual(ModelSpeed.answerTokens(m), 1_400)
    }
}
