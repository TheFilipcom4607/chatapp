import XCTest
@testable import Halo

final class ReliabilityTests: XCTestCase {

    func testDeadlineReturnsFinishedValue() async {
        let outcome = await Deadline.race(seconds: 5) { 42 }
        guard case .finished(let value) = outcome else { return XCTFail("expected .finished, got \(outcome)") }
        XCTAssertEqual(value, 42)
    }

    func testDeadlineTimesOutOnHungOperation() async {
        let outcome = await Deadline.race(seconds: 0.2) { () async -> Int in
            try? await Task.sleep(nanoseconds: 60_000_000_000)   // far past the deadline
            return 0
        }
        guard case .timedOut = outcome else { return XCTFail("expected .timedOut, got \(outcome)") }
    }

    func testDeadlineStopsWaitingWhenCancelled() async {
        let task = Task {
            await Deadline.race(seconds: 30) { () async -> Int in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return 0
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value
        guard case .cancelled = outcome else { return XCTFail("expected .cancelled, got \(outcome)") }
    }

    func testJavaScriptStillRuns() async {
        let result = await CodeRunner.run(language: "javascript", code: "console.log('hi'); 1 + 2")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.stdout, "hi")
        XCTAssertEqual(result.result, "3")
    }

    func testHugeNumbersDontTrap() {
        let v = JSONValue.parse(#"{"count": 1e300, "n": 3, "neg": -2.0}"#)
        XCTAssertNil(v?["count"]?.intValue)
        XCTAssertEqual(v?["n"]?.intValue, 3)
        XCTAssertEqual(v?["neg"]?.intValue, -2)
        XCTAssertEqual(v?["count"]?.stringValue, String(1e300))
        XCTAssertEqual(v?["n"]?.stringValue, "3")
    }
}
