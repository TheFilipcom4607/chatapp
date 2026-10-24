import XCTest
@testable import Halo

final class ShareInboxTests: XCTestCase {
    func testEntriesRoundTripThroughTheAppGroup() throws {
        try XCTSkipIf(ShareInbox.directory == nil, "No App Group container in this build")
        let before = Set(ShareInbox.pending().map(\.item.id))
        let item = SharedItem(text: "Look at this", url: "https://www.apple.com/iphone/", note: "Is it worth it?")
        try ShareInbox.write(item, images: [Data([0xFF, 0xD8, 0xFF]), Data([0xFF, 0xD8])])

        let entry = try XCTUnwrap(ShareInbox.pending().first { $0.item.id == item.id })
        XCTAssertEqual(entry.item.text, "Look at this")
        XCTAssertEqual(entry.item.note, "Is it worth it?")
        XCTAssertEqual(entry.item.imageFiles, ["image-0.jpg", "image-1.jpg"])
        XCTAssertEqual(try Data(contentsOf: entry.folder.appendingPathComponent("image-1.jpg")), Data([0xFF, 0xD8]))

        ShareInbox.remove(entry.folder)
        XCTAssertEqual(Set(ShareInbox.pending().map(\.item.id)), before)
    }

    func testHalfWrittenEntriesAreIgnored() throws {
        let base = try XCTUnwrap(ShareInbox.directory, "No App Group container in this build")
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("image-0.jpg"))
        defer { ShareInbox.remove(folder) }
        XCTAssertFalse(ShareInbox.pending().contains { $0.folder.lastPathComponent == folder.lastPathComponent })
    }
}
