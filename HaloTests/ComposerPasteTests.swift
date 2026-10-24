import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Halo

final class ComposerPasteTests: XCTestCase {
    private let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testACopiedPhotoPastesAsAnImageEvenWithItsLink() throws {
        let pasteboard = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("halo-test-\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let png = try XCTUnwrap(photo.pngData())

        pasteboard.items = [[UTType.png.identifier: png]]
        XCTAssertEqual(PastingTextView.pastedImages(from: pasteboard)?.count, 1)

        // Copied from Safari or Messages: the image and its address.
        pasteboard.items = [[UTType.png.identifier: png, UTType.utf8PlainText.identifier: "https://example.com/bus.jpg"]]
        XCTAssertEqual(PastingTextView.pastedImages(from: pasteboard)?.count, 1)

        // Text that carries an image along is pasted as the text.
        pasteboard.items = [[UTType.png.identifier: png, UTType.utf8PlainText.identifier: "Look at this bus"]]
        XCTAssertNil(PastingTextView.pastedImages(from: pasteboard))

        pasteboard.items = [[UTType.utf8PlainText.identifier: "just words"]]
        XCTAssertNil(PastingTextView.pastedImages(from: pasteboard))
    }

    func testLinks() {
        XCTAssertTrue(PastingTextView.isLink(" https://example.com/a.png\n"))
        XCTAssertFalse(PastingTextView.isLink("see https://example.com"))
        XCTAssertFalse(PastingTextView.isLink("example"))
    }
}
