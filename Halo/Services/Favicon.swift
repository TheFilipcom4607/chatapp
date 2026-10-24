import UIKit

/// Site icons for sources, fetched from the site itself (no icon service learns what you read).
/// Tries the touch icon, then favicon.ico, on the host and then its parent domain; misses are
/// remembered so a site without one isn't asked again this launch.
@MainActor
enum Favicon {
    private static var cache: [String: UIImage] = [:]
    private static var missing = Set<String>()
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    static func cached(_ host: String) -> UIImage? { cache[host] }

    static func image(for host: String) async -> UIImage? {
        if let image = cache[host] { return image }
        if missing.contains(host) { return nil }
        if let task = inFlight[host] { return await task.value }
        let task = Task<UIImage?, Never> {
            for url in candidates(host) {
                if let image = await fetch(url) { return image }
            }
            return nil
        }
        inFlight[host] = task
        let image = await task.value
        inFlight[host] = nil
        if let image { cache[host] = image } else { missing.insert(host) }
        return image
    }

    private static func candidates(_ host: String) -> [URL] {
        var hosts = [host]
        let parts = host.split(separator: ".")
        if parts.count > 2 { hosts.append(parts.suffix(2).joined(separator: ".")) }
        return hosts.flatMap { h in
            ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: "https://\(h)/\($0)") }
        }
    }

    private nonisolated static func fetch(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 1_000_000,
              let image = UIImage(data: data), image.size.width >= 16 else { return nil }
        guard image.size.width > 96 else { return image }
        return image.preparingThumbnail(of: CGSize(width: 96, height: 96)) ?? image
    }
}
