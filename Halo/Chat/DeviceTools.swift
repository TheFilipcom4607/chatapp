import Foundation
import CoreLocation
import EventKit
import MapKit
import UIKit

/// What a device or web tool hands back: the text the model reads, a short line for the chip,
/// and a card for the chat.
struct ToolOutcome {
    var ok = true
    var text: String
    var summary: String
    var card: ToolCard?

    static func failure(_ text: String, summary: String = "Failed") -> ToolOutcome {
        ToolOutcome(ok: false, text: text, summary: summary)
    }
}

/// The tools that reach past the chat: web pages, the iPhone itself, location, weather, Maps,
/// Calendar and Reminders, and links into other apps.
@MainActor
enum DeviceTools {
    // MARK: Web pages

    static let maxPageBytes = 4 * 1024 * 1024

    static func readWebPage(_ args: JSONValue) async -> ToolOutcome {
        var raw = (args["url"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http://") { raw = "https://" + raw.dropFirst(7) }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            return .failure("That isn't an https:// address: \(raw)", summary: "Bad address")
        }
        let start = max(0, args["start"]?.intValue ?? 0)
        do {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,application/json;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            if let status = http?.statusCode, !(200..<300).contains(status) {
                return .failure("The page answered HTTP \(status).", summary: "HTTP \(status)")
            }
            let mime = (response.mimeType ?? "text/html").lowercased()
            guard mime.hasPrefix("text/") || mime.contains("html") || mime.contains("json") || mime.contains("xml") else {
                return .failure("That link is \(mime), not a web page, so it can't be read as text.", summary: "Not a page")
            }
            var data = Data()
            var truncated = false
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxPageBytes { truncated = true; break }
            }
            let encoding = response.textEncodingName.map { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
            let body = encoding.flatMap { String(data: data, encoding: String.Encoding(rawValue: $0)) }
                ?? String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let isHTML = mime.contains("html")
            let extracted = isHTML ? await Task.detached(priority: .userInitiated) { HTMLText.extract(body) }.value : (title: nil, text: body)
            let host = (response.url ?? url).host ?? url.host ?? ""
            let title = extracted.title ?? host
            guard !extracted.text.isEmpty else {
                return .failure("The page had no readable text (it may need JavaScript).", summary: "No text")
            }
            let page = HTMLText.page(extracted.text, start: start)
            var text = "Page: \(title)\nURL: \((response.url ?? url).absoluteString)\n\n\(page.text)"
            if let next = page.next {
                text += "\n\n[\(extracted.text.count - next) more characters; call read_web_page with start=\(next) to read on.]"
            } else if truncated {
                text += "\n\n[The page was larger than 4 MB; only the start was read.]"
            }
            let count = extracted.text.count
            let size = count >= 1000 ? "\(count / 1000)k characters" : "\(count) characters"
            return ToolOutcome(text: text, summary: title,
                               card: ToolCard(symbol: "doc.text", title: title,
                                              subtitle: start > 0 ? "\(host) · from \(start)" : "\(host) · \(size)",
                                              buttonTitle: "Open in Safari", buttonURL: (response.url ?? url).absoluteString))
        } catch {
            return .failure("Couldn't load the page: \(error.localizedDescription)", summary: "Couldn't load")
        }
    }

    // MARK: Device

    static func deviceInfo() -> ToolOutcome {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        var rows: [ToolCard.Row] = []
        var lines: [String] = []
        func add(_ title: String, _ value: String, _ symbol: String) {
            rows.append(.init(title: title, trailing: value, symbol: symbol))
            lines.append("\(title): \(value)")
        }
        let level = device.batteryLevel
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "on battery"
        default: state = "unknown"
        }
        add("Battery", level >= 0 ? "\(Int((level * 100).rounded()))%, \(state)" : "Unknown (\(state))", "battery.75percent")
        add("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off", "bolt")
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let style = ByteCountFormatter()
            style.countStyle = .file
            let total = values.volumeTotalCapacity.map { " of \(style.string(fromByteCount: Int64($0)))" } ?? ""
            add("Free storage", style.string(fromByteCount: free) + total, "internaldrive")
        }
        add("iOS", device.systemVersion, "gear")
        add("Model", modelIdentifier, "iphone")
        add("Language", Locale.preferredLanguages.first ?? Locale.current.identifier, "character.bubble")
        add("Region", Locale.current.region?.identifier ?? "—", "globe")
        add("Time zone", TimeZone.current.identifier, "clock")
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm:ss zzz"
        f.locale = Locale(identifier: "en_GB")
        add("Local time", f.string(from: .now), "calendar")
        let battery = level >= 0 ? "\(Int((level * 100).rounded()))%" : "battery unknown"
        return ToolOutcome(text: "The user's iPhone:\n" + lines.joined(separator: "\n"), summary: "iPhone · \(battery)",
                           card: ToolCard(symbol: "iphone", title: "This iPhone", subtitle: "iOS \(device.systemVersion)", rows: rows))
    }

    private static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim + " (Simulator)" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Links into apps

    static func openInApp(_ args: JSONValue) -> ToolOutcome {
        let app = (args["app"]?.stringValue ?? "").lowercased()
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let given = args["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func encoded(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? s }
        let link: String
        let name: String
        switch app {
        case "maps":
            guard !query.isEmpty else { return .failure("Give a place or search for Maps.", summary: "Nothing to open") }
            link = "https://maps.apple.com/?q=\(encoded(query))"
            name = "Maps"
        case "safari":
            if let url = URL(string: given), url.scheme == "https" {
                link = url.absoluteString
            } else if !query.isEmpty {
                link = "x-web-search://?\(encoded(query))"
            } else {
                return .failure("Give an https:// URL or a search for Safari.", summary: "Nothing to open")
            }
            name = "Safari"
        case "music":
            guard !query.isEmpty else { return .failure("Give a song, artist or album to search for.", summary: "Nothing to open") }
            link = "https://music.apple.com/search?term=\(encoded(query))"
            name = "Music"
        case "shortcuts":
            guard !query.isEmpty else { return .failure("Give the shortcut's name.", summary: "Nothing to open") }
            link = "shortcuts://run-shortcut?name=\(encoded(query))"
            name = "Shortcuts"
        default:
            return .failure("Unknown app \(app). Use maps, safari, music or shortcuts.", summary: "Unknown app")
        }
        let symbol = ["Maps": "map", "Safari": "safari", "Music": "music.note", "Shortcuts": "square.2.layers.3d"][name] ?? "arrow.up.forward.app"
        return ToolOutcome(text: "A button to open \(name) (\(link)) is shown to the user; it opens when they tap it.",
                           summary: "Open in \(name)",
                           card: ToolCard(symbol: symbol, title: query.isEmpty ? given : query, subtitle: name,
                                          buttonTitle: app == "shortcuts" ? "Run in Shortcuts" : "Open in \(name)", buttonURL: link))
    }

    // MARK: Location

    static func getLocation(_ args: JSONValue) async -> ToolOutcome {
        let precise = args["precise"]?.boolValue == true
        do {
            let location = try await LocationProvider.shared.current()
            let place = await LocationProvider.describe(location, precise: precise)
            let c = location.coordinate
            let coords = precise ? String(format: "%.5f, %.5f", c.latitude, c.longitude) : String(format: "%.2f, %.2f", c.latitude, c.longitude)
            let accuracy = precise ? " (±\(Int(location.horizontalAccuracy)) m)" : " (rounded to about 1 km)"
            return ToolOutcome(text: "The user is in \(place.isEmpty ? "an unknown place" : place). Coordinates: \(coords)\(accuracy).",
                               summary: place.isEmpty ? "Location" : place,
                               card: ToolCard(symbol: "location.fill", title: place.isEmpty ? "Your location" : place, subtitle: coords,
                                              buttonTitle: "Open in Maps",
                                              buttonURL: "https://maps.apple.com/?ll=\(String(format: "%.4f,%.4f", c.latitude, c.longitude))"))
        } catch {
            return .failure(error.localizedDescription, summary: "No location")
        }
    }

    // MARK: Weather

    static func getWeather(_ args: JSONValue) async -> ToolOutcome {
        var latitude = args["latitude"]?.doubleValue
        var longitude = args["longitude"]?.doubleValue
        var placeLabel = args["place"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if latitude == nil || longitude == nil {
                if !placeLabel.isEmpty {
                    guard let found = try await geocode(placeLabel) else {
                        return .failure("Couldn't find a place called \(placeLabel).", summary: "Place not found")
                    }
                    latitude = found.latitude
                    longitude = found.longitude
                    placeLabel = found.label
                } else {
                    let location = try await LocationProvider.shared.current()
                    latitude = location.coordinate.latitude
                    longitude = location.coordinate.longitude
                    placeLabel = await LocationProvider.describe(location, precise: false)
                }
            }
            guard let latitude, let longitude else { return .failure("No place to forecast.", summary: "No place") }
            if placeLabel.isEmpty { placeLabel = String(format: "%.2f, %.2f", latitude, longitude) }
            var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            var items: [URLQueryItem] = [
                .init(name: "latitude", value: String(format: "%.4f", latitude)),
                .init(name: "longitude", value: String(format: "%.4f", longitude)),
                .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation"),
                .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
                .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
                .init(name: "timezone", value: "auto"),
                .init(name: "forecast_days", value: "7"),
                .init(name: "forecast_hours", value: "24"),
            ]
            if Locale.current.measurementSystem == .us {
                items += [.init(name: "temperature_unit", value: "fahrenheit"), .init(name: "wind_speed_unit", value: "mph")]
            }
            parts.queryItems = items
            let (data, response) = try await URLSession.shared.data(from: parts.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failure("The weather service didn't answer (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", summary: "No forecast")
            }
            let forecast = try OpenMeteoForecast.decode(data)
            let now = OpenMeteoForecast.condition(forecast.current.weatherCode)
            return ToolOutcome(text: forecast.summary(place: placeLabel),
                               summary: "\(Int(forecast.current.temperature2m.rounded()))° · \(now.text)",
                               card: forecast.card(place: placeLabel))
        } catch {
            return .failure("Couldn't get the weather: \(error.localizedDescription)", summary: "No forecast")
        }
    }

    /// A place name to coordinates. "Lisbon, Portugal" searches for Lisbon and prefers the result
    /// whose country or region matches the rest.
    private static func geocode(_ query: String) async throws -> OpenMeteoGeocoding.Place? {
        let pieces = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = pieces.first, !name.isEmpty else { return nil }
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "8"),
                            .init(name: "language", value: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"),
                            .init(name: "format", value: "json")]
        let (data, _) = try await URLSession.shared.data(from: parts.url!)
        let results = try JSONDecoder().decode(OpenMeteoGeocoding.self, from: data).results ?? []
        let rest = pieces.dropFirst().map { $0.lowercased() }
        if !rest.isEmpty, let match = results.first(where: { place in
            rest.allSatisfy { r in [place.country, place.admin1].compactMap { $0?.lowercased() }.contains { $0.contains(r) || r.contains($0) } }
        }) { return match }
        return results.first
    }

    // MARK: Maps

    static func searchPlaces(_ args: JSONValue) async -> ToolOutcome {
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return .failure("Say what to search for.", summary: "No search") }
        let near = args["near"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            var center: CLLocation?
            if !near.isEmpty {
                center = try await mapSearch(near, around: nil).first?.location
            } else {
                center = try? await LocationProvider.shared.current()
            }
            let items = Array(try await mapSearch(query, around: center?.coordinate).prefix(8))
            guard !items.isEmpty else {
                return .failure("Apple Maps found nothing for \(query)\(near.isEmpty ? "" : " near \(near)").", summary: "Nothing found")
            }
            var lines: [String] = []
            var rows: [ToolCard.Row] = []
            for item in items {
                let name = item.name ?? "Place"
                let address = Self.address(of: item)
                let distance = center.map { Self.distance(item.location.distance(from: $0)) }
                var line = "- \(name)"
                if !address.isEmpty { line += ", \(address)" }
                if let distance { line += " (\(distance) away)" }
                if let phone = item.phoneNumber { line += ", phone \(phone)" }
                if let url = item.url { line += ", \(url.absoluteString)" }
                lines.append(line)
                rows.append(.init(title: name, detail: address.isEmpty ? nil : address, trailing: distance, symbol: "mappin.and.ellipse",
                                  url: mapsLink(for: item)))
            }
            let around = near.isEmpty ? (center == nil ? "" : " near the user") : " near \(near)"
            return ToolOutcome(text: "Apple Maps results for \(query)\(around):\n" + lines.joined(separator: "\n"),
                               summary: "\(items.count) place\(items.count == 1 ? "" : "s")",
                               card: ToolCard(symbol: "map", title: query.capitalized(with: nil), subtitle: near.isEmpty ? "Nearby" : "Near \(near)",
                                              rows: rows, buttonTitle: "Open in Maps",
                                              buttonURL: "https://maps.apple.com/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
                                                + (center.map { String(format: "&sll=%.4f,%.4f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "")))
        } catch {
            return .failure("Maps search failed: \(error.localizedDescription)", summary: "Search failed")
        }
    }

    static func getDirections(_ args: JSONValue) async -> ToolOutcome {
        let to = args["to"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let from = args["from"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mode = (args["mode"]?.stringValue ?? "driving").lowercased()
        guard !to.isEmpty else { return .failure("Say where to go.", summary: "No destination") }
        do {
            let here: CLLocation? = from.isEmpty ? try await LocationProvider.shared.current() : nil
            let source: MKMapItem
            if from.isEmpty {
                source = MKMapItem.forCurrentLocation()
            } else if let found = try await mapSearch(from, around: nil).first {
                source = found
            } else {
                return .failure("Couldn't find \(from).", summary: "Start not found")
            }
            let anchor = here?.coordinate ?? (from.isEmpty ? nil : source.location.coordinate)
            guard let destination = try await mapSearch(to, around: anchor).first else {
                return .failure("Couldn't find \(to).", summary: "Not found")
            }
            let request = MKDirections.Request()
            request.source = source
            request.destination = destination
            request.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
            let eta = try await MKDirections(request: request).calculateETA()
            let minutes = Int((eta.expectedTravelTime / 60).rounded())
            let duration = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
            let arrival = eta.expectedArrivalDate.formatted(date: .omitted, time: .shortened)
            let how = mode == "walking" ? "on foot" : mode == "transit" ? "by public transport" : "by car"
            let name = destination.name ?? to
            let flag = mode == "walking" ? "w" : mode == "transit" ? "r" : "d"
            var link = "https://maps.apple.com/?dirflg=\(flag)"
            let d = destination.location.coordinate
            link += String(format: "&daddr=%.5f,%.5f", d.latitude, d.longitude)
            if !from.isEmpty {
                let c = source.location.coordinate
                link += String(format: "&saddr=%.5f,%.5f", c.latitude, c.longitude)
            }
            return ToolOutcome(text: "\(name) (\(Self.address(of: destination).isEmpty ? to : Self.address(of: destination))) is \(duration) \(how), \(distance(eta.distance)), from \(from.isEmpty ? "the user's location" : from). Leaving now arrives about \(arrival).",
                               summary: "\(duration) \(how)",
                               card: ToolCard(symbol: mode == "walking" ? "figure.walk" : mode == "transit" ? "tram" : "car",
                                              title: name, subtitle: "\(distance(eta.distance)) · arrive \(arrival)", value: duration,
                                              buttonTitle: "Directions in Maps", buttonURL: link))
        } catch {
            return .failure("Couldn't get directions: \(error.localizedDescription)", summary: "No route")
        }
    }

    private static func mapSearch(_ query: String, around center: CLLocationCoordinate2D?) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        do {
            return try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        }
    }

    private static func address(of item: MKMapItem) -> String {
        item.address?.shortAddress ?? item.address?.fullAddress ?? ""
    }

    private static func mapsLink(for item: MKMapItem) -> String? {
        let c = item.location.coordinate
        let name = (item.name ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return String(format: "https://maps.apple.com/?q=%@&ll=%.5f,%.5f", name, c.latitude, c.longitude)
    }

    private static func distance(_ meters: CLLocationDistance) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .road))
    }

    // MARK: Calendar and reminders

    static let eventStore = EKEventStore()

    private struct AccessDenied: LocalizedError {
        let what: String
        var errorDescription: String? { "Halo doesn't have access to your \(what). The user can allow it in the Settings app under Halo." }
    }

    private static func requestAccess(_ type: EKEntityType) async throws {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess { return }
        let granted = type == .event ? try await eventStore.requestFullAccessToEvents() : try await eventStore.requestFullAccessToReminders()
        guard granted else { throw AccessDenied(what: type == .event ? "calendar" : "reminders") }
    }

    /// Calendars (or reminder lists) that can take new items, once access is granted; empty before.
    static func writableLists(_ type: EKEntityType) -> [String] {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return [] }
        return eventStore.calendars(for: type).filter(\.allowsContentModifications).map(\.title)
    }

    static func listEvents(_ args: JSONValue) async -> ToolOutcome {
        let days = min(31, max(1, args["days"]?.intValue ?? 7))
        do {
            try await requestAccess(.event)
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = eventStore.events(matching: predicate)
                .filter { $0.endDate > .now }
                .sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else {
                return ToolOutcome(text: "No events in the next \(days) day\(days == 1 ? "" : "s").", summary: "No events",
                                   card: ToolCard(symbol: "calendar", title: "Nothing on", subtitle: "Next \(days) days"))
            }
            let shown = events.prefix(50)
            let lines = shown.map { e in
                var line = "- \(eventTime(e)): \(e.title ?? "Untitled") [\(e.calendar.title)]"
                if let loc = e.location, !loc.isEmpty { line += " at \(loc)" }
                return line
            }
            let rows = shown.prefix(12).map { e in
                ToolCard.Row(title: e.title ?? "Untitled", detail: eventTime(e), trailing: e.calendar.title, symbol: "calendar")
            }
            var text = "The user's events in the next \(days) days (local time):\n" + lines.joined(separator: "\n")
            if events.count > shown.count { text += "\n(\(events.count - shown.count) more not listed.)" }
            return ToolOutcome(text: text, summary: "\(events.count) event\(events.count == 1 ? "" : "s")",
                               card: ToolCard(symbol: "calendar", title: "\(events.count) event\(events.count == 1 ? "" : "s")",
                                              subtitle: "Next \(days) days", rows: Array(rows)))
        } catch {
            return .failure(error.localizedDescription, summary: "No access")
        }
    }

    static func listReminders() async -> ToolOutcome {
        do {
            try await requestAccess(.reminder)
            let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let items: [(title: String, list: String, due: Date?)] = await withCheckedContinuation { continuation in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    let mapped = (reminders ?? []).map { r in
                        (title: r.title ?? "Untitled", list: r.calendar.title, due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                    }
                    continuation.resume(returning: mapped)
                }
            }
            let sorted = items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            guard !sorted.isEmpty else {
                return ToolOutcome(text: "The user has no open reminders.", summary: "No reminders",
                                   card: ToolCard(symbol: "checklist", title: "All done", subtitle: "No open reminders"))
            }
            let shown = sorted.prefix(50)
            let lines = shown.map { r in "- \(r.title) [\(r.list)]" + (r.due.map { ", due \(dateTime($0))" } ?? "") }
            let rows = shown.prefix(12).map { r in
                ToolCard.Row(title: r.title, detail: r.due.map(dateTime), trailing: r.list, symbol: "circle")
            }
            return ToolOutcome(text: "The user's open reminders:\n" + lines.joined(separator: "\n"),
                               summary: "\(sorted.count) reminder\(sorted.count == 1 ? "" : "s")",
                               card: ToolCard(symbol: "checklist", title: "\(sorted.count) reminder\(sorted.count == 1 ? "" : "s")",
                                              subtitle: "Open", rows: Array(rows)))
        } catch {
            return .failure(error.localizedDescription, summary: "No access")
        }
    }

    /// The card's starting values from what the model asked for.
    static func eventParams(_ args: JSONValue, reminder: Bool) -> ApprovalParams {
        let title = args["title"]?.stringValue ?? ""
        var params = ApprovalParams(prompt: title, model: "")
        params.title = title
        params.notes = args["notes"]?.stringValue
        if reminder {
            params.start = FlexibleDate.parse(args["due"]?.stringValue)?.date
            params.listName = args["list"]?.stringValue
        } else {
            let start = FlexibleDate.parse(args["start"]?.stringValue)
            let allDay = args["all_day"]?.boolValue ?? start?.dateOnly ?? false
            let begin = start?.date ?? nextHour()
            params.start = begin
            params.end = FlexibleDate.parse(args["end"]?.stringValue)?.date
                ?? (allDay ? Calendar.current.date(byAdding: .day, value: 1, to: begin) : begin.addingTimeInterval(3600))
            params.allDay = allDay
            params.location = args["location"]?.stringValue
            params.listName = args["calendar"]?.stringValue
        }
        return params
    }

    static func saveEvent(_ params: ApprovalParams) async -> ToolOutcome {
        do {
            try await requestAccess(.event)
            let event = EKEvent(eventStore: eventStore)
            event.title = params.title ?? params.prompt
            let start = params.start ?? nextHour()
            event.startDate = start
            event.endDate = max(params.end ?? start.addingTimeInterval(3600), start)
            event.isAllDay = params.allDay == true
            if let loc = params.location, !loc.isEmpty { event.location = loc }
            if let notes = params.notes, !notes.isEmpty { event.notes = notes }
            event.calendar = writableCalendar(params.listName, type: .event) ?? eventStore.defaultCalendarForNewEvents
            try eventStore.save(event, span: .thisEvent)
            let when = event.isAllDay ? start.formatted(date: .complete, time: .omitted) : eventTime(event)
            return ToolOutcome(text: "Added \"\(event.title ?? "")\" to the calendar \(event.calendar.title): \(when).",
                               summary: "Added to Calendar",
                               card: ToolCard(symbol: "calendar.badge.checkmark", title: event.title ?? "Event",
                                              subtitle: "\(when) · \(event.calendar.title)", buttonTitle: "Open Calendar",
                                              buttonURL: "calshow:\(Int(start.timeIntervalSinceReferenceDate))"))
        } catch {
            return .failure("Couldn't add the event: \(error.localizedDescription)", summary: "Not added")
        }
    }

    static func saveReminder(_ params: ApprovalParams) async -> ToolOutcome {
        do {
            try await requestAccess(.reminder)
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = params.title ?? params.prompt
            if let notes = params.notes, !notes.isEmpty { reminder.notes = notes }
            if let due = params.start {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            guard let list = writableCalendar(params.listName, type: .reminder) ?? eventStore.defaultCalendarForNewReminders() else {
                return .failure("There's no reminder list to add to.", summary: "Not added")
            }
            reminder.calendar = list
            try eventStore.save(reminder, commit: true)
            let due = params.start.map { ", due \(dateTime($0))" } ?? ""
            return ToolOutcome(text: "Added the reminder \"\(reminder.title ?? "")\" to the list \(list.title)\(due).",
                               summary: "Added to Reminders",
                               card: ToolCard(symbol: "checklist", title: reminder.title ?? "Reminder",
                                              subtitle: list.title + (params.start.map { " · \(dateTime($0))" } ?? ""),
                                              buttonTitle: "Open Reminders", buttonURL: "x-apple-reminderkit://"))
        } catch {
            return .failure("Couldn't add the reminder: \(error.localizedDescription)", summary: "Not added")
        }
    }

    private static func writableCalendar(_ name: String?, type: EKEntityType) -> EKCalendar? {
        guard let name, !name.isEmpty else { return nil }
        return eventStore.calendars(for: type).first { $0.allowsContentModifications && $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func nextHour() -> Date {
        let now = Date()
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.end ?? now
        return hour
    }

    private static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private static func eventTime(_ e: EKEvent) -> String {
        if e.isAllDay { return e.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", all day" }
        let sameDay = Calendar.current.isDate(e.startDate, inSameDayAs: e.endDate)
        let end = sameDay ? e.endDate.formatted(date: .omitted, time: .shortened) : dateTime(e.endDate)
        return "\(dateTime(e.startDate))–\(end)"
    }
}

/// One location fix at a time, asking for permission the first time. A fix from the last two
/// minutes is reused.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var authWaiters: [CheckedContinuation<Void, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var lastFix: CLLocation?

    struct Denied: LocalizedError {
        var errorDescription: String? { "Halo isn't allowed to use the location. The user can allow it in the Settings app under Halo › Location." }
    }
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "The iPhone couldn't find its location in time." }
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authWaiters.append(continuation)
                if authWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: throw Denied()
        }
        if let lastFix, Date().timeIntervalSince(lastFix.timestamp) < 120 { return lastFix }
        return try await withCheckedThrowingContinuation { continuation in
            fixWaiters.append(continuation)
            guard fixWaiters.count == 1 else { return }
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.resolveFix(.failure(TimedOut()))
            }
        }
    }

    private func resolveFix(_ result: Result<CLLocation, Error>) {
        let waiters = fixWaiters
        fixWaiters = []
        if case .success(let location) = result { lastFix = location }
        waiters.forEach { $0.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authWaiters
            authWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let location = locations.last { resolveFix(.success(location)) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // "Unknown location" just means it's still looking.
            if (error as? CLError)?.code == .locationUnknown { return }
            resolveFix(.failure(error))
        }
    }

    /// "Kraków, Lesser Poland, Poland", with the street first when `precise`.
    static func describe(_ location: CLLocation, precise: Bool) async -> String {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return "" }
        let city = item.addressRepresentations?.cityWithContext ?? item.addressRepresentations?.cityName
        if precise, let street = item.address?.shortAddress ?? item.address?.fullAddress {
            return [street, city].compactMap { $0 }.joined(separator: ", ")
        }
        return city ?? item.address?.fullAddress ?? ""
    }
}
