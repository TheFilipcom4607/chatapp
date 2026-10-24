import XCTest
import SwiftData
@testable import Halo

@MainActor
final class DeviceToolsTests: XCTestCase {

    // MARK: Web pages

    func testHTMLKeepsTitleHeadingsAndMainText() {
        let html = """
        <html><head><title>Swift &amp; You</title><style>body{color:red}</style>
        <script>var x = "<p>not text</p>";</script></head>
        <body>
        <header><a href="/">Site logo</a></header>
        <nav><ul><li>Home</li><li>About</li></ul></nav>
        <h1>Concurrency&nbsp;guide</h1>
        <p>Actors keep state <b>safe</b> &mdash; one task at a time.</p>
        <!-- a comment -->
        <ul><li>First point</li><li>Second &#8220;point&#8221;</li></ul>
        <h2>Next   steps</h2><p>Read&nbsp;on&#x2026;</p>
        <footer>© 2026 Example</footer>
        </body></html>
        """
        let page = HTMLText.extract(html)
        XCTAssertEqual(page.title, "Swift & You")
        XCTAssertEqual(page.text, """
        # Concurrency guide

        Actors keep state safe — one task at a time.

        - First point
        - Second “point”

        ## Next steps

        Read on…
        """)
        XCTAssertFalse(page.text.contains("Site logo"))
        XCTAssertFalse(page.text.contains("not text"))
        XCTAssertFalse(page.text.contains("2026 Example"))
    }

    func testHTMLPrefersTheArticleAndKeepsItsHeadline() {
        let body = String(repeating: "Body text that is long enough to count as the article. ", count: 6)
        let html = """
        <body><header>Menu bar</header>
        <article><header><h1>The headline</h1></header><p>\(body)</p><footer>Share this</footer></article>
        <aside>Related links</aside></body>
        """
        let text = HTMLText.extract(html).text
        XCTAssertTrue(text.hasPrefix("# The headline"))
        XCTAssertFalse(text.contains("Menu bar"))
        XCTAssertFalse(text.contains("Share this"))
        XCTAssertFalse(text.contains("Related links"))
    }

    func testLongPagesComeInParts() {
        let text = String(repeating: "abcdefghij", count: 5)
        let first = HTMLText.page(text, start: 0, limit: 20)
        XCTAssertEqual(first.text.count, 20)
        XCTAssertEqual(first.next, 20)
        let last = HTMLText.page(text, start: 40, limit: 20)
        XCTAssertEqual(last.text, "abcdefghij")
        XCTAssertNil(last.next)
    }

    // MARK: Weather

    private let forecastJSON = """
    {"latitude":50.06,"longitude":19.94,"timezone":"Europe/Warsaw",
     "current_units":{"temperature_2m":"°C","wind_speed_10m":"km/h"},
     "current":{"time":"2026-10-24T14:00","temperature_2m":12.4,"apparent_temperature":10.2,"relative_humidity_2m":71,
                "weather_code":2,"wind_speed_10m":11.6,"precipitation":0.0},
     "hourly":{"time":["2026-10-24T14:00","2026-10-24T15:00","2026-10-24T16:00","2026-10-24T17:00"],
               "temperature_2m":[12.4,12.9,null,11.0],"precipitation_probability":[0,10,null,40],"weather_code":[2,3,null,61]},
     "daily":{"time":["2026-10-24","2026-10-25"],"weather_code":[2,63],"temperature_2m_max":[14.2,11.8],
              "temperature_2m_min":[7.6,6.1],"precipitation_probability_max":[10,80],
              "sunrise":["2026-10-24T06:31","2026-10-25T06:33"],"sunset":["2026-10-24T16:41","2026-10-25T16:39"]}}
    """

    func testOpenMeteoForecastDecodesAndReads() throws {
        let forecast = try OpenMeteoForecast.decode(Data(forecastJSON.utf8))
        XCTAssertEqual(forecast.current.weatherCode, 2)
        XCTAssertEqual(forecast.hourly?.temperature2m[2], nil)
        let summary = forecast.summary(place: "Kraków, Poland")
        XCTAssertTrue(summary.contains("Now: 12°C, partly cloudy, feels like 10°C, humidity 71%, wind 12 km/h."), summary)
        XCTAssertTrue(summary.contains("Next 24 hours: 14:00 12° partly cloudy; 17:00 11° light rain (40% rain)."), summary)
        XCTAssertTrue(summary.contains("Sat 24 Oct: 8–14°C, partly cloudy, 10% rain; Sun 25 Oct: 6–12°C, rain, 80% rain."), summary)

        let card = forecast.card(place: "Kraków, Poland")
        XCTAssertEqual(card.value, "12°")
        XCTAssertEqual(card.subtitle, "Partly cloudy · H 14° L 8°")
        XCTAssertEqual(card.rows.map(\.title), ["Today", "Sun"])
        XCTAssertEqual(card.rows.last?.trailing, "6° / 12°")
        XCTAssertEqual(card.rows.last?.symbol, "cloud.rain")
    }

    func testGeocodingLabelSkipsRepeats() throws {
        let json = #"{"results":[{"name":"Lisbon","latitude":38.7,"longitude":-9.1,"country":"Portugal","admin1":"Lisbon"}]}"#
        let place = try XCTUnwrap(JSONDecoder().decode(OpenMeteoGeocoding.self, from: Data(json.utf8)).results?.first)
        XCTAssertEqual(place.label, "Lisbon, Portugal")
    }

    // MARK: Dates

    func testDatesTheModelWrites() throws {
        let zone = TimeZone(identifier: "Europe/Warsaw")!
        let local = try XCTUnwrap(FlexibleDate.parse("2026-10-25T15:00", timeZone: zone))
        XCTAssertFalse(local.dateOnly)
        XCTAssertEqual(local.date, ISO8601DateFormatter().date(from: "2026-10-25T14:00:00Z"))
        XCTAssertEqual(FlexibleDate.parse("2026-10-25T15:00:00Z")?.date, ISO8601DateFormatter().date(from: "2026-10-25T15:00:00Z"))
        XCTAssertEqual(FlexibleDate.parse("2026-10-25", timeZone: zone)?.dateOnly, true)
        XCTAssertNil(FlexibleDate.parse("next Tuesday"))
        XCTAssertNil(FlexibleDate.parse(nil))
    }

    func testEventCardDefaults() {
        let args: JSONValue = ["title": "Dentist", "start": "2026-10-27T09:30", "calendar": "Home"]
        let params = DeviceTools.eventParams(args, reminder: false)
        XCTAssertEqual(params.title, "Dentist")
        XCTAssertEqual(params.allDay, false)
        XCTAssertEqual(params.listName, "Home")
        XCTAssertEqual(params.end.map { $0.timeIntervalSince(params.start!) }, 3600)

        let allDay = DeviceTools.eventParams(["title": "Holiday", "start": "2026-12-24"], reminder: false)
        XCTAssertEqual(allDay.allDay, true)

        let reminder = DeviceTools.eventParams(["title": "Call mum", "list": "Family"], reminder: true)
        XCTAssertNil(reminder.start)
        XCTAssertEqual(reminder.listName, "Family")
    }

    // MARK: Switches

    func testEffectiveToolsAreThePersonasMinusTheDisabled() {
        XCTAssertEqual(ToolCapability.effective(nil, disabled: []), Set(ToolCapability.allCases))
        XCTAssertEqual(ToolCapability.effective([.search, .maps, .calendar], disabled: ["maps", "nonsense"]), [.search, .calendar])
        XCTAssertFalse(ToolCapability.effective(nil, disabled: ["location"]).contains(.location))
    }

    func testDisabledToolsAreLeftOutOfTheRequest() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let c = Conversation(modelID: "test/unknown-model", searchMode: .auto)
        container.mainContext.insert(c)
        let m = Message(role: .user, text: "Weather?")
        c.append(m)
        container.mainContext.insert(m)

        let settings = AppSettings()
        let saved = settings.disabledTools
        defer { settings.disabledTools = saved }
        settings.disabledTools = []
        func build() throws -> (body: String, prompt: String) {
            let builder = RequestBuilder(conversation: c, persona: nil, settings: settings,
                                         catalog: ModelCatalog(client: OpenRouterClient(keyProvider: { nil })),
                                         artifacts: [], includeTitleInstruction: false)
            return (String(decoding: try JSONEncoder().encode(builder.build()), as: UTF8.self), builder.systemPrompt(toolsSupported: true))
        }
        var request = try build()
        XCTAssertTrue(request.body.contains("\"get_weather\""))
        XCTAssertTrue(request.body.contains("\"create_event\""))
        XCTAssertTrue(request.prompt.contains("- get_location / get_weather"))

        settings.setTool(.location, enabled: false)
        settings.setTool(.calendar, enabled: false)
        settings.setTool(.search, enabled: false)
        request = try build()
        XCTAssertFalse(request.body.contains("get_weather"))
        XCTAssertFalse(request.body.contains("create_event"))
        XCTAssertFalse(request.body.contains("openrouter:web_search"))
        XCTAssertTrue(request.body.contains("\"search_places\""))
        XCTAssertFalse(request.prompt.contains("get_weather"))
        XCTAssertTrue(request.prompt.contains("Web search is off"))
    }
}
