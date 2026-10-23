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
}
