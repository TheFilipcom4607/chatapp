import XCTest
import UIKit
@testable import Halo

final class FaviconTests: XCTestCase {
    func testLinkedIconsPreferTouchIconsAndSkipSVG() {
        let html = """
        <head>
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel="icon" sizes="16x16" href="/favicon-16.png">
        <link rel='apple-touch-icon' sizes='180x180' href='https://cdn.example.com/touch-180.png'>
        <link rel="apple-touch-icon" sizes="57x57" href="touch-57.png">
        <link rel="stylesheet" href="/site.css">
        <link rel="shortcut icon" href="/favicon.ico?v=2&amp;x=1">
        </head>
        """
        let urls = Favicon.declaredIcons(in: html, base: URL(string: "https://example.com/")!).map(\.absoluteString)
        XCTAssertEqual(urls, ["https://cdn.example.com/touch-180.png", "https://example.com/touch-57.png",
                              "https://example.com/favicon.ico?v=2&x=1", "https://example.com/favicon-16.png"])
    }

    func testBlankPlaceholdersAndLightLogos() throws {
        let size = CGSize(width: 32, height: 32)
        let clear = UIGraphicsImageRenderer(size: size).image { _ in }
        XCTAssertEqual(Favicon.look(clear)?.isBlank, true)

        let flat = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        XCTAssertEqual(Favicon.look(flat)?.isBlank, true)

        // A white logo on a clear background: shows, but needs the dark circle.
        let whiteLogo = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let look = try XCTUnwrap(Favicon.look(whiteLogo))
        XCTAssertFalse(look.isBlank)
        XCTAssertTrue(look.isLight)

        // A dark logo on white: shows, on the white circle.
        let darkOnWhite = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill(); ctx.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        XCTAssertEqual(Favicon.look(darkOnWhite)?.isBlank, false)
        XCTAssertEqual(Favicon.look(darkOnWhite)?.isLight, false)
    }
}
