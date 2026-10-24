import Foundation

/// What the share extension leaves for the app: text, a link and images someone shared into Halo.
/// The app picks it up next time it's opened and puts it in a new chat's message box.
struct SharedItem: Codable, Sendable {
    var id = UUID()
    var date = Date()
    var text: String?
    var url: String?
    var note: String?
    /// File names of JPEGs next to the entry, in order.
    var imageFiles: [String] = []
}

/// A folder per shared item in the App Group container: the images first, then `item.json`
/// (written last, so the app never reads half an entry).
enum ShareInbox {
    /// The App Group, from the Info.plist so it follows `APP_BUNDLE_ID`.
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "HaloAppGroup") as? String ?? "group.com.filipmanikowski.halo"
    }

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Halo's shared folder isn't available." }
    }

    static func write(_ item: SharedItem, images: [Data]) throws {
        guard let base = directory else { throw Unavailable() }
        let folder = base.appendingPathComponent(item.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entry = item
        entry.imageFiles = []
        for (i, data) in images.enumerated() {
            let name = "image-\(i).jpg"
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            entry.imageFiles.append(name)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
    }

    /// Complete entries, oldest first, with their folders.
    static func pending() -> [(item: SharedItem, folder: URL)] {
        guard let base = directory,
              let folders = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("item.json")),
                  let item = try? decoder.decode(SharedItem.self, from: data) else { return nil }
            return (item, folder)
        }
        .sorted { $0.item.date < $1.item.date }
    }

    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }
}
