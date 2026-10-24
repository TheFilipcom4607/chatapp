import UIKit

/// Site icons for sources, fetched from the site itself (no icon service learns what you read).
/// Tries the touch icon, then the icons the home page links to, then favicon.ico, on the host and
/// then its parent domain. Blank placeholders don't count, and misses are remembered so a site
/// without one isn't asked again this launch.
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
            for h in hosts(host) {
                if let icon = await fetch(URL(string: "https://\(h)/apple-touch-icon.png")) { return icon }
                for url in await linkedIcons(h) {
                    if let icon = await fetch(url) { return icon }
                }
                if let icon = await fetch(URL(string: "https://\(h)/favicon.ico")) { return icon }
            }
            return nil
        }
        inFlight[host] = task
        let image = await task.value
        inFlight[host] = nil
        if let image { cache[host] = image } else { missing.insert(host) }
        return image
    }

    private static func hosts(_ host: String) -> [String] {
        var hosts = [host]
        let parts = host.split(separator: ".")
        if parts.count > 2 { hosts.append(parts.suffix(2).joined(separator: ".")) }
        return hosts
    }

    /// The icons the home page's `<link rel="…icon…">` tags point to, best first (the start of
    /// the page is enough: the tags sit in its head).
    private nonisolated static func linkedIcons(_ host: String) async -> [URL] {
        guard let base = URL(string: "https://\(host)/") else { return [] }
        var request = URLRequest(url: base, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 200_000 { break }
            }
        } catch { return [] }
        return declaredIcons(in: String(decoding: data, as: UTF8.self), base: response.url ?? base)
    }

    /// Touch icons before other icons, then the larger first (up to 256 px, beyond which it's
    /// just more to download). SVGs are left out: UIImage can't draw them.
    nonisolated static func declaredIcons(in html: String, base: URL) -> [URL] {
        let tag = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
        func attribute(_ name: String, in tag: String) -> String? {
            let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
            for i in 1...3 {
                if let r = Range(m.range(at: i), in: tag) { return String(tag[r]) }
            }
            return nil
        }
        var found: [(url: URL, score: Int)] = []
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(match.range, in: html) else { continue }
            let link = String(html[r])
            guard let rel = attribute("rel", in: link)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: link)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https", !url.path.lowercased().hasSuffix(".svg"),
                  attribute("type", in: link)?.lowercased().contains("svg") != true else { continue }
            let size = attribute("sizes", in: link)?.split(separator: "x").first.flatMap { Int($0) } ?? 32
            let fit = size <= 256 ? size : 256 - size / 16
            found.append((url, (rel.contains("apple-touch-icon") ? 1000 : 0) + fit))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    private nonisolated static func fetch(_ url: URL?) async -> Icon? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 1_000_000,
              let image = UIImage(data: data), image.size.width >= 16 else { return nil }
        let small = image.size.width > 96 ? image.preparingThumbnail(of: CGSize(width: 96, height: 96)) ?? image : image
        guard let appearance = look(small), !appearance.isBlank else { return nil }
        return Icon(image: small, isLight: appearance.isLight)
    }

    /// From a 16×16 copy: whether the icon shows anything (some sites serve a clear or one-colour
    /// placeholder), and whether its visible pixels are light on a see-through background.
    nonisolated static func look(_ image: UIImage) -> (isBlank: Bool, isLight: Bool)? {
        guard let cg = image.cgImage else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var light = 0.0, alpha = 0.0
        var lowest = 1.0, highest = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            // Premultiplied: the colour channels already carry the alpha.
            let l = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255
            light += l
            alpha += a
            // Brightness over a dark backdrop, so clear areas count as dark: shapes show up as range.
            lowest = min(lowest, l)
            highest = max(highest, l)
        }
        let count = Double(side * side)
        let isBlank = alpha < count * 0.03 || highest - lowest < 0.04
        // An opaque icon brings its own background; only a mostly see-through one can vanish.
        let isLight = alpha > 0 && alpha < count * 0.9 && light / alpha > 0.85
        return (isBlank, isLight)
    }
}
