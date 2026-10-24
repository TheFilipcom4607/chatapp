import Foundation
import SwiftData
import UIKit

/// Seeds a showcase conversation when launched with `-demo` (used for screenshots / UI review).
/// Launch arguments: `-demo` plus optionally
/// `-demoScreen home|chat|sidebar|approval|shell|artifact|spend|onboarding|settings|models|persona|details|sources`.
@MainActor
enum DemoSeeder {
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }
    static var screen: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoScreen"), i + 1 < args.count { return args[i + 1] }
        return "chat"
    }

    static func seedIfNeeded(app: AppModel) {
        guard isDemo else { return }
        if screen == "onboarding" {
            app.hasAPIKey = false
            return
        }
        if KeyStore.shared.apiKey == nil { KeyStore.shared.useTemporaryKey("sk-or-demo") }
        app.hasAPIKey = true
        let context = app.context
        let existing = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        if existing.isEmpty { seed(context: context, settings: app.settings) }
        let conversations = (try? context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        switch screen {
        case "home":
            app.currentConversationID = nil
        case "sidebar":
            app.currentConversationID = conversations.first?.id
            app.sidebarOpen = true
        case "approval":
            app.currentConversationID = conversations.first { $0.title == "Neon fox poster" }?.id
        case "shell":
            app.currentConversationID = conversations.first { $0.title == "Tram 2021" }?.id
        case "audio":
            app.currentConversationID = conversations.first { $0.title == "Good morning in French" }?.id
        case "tools":
            app.currentConversationID = conversations.first { $0.title == "Saturday in Kraków" }?.id
        case "sources", "sourcelist":
            let chat = conversations.first { $0.title == "Bus in Tallinn" }
            app.currentConversationID = chat?.id
            if screen == "sourcelist", let chat, let turn = TurnSummary.byLastMessage(chat.orderedMessages).values.first {
                app.sheet = .sources(turn.citations)
            }
        case "toolsettings":
            app.currentConversationID = conversations.first?.id
            app.sheet = .settings
        case "location", "weather", "calendar":
            // Runs a real tool on launch, so its iOS permission prompt and result can be checked.
            app.currentConversationID = conversations.first { $0.title == "Saturday in Kraków" }?.id
            Task {
                let outcome: ToolOutcome
                switch screen {
                case "location": outcome = await DeviceTools.getLocation(.object([:]))
                case "weather": outcome = await DeviceTools.getWeather(["place": "Kraków"])
                default: outcome = await DeviceTools.listEvents(.object([:]))
                }
                app.showToast(outcome.summary)
                print("DEMO TOOL \(screen): \(outcome.text)")
            }
        case "artifact":
            app.currentConversationID = conversations.first?.id
            if let artifact = try? context.fetch(FetchDescriptor<Artifact>()).first {
                app.fullScreenArtifact = .artifact(artifact.id, nil)
            }
        case "spend":
            app.currentConversationID = conversations.first?.id
            app.sheet = .spend
        case "settings":
            app.currentConversationID = conversations.first?.id
            app.sheet = .settings
        case "models":
            app.currentConversationID = conversations.first?.id
            app.sheet = .modelPicker
        case "persona":
            app.currentConversationID = nil
            app.sheet = .personaEditor(app.personas.first { $0.name == "Coder" }?.id ?? app.personas.first?.id)
        case "details":
            let chat = conversations.first { $0.title == "Black holes, explained" }
            app.currentConversationID = chat?.id
            if let reply = chat?.orderedMessages.first(where: { $0.role == .assistant && $0.usage != nil }) {
                app.sheet = .details(reply.id)
            }
        default:
            app.currentConversationID = conversations.first { $0.title == "Black holes, explained" }?.id
        }
    }

    private static func seed(context: ModelContext, settings: AppSettings) {
        // Conversation 1: rich answer with markdown, math, table, code, image, artifact.
        let c1 = Conversation(modelID: "anthropic/claude-sonnet-5.5", searchMode: .auto, reasoningEffort: "high")
        c1.title = "Black holes, explained"
        c1.titleIsSet = true
        context.insert(c1)
        var i = 0
        func add(_ role: MessageRole, _ text: String, to c: Conversation, configure: (Message) -> Void = { _ in }) {
            let m = Message(role: role, text: text, sortIndex: i, modelID: c.modelID)
            i += 1
            m.conversation = c
            configure(m)
            context.insert(m)
        }
        add(.user, "How big would a black hole with Earth's mass be? Show the math and draw me one.", to: c1)
        add(.assistant, """
        Surprisingly small: about the size of a **marble**.

        The radius of a non-rotating black hole is the *Schwarzschild radius*:

        $$r_s = \\frac{2GM}{c^2}$$

        Plugging in Earth's mass $M \\approx 5.97 \\times 10^{24}\\,\\text{kg}$:

        | Quantity | Value |
        |---|---|
        | $G$ | $6.674 \\times 10^{-11}$ |
        | $c$ | $2.998 \\times 10^{8}$ m/s |
        | **$r_s$** | **≈ 8.9 mm** |

        ```python
        G, M, c = 6.674e-11, 5.972e24, 2.998e8
        r_s = 2 * G * M / c**2
        print(f"{r_s * 1000:.1f} mm")  # 8.9 mm
        ```

        > A teaspoon of that black hole would weigh more than every mountain on Earth combined.

        I also made you a picture and a one-page explainer.
        """, to: c1) { m in
            m.reasoning = "The user wants the Schwarzschild radius for Earth's mass. r = 2GM/c^2 ≈ 8.87 mm. I'll show the formula, a table of constants, Python to verify, then generate an image."
            m.cost = 0.0112
            m.latency = 3.8
            m.duration = 9.6
            m.provider = "Anthropic"
            m.usage = Usage(promptTokens: 1840, completionTokens: 612, totalTokens: 2452, cost: 0.0112,
                            promptTokensDetails: .init(cachedTokens: 1200), completionTokensDetails: .init(reasoningTokens: 140),
                            serverToolUseDetails: .init(webSearchRequests: 1))
            m.annotations = [
                ["type": "url_citation", "url_citation": ["url": "https://en.wikipedia.org/wiki/Schwarzschild_radius", "title": "Schwarzschild radius – Wikipedia"]],
                ["type": "url_citation", "url_citation": ["url": "https://science.nasa.gov/universe/black-holes/", "title": "Black Holes – NASA Science"]],
            ]
        }
        if let img = demoImage(), let item = try? MediaStore.save(img, kind: .image, mimeType: "image/png", ext: "png", prompt: "A marble-sized black hole floating above a desk, gravitational lensing, cinematic", model: settings.imageModelID) {
            add(.tool, "Generated 1 image", to: c1) { m in
                m.toolCallID = "demo_img"
                m.media = [item]
                m.toolState = ToolState(name: "generate_image", arguments: "{}", status: .done, summary: "1 image · $0.039",
                                        approval: ApprovalParams(prompt: item.prompt ?? "", model: settings.imageModelID))
                m.cost = 0.039
            }
        }
        let artifact = Artifact(title: "Black Holes 101", kind: .markdown, language: nil, content: """
        # Black Holes 101

        A **black hole** forms when mass is compressed inside its *Schwarzschild radius*.

        ## Key ideas
        - Event horizon: the point of no return
        - Hawking radiation: black holes slowly evaporate
        - Spaghettification: tidal forces stretch infalling matter

        $$r_s = \\frac{2GM}{c^2}$$
        """, conversationID: c1.id)
        context.insert(artifact)
        add(.tool, "Created artifact", to: c1) { m in
            m.toolCallID = "demo_art"
            m.toolState = ToolState(name: "create_artifact", arguments: "{}", status: .done, summary: "Black Holes 101",
                                    artifactID: artifact.id, artifactVersion: 1)
        }
        c1.totalCost = 0.0502

        // Conversation 2: pending approval card.
        let c2 = Conversation(modelID: "google/gemini-4-argon")
        c2.title = "Neon fox poster"
        c2.titleIsSet = true
        c2.updatedAt = Date().addingTimeInterval(-3600 * 26)
        context.insert(c2)
        add(.user, "Design a synthwave poster of a fox in a neon city", to: c2)
        add(.assistant, "Love it — here's the concept I'll render: a sleek fox silhouette on a rain-soaked rooftop, magenta and cyan neon, 80s grid horizon.", to: c2) { m in
            m.toolCalls = [ToolCall(id: "demo_call", function: .init(name: "generate_image", arguments: "{}"))]
        }
        add(.tool, "Waiting for approval", to: c2) { m in
            m.toolCallID = "demo_call"
            m.toolState = ToolState(name: "generate_image", arguments: "{}", status: .awaitingApproval,
                                    approval: ApprovalParams(prompt: "Synthwave poster: a sleek fox silhouette on a rain-soaked rooftop, magenta and cyan neon signs, retro 80s grid horizon, glowing sun, film grain, 4k",
                                                             model: settings.imageModelID, aspectRatio: "2:3", count: 1, estimatedCost: 0.039))
        }

        // Conversation 3: a shell command waiting for approval.
        let c3 = Conversation(modelID: "anthropic/claude-sonnet-5.5")
        c3.title = "Tram 2021"
        c3.titleIsSet = true
        c3.updatedAt = Date().addingTimeInterval(-3600 * 30)
        context.insert(c3)
        let command = "curl -s https://taborapi.thefilip.com/v1/fleet/2021 | jq '.result | {model, year, operator, depot: .depot.name}'"
        let shellArgs = (try? JSONEncoder().encode(["command": command])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        add(.user, "What is vehicle 2021 in Warsaw?", to: c3)
        add(.assistant, "Let me look it up in the fleet database.", to: c3) { m in
            m.toolCalls = [ToolCall(id: "demo_shell", function: .init(name: "shell", arguments: shellArgs))]
        }
        add(.tool, "Waiting for approval", to: c3) { m in
            m.toolCallID = "demo_shell"
            m.toolState = ToolState(name: "shell", arguments: shellArgs, status: .awaitingApproval,
                                    approval: ApprovalParams(prompt: command, model: ""))
        }

        // Conversation 4: spoken audio, a turn that ends on the tool with no closing text.
        let c4 = Conversation(modelID: "google/gemini-3.8-flash")
        c4.title = "Good morning in French"
        c4.titleIsSet = true
        c4.updatedAt = Date().addingTimeInterval(-3600 * 40)
        context.insert(c4)
        add(.user, "How do I say good morning in French? Say it out loud.", to: c4)
        add(.assistant, "It's **Bonjour** (bohn-ZHOOR). Here's how it sounds:", to: c4) { m in
            m.toolCalls = [ToolCall(id: "demo_speech", function: .init(name: "generate_speech", arguments: #"{"text":"Bonjour !"}"#))]
            m.cost = 0.0004
        }
        if let item = try? MediaStore.save(demoTone(), kind: .audio, mimeType: "audio/wav", ext: "wav", prompt: "Bonjour !", model: settings.speechModelID) {
            add(.tool, "Speech generated", to: c4) { m in
                m.toolCallID = "demo_speech"
                m.media = [item]
                m.toolState = ToolState(name: "generate_speech", arguments: #"{"text":"Bonjour !"}"#, status: .done, summary: "Voice · Kore")
                m.cost = 0.0021
            }
        }
        add(.assistant, "", to: c4) { m in m.cost = 0.0003 }
        c4.totalCost = 0.0028

        // Conversation 5: device tools, with an event waiting to be added.
        let c5 = Conversation(modelID: "anthropic/claude-sonnet-5.5", searchMode: .auto)
        c5.title = "Saturday in Kraków"
        c5.titleIsSet = true
        c5.updatedAt = Date().addingTimeInterval(-3600 * 3)
        context.insert(c5)
        add(.user, "What's the weather in Kraków on Saturday? If it's dry, find a good café near the Old Town and put a coffee in my calendar.", to: c5)
        add(.assistant, "", to: c5) { m in
            m.toolCalls = [ToolCall(id: "demo_weather", function: .init(name: "get_weather", arguments: #"{"place":"Kraków"}"#)),
                           ToolCall(id: "demo_places", function: .init(name: "search_places", arguments: #"{"query":"café","near":"Kraków Old Town"}"#))]
            m.cost = 0.0031
        }
        add(.tool, "Weather", to: c5) { m in
            m.toolCallID = "demo_weather"
            m.toolState = ToolState(name: "get_weather", arguments: #"{"place":"Kraków"}"#, status: .done, summary: "12° · Partly cloudy",
                                    card: ToolCard(symbol: "cloud.sun", title: "Kraków, Lesser Poland, Poland", subtitle: "Partly cloudy · H 14° L 7°", value: "12°",
                                                   rows: [.init(title: "Today", detail: "Partly cloudy", trailing: "7° / 14°", symbol: "cloud.sun"),
                                                          .init(title: "Sat", detail: "Mostly clear", trailing: "6° / 15°", symbol: "sun.max"),
                                                          .init(title: "Sun", detail: "Rain", trailing: "8° / 11°", symbol: "cloud.rain"),
                                                          .init(title: "Mon", detail: "Showers", trailing: "7° / 12°", symbol: "cloud.sun.rain")]))
        }
        add(.tool, "Places", to: c5) { m in
            m.toolCallID = "demo_places"
            m.toolState = ToolState(name: "search_places", arguments: "{}", status: .done, summary: "3 places",
                                    card: ToolCard(symbol: "map", title: "Café", subtitle: "Near Kraków Old Town",
                                                   rows: [.init(title: "Café Camelot", detail: "św. Tomasza 17", trailing: "250 m", symbol: "mappin.and.ellipse", url: "https://maps.apple.com/?q=Cafe%20Camelot"),
                                                          .init(title: "Charlotte", detail: "plac Szczepański 2", trailing: "400 m", symbol: "mappin.and.ellipse", url: "https://maps.apple.com/?q=Charlotte"),
                                                          .init(title: "Karma", detail: "Krupnicza 12", trailing: "900 m", symbol: "mappin.and.ellipse", url: "https://maps.apple.com/?q=Karma")],
                                                   buttonTitle: "Open in Maps", buttonURL: "https://maps.apple.com/?q=cafe"))
        }
        let saturday = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 10, minute: 30, weekday: 7), matchingPolicy: .nextTime) ?? .now
        add(.assistant, "Saturday looks dry and bright, 6–15°. **Café Camelot** is a short walk from the Rynek and does a great breakfast. Here's the coffee for your calendar:", to: c5) { m in
            m.toolCalls = [ToolCall(id: "demo_event", function: .init(name: "create_event", arguments: "{}"))]
            m.cost = 0.0042
        }
        add(.tool, "Waiting for approval", to: c5) { m in
            m.toolCallID = "demo_event"
            var params = ApprovalParams(prompt: "Coffee at Café Camelot", model: "")
            params.title = "Coffee at Café Camelot"
            params.start = saturday
            params.end = saturday.addingTimeInterval(3600)
            params.allDay = false
            params.location = "św. Tomasza 17, Kraków"
            m.toolState = ToolState(name: "create_event", arguments: "{}", status: .awaitingApproval, approval: params)
        }

        // Conversation 6: searched, read a page, searched again: one sources pill, the page folded away.
        let c6 = Conversation(modelID: "minimax/minimax-m3.1-flash", searchMode: .auto)
        c6.title = "Bus in Tallinn"
        c6.titleIsSet = true
        c6.updatedAt = Date().addingTimeInterval(-3600 * 4)
        context.insert(c6)
        func cite(_ url: String, _ title: String, _ snippet: String? = nil) -> JSONValue {
            ["type": "url_citation", "url_citation": ["url": .string(url), "title": .string(title), "content": snippet.map { .string($0) } ?? .null]]
        }
        add(.user, "What bus is this? From where", to: c6)
        add(.assistant, "", to: c6) { m in
            m.reasoning = "Teal livery, Solaris front, Estonian plate. Search the fleet number, then read the fleet page."
            m.toolCalls = [ToolCall(id: "demo_page", function: .init(name: "read_web_page", arguments: #"{"url":"https://www.ebus.ee/2472"}"#))]
            m.annotations = [cite("https://www.tlt.ee/en/", "Tallinna Linnatranspordi AS",
                                  "Tallinn's public transport company runs the city's buses and trams, including a growing gas-powered fleet."),
                             cite("https://en.wikipedia.org/wiki/Solaris_Urbino_12", "Solaris Urbino 12 – Wikipedia",
                                  "The Solaris Urbino 12 is a 12-metre low-floor city bus built in Poland since 1999.")]
            m.duration = 186
            m.cost = 0.041
        }
        add(.tool, "Page", to: c6) { m in
            m.toolCallID = "demo_page"
            m.toolState = ToolState(name: "read_web_page", arguments: #"{"url":"https://www.ebus.ee/2472"}"#, status: .done,
                                    summary: "Tallinn, Nº 2472",
                                    card: ToolCard(symbol: "doc.text", title: "Tallinn, Nº 2472 AS Tallinna Linnatransport (Mustamäe garaaž)",
                                                   subtitle: "ebus.ee · 1k characters", buttonTitle: "Open in Safari", buttonURL: "https://www.ebus.ee/2472"))
        }
        add(.assistant, """
        That's a **Solaris Urbino IV 12 CNG** (fleet no. **2472**) run by **Tallinna Linnatransport** in **Tallinn, Estonia**, in service since 2022.

        - The side card shows **line 16**, Väike-Õismäe ⇄ Tallinn-Väike.
        - *"See buss on roheline"* ("this bus is green") is TLT's slogan for its gas-powered fleet.
        """, to: c6) { m in
            m.reasoning = "The fleet page confirms model, year and depot."
            m.latency = 9
            m.duration = 11.5
            m.cost = 0.025
            m.usage = Usage(promptTokens: 9_200, completionTokens: 1_310, completionTokensDetails: .init(reasoningTokens: 1_000),
                            serverToolUseDetails: .init(webSearchRequests: 1))
            m.annotations = [cite("https://en.wikipedia.org/wiki/Solaris_Urbino_12", "Solaris Urbino 12 – Wikipedia"),
                             cite("https://transport.tallinn.ee/#bus/16", "Routes and Schedules", "Routes and Schedules"),
                             cite("https://et.wikipedia.org/wiki/16_(Tallinna_bussiliin)", "16 (Tallinna bussiliin)", "16 (Tallinna bussiliin)")]
        }
        c6.totalCost = 0.066

        // A few extra chats for the sidebar.
        let hour: Double = 3600
        let extras: [(String, Double)] = [
            ("Swift concurrency deep dive", hour * 2),
            ("Weekend in Lisbon", hour * 50),
            ("Pitch deck outline", hour * 24 * 5),
            ("Sourdough troubleshooting", hour * 24 * 12),
        ]
        for (title, ago) in extras {
            let c = Conversation(modelID: settings.defaultModelID)
            c.title = title
            c.titleIsSet = true
            c.updatedAt = Date().addingTimeInterval(-ago)
            context.insert(c)
            add(.user, title, to: c)
            add(.assistant, "…", to: c)
        }

        // Spending history.
        let models = ["anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol", "google/gemini-4-argon", settings.imageModelID]
        for d in 0..<21 {
            for (k, model) in models.enumerated() where (d + k) % 3 != 0 {
                let cents = Double((d * 7 + k * 13) % 17)
                let cost: Double = cents / 100 + 0.01
                let r = UsageRecord(kind: k == 3 ? .image : .chat, modelID: model, cost: cost, conversationID: c1.id, messageID: nil)
                r.date = Calendar.current.date(byAdding: .day, value: -d, to: .now) ?? .now
                context.insert(r)
            }
        }
        try? context.save()
    }

    /// Two soft notes, standing in for a voice clip.
    private static func demoTone() -> Data {
        let rate = 24_000
        var pcm = Data()
        for (freq, length) in [(392.0, 0.35), (523.0, 0.55)] {
            let n = Int(Double(rate) * length)
            for i in 0..<n {
                let t = Double(i) / Double(rate)
                let envelope = min(1, Double(i) / 800) * min(1, Double(n - i) / 2400)
                let sample = Int16(sin(2 * .pi * freq * t) * 9000 * envelope)
                withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        return WAV.wrap(pcm: pcm, sampleRate: rate)
    }

    /// Procedurally drawn "black hole" so the demo has a real image without network.
    private static func demoImage() -> Data? {
        let size = CGSize(width: 768, height: 768)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<220 {
                let p = CGPoint(x: .random(in: 0...size.width), y: .random(in: 0...size.height))
                UIColor(white: 1, alpha: .random(in: 0.2...0.9)).setFill()
                cg.fillEllipse(in: CGRect(x: p.x, y: p.y, width: 2, height: 2))
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let colors = [UIColor(red: 1, green: 0.75, blue: 0.4, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.3, blue: 0.5, alpha: 0.6).cgColor, UIColor.clear.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.35, 0.55, 1]) {
                cg.saveGState()
                cg.translateBy(x: center.x, y: center.y)
                cg.scaleBy(x: 1, y: 0.32)
                cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 330, options: [])
                cg.restoreGState()
                cg.drawRadialGradient(g, startCenter: center, startRadius: 120, endCenter: center, endRadius: 210, options: [])
            }
            UIColor.black.setFill()
            cg.fillEllipse(in: CGRect(x: center.x - 115, y: center.y - 115, width: 230, height: 230))
        }
        return img.pngData()
    }
}
