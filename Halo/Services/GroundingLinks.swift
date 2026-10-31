import Foundation

/// Gemini's own search cites Google redirect links (vertexaisearch.cloud.google.com/grounding-api-redirect/…)
/// titled with nothing but the site's domain. These follow each link to the real page, so the sources
/// list shows the site's own icon, address and page title, and the link keeps working after Google's
/// redirect expires.
enum GroundingLinks {
    static let redirectHost = "vertexaisearch.cloud.google.com"

    static func isRedirect(_ url: String) -> Bool {
        URL(string: url)?.host == redirectHost
    }

    /// The annotations with every redirect swapped for the page it lands on, or nil when there were
    /// none (or none could be followed).
    static func resolve(_ annotations: [JSONValue]) async -> [JSONValue]? {
        let redirects = Set(annotations.compactMap { a in
            (a["url_citation"] ?? a["web_search_citation"] ?? a)["url"]?.stringValue
        }.filter(isRedirect))
        guard !redirects.isEmpty else { return nil }
        var targets: [String: (url: String, title: String?)] = [:]
        await withTaskGroup(of: (String, (url: String, title: String?)?).self) { group in
            for url in redirects { group.addTask { (url, await follow(url)) } }
            for await (url, landed) in group { if let landed { targets[url] = landed } }
        }
        guard !targets.isEmpty else { return nil }
        return annotations.map { a in
            guard case .object(var outer) = a else { return a }
            // The citation sits under "url_citation" (OpenRouter's shape) or is the annotation itself.
            let key = ["url_citation", "web_search_citation"].first { outer[$0] != nil }
            guard case .object(var b) = key.flatMap({ outer[$0] }) ?? a,
                  let url = b["url"]?.stringValue, let landed = targets[url] else { return a }
            b["url"] = .string(landed.url)
            if let title = landed.title { b["title"] = .string(title) }
            guard let key else { return .object(b) }
            outer[key] = .object(b)
            return .object(outer)
        }
    }

    /// Follows the redirect and reads the landing page's title from its first 256 KB. Sites that turn
    /// bots away still give their address; their title is left as it was.
    private static func follow(_ raw: String) async -> (url: String, title: String?)? {
        guard let url = URL(string: raw) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let landed = response.url, landed.host != redirectHost else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), (response.mimeType ?? "").contains("html") else { return (landed.absoluteString, nil) }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 256 * 1024 { break }
            }
        } catch {}
        let html = String(decoding: data, as: UTF8.self)
        guard let end = html.range(of: "</title>", options: .caseInsensitive) else { return (landed.absoluteString, nil) }
        let title = HTMLText.extract(String(html[..<end.upperBound])).title
        let blocked = ["just a moment", "access denied", "attention required", "403 forbidden", "are you a robot", "security check"]
        let usable = title.flatMap { t in blocked.contains { t.lowercased().contains($0) } ? nil : t }
        return (landed.absoluteString, usable)
    }
}
