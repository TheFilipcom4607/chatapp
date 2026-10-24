import Foundation

/// Readable text from a web page: scripts, styles and the site's menus, headers and footers go;
/// headings stay (as Markdown), and the page's main or article part is preferred when it has one.
enum HTMLText {
    nonisolated static func extract(_ html: String) -> (title: String?, text: String) {
        var s = html
        let title = firstGroup(#"<title[^>]*>([\s\S]*?)</title>"#, in: s).map { collapse(decode(stripTags($0))) }.flatMap { $0.isEmpty ? nil : $0 }
        s = replace(#"<!--[\s\S]*?-->"#, in: s, with: " ")
        for tag in ["head", "script", "style", "noscript", "svg", "template", "iframe"] {
            s = removeElements(tag, in: s)
        }
        // The page's own main content, when marked, keeps its header (that's where the headline is).
        if let main = firstGroup(#"<main\b[^>]*>([\s\S]*)</main>"#, in: s) ?? firstGroup(#"<article\b[^>]*>([\s\S]*?)</article>"#, in: s),
           collapse(stripTags(main)).count > 200 {
            s = main
            for tag in ["nav", "footer"] { s = removeElements(tag, in: s) }
        } else {
            for tag in ["nav", "header", "footer"] { s = removeElements(tag, in: s) }
        }
        s = replace(#"<h([1-6])\b[^>]*>([\s\S]*?)</h\1>"#, in: s) { groups in
            let level = Int(groups[1]) ?? 2
            let text = collapse(stripTags(groups[2]))
            return text.isEmpty ? "\n" : "\n\n" + String(repeating: "#", count: level) + " " + text + "\n\n"
        }
        s = replace(#"<li\b[^>]*>"#, in: s, with: "\n- ")
        s = replace(#"<br\s*/?>"#, in: s, with: "\n")
        s = replace(#"</t[dh]>"#, in: s, with: " ")
        s = replace(#"</?(p|div|section|article|main|aside|tr|table|ul|ol|dl|dd|dt|blockquote|pre|figure|figcaption|hr)\b[^>]*>"#, in: s, with: "\n")
        s = stripTags(s)
        s = decode(s)
        let lines = s.components(separatedBy: "\n").map { collapse($0) }
        var out: [String] = []
        for line in lines {
            if line.isEmpty {
                if out.last?.isEmpty == false { out.append("") }
            } else if line != "-" {
                out.append(line)
            }
        }
        return (title, out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One window of a long text, and where the next one starts (nil at the end).
    nonisolated static func page(_ text: String, start: Int, limit: Int = 20_000) -> (text: String, next: Int?) {
        let from = max(0, min(start, text.count))
        let begin = text.index(text.startIndex, offsetBy: from)
        let end = text.index(begin, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return (String(text[begin..<end]), end < text.endIndex ? from + limit : nil)
    }

    nonisolated static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        t = replace(#"&#[xX]([0-9a-fA-F]+);"#, in: t) { g in
            UInt32(g[1], radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        t = replace(#"&#([0-9]+);"#, in: t) { g in
            UInt32(g[1]).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        let named: [String: String] = [
            "nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "mdash": "—", "ndash": "–",
            "hellip": "…", "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®",
            "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "times": "×", "middot": "·", "bull": "•",
            "deg": "°", "laquo": "«", "raquo": "»", "shy": "", "zwj": "", "zwnj": "",
        ]
        t = replace(#"&([a-zA-Z]+);"#, in: t) { g in named[g[1]] ?? "&\(g[1]);" }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    nonisolated private static func stripTags(_ s: String) -> String { replace(#"<[^>]*>"#, in: s, with: "") }

    nonisolated private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\s ]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func removeElements(_ tag: String, in s: String) -> String {
        var t = replace("<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: s, with: "\n")
        t = replace("<\(tag)\\b[^>]*/>", in: t, with: "")
        return t
    }

    nonisolated private static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    nonisolated private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    nonisolated private static func replace(_ pattern: String, in s: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        var result = ""
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s) else { continue }
            result += s[last..<whole.lowerBound]
            let groups = (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
            result += transform(groups)
            last = whole.upperBound
        }
        result += s[last...]
        return result
    }
}

/// Open-Meteo's forecast response (current conditions, hourly and daily), as asked for in
/// `DeviceTools.getWeather`.
struct OpenMeteoForecast: Decodable, Sendable {
    struct Current: Decodable, Sendable {
        var time: String
        var temperature2m: Double
        var apparentTemperature: Double?
        var relativeHumidity2m: Double?
        var weatherCode: Int
        var windSpeed10m: Double?
        var precipitation: Double?

        enum CodingKeys: String, CodingKey {
            case time, precipitation
            case temperature2m = "temperature_2m", apparentTemperature = "apparent_temperature"
            case relativeHumidity2m = "relative_humidity_2m", weatherCode = "weather_code", windSpeed10m = "wind_speed_10m"
        }
    }
    struct Hourly: Decodable, Sendable {
        var time: [String]
        var temperature2m: [Double?]
        var precipitationProbability: [Int?]?
        var weatherCode: [Int?]

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m", precipitationProbability = "precipitation_probability", weatherCode = "weather_code"
        }
    }
    struct Daily: Decodable, Sendable {
        var time: [String]
        var weatherCode: [Int?]
        var temperature2mMax: [Double?]
        var temperature2mMin: [Double?]
        var precipitationProbabilityMax: [Int?]?
        var sunrise: [String]?
        var sunset: [String]?

        enum CodingKeys: String, CodingKey {
            case time, sunrise, sunset
            case weatherCode = "weather_code", temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }

    var timezone: String?
    var currentUnits: [String: String]?
    var current: Current
    var hourly: Hourly?
    var daily: Daily?

    enum CodingKeys: String, CodingKey {
        case timezone, current, hourly, daily
        case currentUnits = "current_units"
    }

    static func decode(_ data: Data) throws -> OpenMeteoForecast {
        try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
    }

    /// WMO weather codes as words and an SF Symbol.
    static func condition(_ code: Int) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("Clear", "sun.max")
        case 1: return ("Mostly clear", "sun.max")
        case 2: return ("Partly cloudy", "cloud.sun")
        case 3: return ("Overcast", "cloud")
        case 45, 48: return ("Fog", "cloud.fog")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle")
        case 56, 57: return ("Freezing drizzle", "cloud.sleet")
        case 61: return ("Light rain", "cloud.rain")
        case 63: return ("Rain", "cloud.rain")
        case 65: return ("Heavy rain", "cloud.heavyrain")
        case 66, 67: return ("Freezing rain", "cloud.sleet")
        case 71: return ("Light snow", "cloud.snow")
        case 73: return ("Snow", "cloud.snow")
        case 75: return ("Heavy snow", "cloud.snow")
        case 77: return ("Snow grains", "cloud.snow")
        case 80, 81: return ("Showers", "cloud.sun.rain")
        case 82: return ("Heavy showers", "cloud.heavyrain")
        case 85, 86: return ("Snow showers", "cloud.snow")
        case 95: return ("Thunderstorm", "cloud.bolt")
        case 96, 99: return ("Thunderstorm with hail", "cloud.bolt.rain")
        default: return ("Unknown", "cloud")
        }
    }

    private var tempUnit: String { currentUnits?["temperature_2m"] ?? "°C" }
    private var windUnit: String { currentUnits?["wind_speed_10m"] ?? "km/h" }

    private static func whole(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "?" }

    private static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = s.count > 10 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// "Sat 25 Oct" for a day; "15:00" for an hour (the API's own local times, so read as UTC).
    private static func label(_ s: String, format: String) -> String {
        guard let d = parse(s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: d)
    }

    /// The forecast for the model: now, every third hour of the next day, and the week.
    func summary(place: String) -> String {
        let now = Self.condition(current.weatherCode)
        var lines = ["Weather for \(place) (local time \(current.time.replacingOccurrences(of: "T", with: " ")), \(timezone ?? "local time zone")):"]
        var nowLine = "Now: \(Self.whole(current.temperature2m))\(tempUnit), \(now.text.lowercased())"
        if let feels = current.apparentTemperature { nowLine += ", feels like \(Self.whole(feels))\(tempUnit)" }
        if let h = current.relativeHumidity2m { nowLine += ", humidity \(Self.whole(h))%" }
        if let w = current.windSpeed10m { nowLine += ", wind \(Self.whole(w)) \(windUnit)" }
        if let p = current.precipitation, p > 0 { nowLine += ", precipitation \(p) mm" }
        lines.append(nowLine + ".")
        if let hourly, !hourly.time.isEmpty {
            let parts = stride(from: 0, to: hourly.time.count, by: 3).map { i -> String in
                let code = hourly.weatherCode[safe: i].flatMap { $0 }
                var part = "\(Self.label(hourly.time[i], format: "HH:mm")) \(Self.whole(hourly.temperature2m[safe: i] ?? nil))°"
                if let code { part += " " + Self.condition(code).text.lowercased() }
                if let p = hourly.precipitationProbability?[safe: i] ?? nil, p > 0 { part += " (\(p)% rain)" }
                return part
            }
            lines.append("Next 24 hours: " + parts.joined(separator: "; ") + ".")
        }
        if let daily {
            let parts = daily.time.indices.map { i -> String in
                var part = "\(Self.label(daily.time[i], format: "EEE d MMM")): \(Self.whole(daily.temperature2mMin[safe: i] ?? nil))–\(Self.whole(daily.temperature2mMax[safe: i] ?? nil))\(tempUnit)"
                if let code = daily.weatherCode[safe: i] ?? nil { part += ", " + Self.condition(code).text.lowercased() }
                if let p = daily.precipitationProbabilityMax?[safe: i] ?? nil, p > 0 { part += ", \(p)% rain" }
                return part
            }
            lines.append("7 days: " + parts.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Now and today's high and low up top, then a row per day.
    func card(place: String) -> ToolCard {
        let now = Self.condition(current.weatherCode)
        var subtitle = now.text
        if let hi = daily?.temperature2mMax.first ?? nil, let lo = daily?.temperature2mMin.first ?? nil {
            subtitle += " · H \(Self.whole(hi))° L \(Self.whole(lo))°"
        }
        let rows: [ToolCard.Row] = (daily?.time.indices).map { days in
            days.map { i in
                let code = daily?.weatherCode[safe: i] ?? nil
                return ToolCard.Row(title: i == 0 ? "Today" : Self.label(daily!.time[i], format: "EEE"),
                                    detail: code.map { Self.condition($0).text },
                                    trailing: "\(Self.whole(daily?.temperature2mMin[safe: i] ?? nil))° / \(Self.whole(daily?.temperature2mMax[safe: i] ?? nil))°",
                                    symbol: code.map { Self.condition($0).symbol })
            }
        } ?? []
        return ToolCard(symbol: now.symbol, title: place, subtitle: subtitle,
                        value: "\(Self.whole(current.temperature2m))°", rows: rows)
    }
}

/// Open-Meteo's place search.
struct OpenMeteoGeocoding: Decodable, Sendable {
    struct Place: Decodable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
        var country: String?
        var admin1: String?

        var label: String { [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ") }
    }
    var results: [Place]?
}

/// Dates the model writes: ISO 8601 with or without a zone, or a bare date (then `dateOnly`).
/// Times without a zone are the user's local time.
enum FlexibleDate {
    nonisolated static func parse(_ raw: String?, timeZone: TimeZone = .current) -> (date: Date, dateOnly: Bool)? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return (d, false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return (d, false) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return (d, false) }
        }
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: s) { return (d, true) }
        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
