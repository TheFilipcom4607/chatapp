import UIKit

/// Site icons for sources, fetched from the site itself (no icon service learns what you read).
/// Tries the touch icon, then favicon.ico, on the host and then its parent domain; misses are
/// remembered so a site without one isn't asked again this launch.
@MainActor
enum Favicon {
    struct Icon {
        let image: UIImage
        /// A white or very light logo on a clear background, which needs a dark circle behind it.
        let isLight: Bool
    }

    private static var cache: [String: Icon] = [:]
    private static var missing = Set<String>()
    private static var inFlight: [String: Task<Icon?, Never>] = [:]

    static func cached(_ host: String) -> Icon? { cache[host] }

    static func image(for host: String) async -> Icon? {
        if let image = cache[host] { return image }
        if missing.contains(host) { return nil }
        if let task = inFlight[host] { return await task.value }
        let task = Task<Icon?, Never> {
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

    private nonisolated static func fetch(_ url: URL) async -> Icon? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 1_000_000,
              let image = UIImage(data: data), image.size.width >= 16 else { return nil }
        let small = image.size.width > 96 ? image.preparingThumbnail(of: CGSize(width: 96, height: 96)) ?? image : image
        return Icon(image: small, isLight: isLight(small))
    }

    /// The average brightness of the icon's visible pixels, from an 8×8 copy.
    private nonisolated static func isLight(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var light = 0.0, alpha = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            // Premultiplied: the colour channels already carry the alpha.
            light += (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
            alpha += a
        }
        // An opaque icon brings its own background; only a mostly see-through one can vanish.
        guard alpha > 0, alpha < Double(side * side) * 0.9 else { return false }
        return light / alpha > 0.85
    }
}
