import XCTest
@testable import Halo

final class MoneyTests: XCTestCase {
    func testPerMillionUsesTwoDecimalsEverywhere() {
        XCTAssertEqual(Money.perMillion(0.15), "$0.15")
        XCTAssertEqual(Money.perMillion(2), "$2.00")
        XCTAssertEqual(Money.perMillion(10), "$10.00")
        XCTAssertEqual(Money.perMillion(75), "$75.00")
    }

    func testPerMillionAbsorbsPerTokenFloatingPointError() {
        // $0.0000001 a token times a million is 0.09999999999999999, which used to print "$0.100".
        XCTAssertEqual(Money.perMillion(0.0000001 * 1_000_000), "$0.10")
        XCTAssertEqual(Money.perMillion(0.00000043 * 1_000_000), "$0.43")
    }

    func testPerMillionKeepsAThirdDecimalOnlyWhenNeeded() {
        XCTAssertEqual(Money.perMillion(0.075), "$0.075")
        XCTAssertEqual(Money.perMillion(0.0001), "<$0.001")
    }

    func testPerMillionFreeAndMissing() {
        XCTAssertEqual(Money.perMillion(0), "free")
        XCTAssertEqual(Money.perMillion(nil), "–")
    }
}

final class TokenFormatTests: XCTestCase {
    func testDropsTrailingZeroDecimal() {
        XCTAssertEqual(TokenFormat.short(1_000_000), "1M")
        XCTAssertEqual(TokenFormat.short(1_048_576), "1M")
        XCTAssertEqual(TokenFormat.short(2_500_000), "2.5M")
        XCTAssertEqual(TokenFormat.short(131_072), "131.1K")
        XCTAssertEqual(TokenFormat.short(128_000), "128K")
        XCTAssertEqual(TokenFormat.short(999), "999")
    }
}
