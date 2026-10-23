import Foundation
import SwiftData
import UIKit

/// Seeds a showcase conversation when launched with `-demo` (used for screenshots / UI review).
/// Launch arguments: `-demo` plus optionally
/// `-demoScreen home|chat|sidebar|approval|artifact|spend|onboarding|settings|models|persona|details`.
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
        let c1 = Conversation(modelID: "anthropic/claude-sonnet-5.5", webSearch: true, reasoningEffort: "high")
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
            m.latency = 0.62
            m.duration = 7.4
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
