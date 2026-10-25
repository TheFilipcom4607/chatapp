import Foundation

/// Design Arena (designarena.ai) ratings as OpenRouter lists them on each model: people see two
/// models' results for the same prompt, blind, and vote for the better one. Chat models are rated
/// on what they build (websites, games, UI components…), media models on images and voices.
enum DesignArena {
    static let source = "Design Arena"
    static let sourceURL = URL(string: "https://www.designarena.ai")!

    struct Group: Identifiable {
        /// "Models arena" or "Agents arena"; nil when the model is only in one.
        let title: String?
        let scores: [ORModel.ArenaScore]
        var id: String { title ?? "" }
    }

    /// The scores by arena, one-shot prompts before agent runs. In each, the coding-wide score leads,
    /// then the rest from the highest Elo down.
    static func groups(_ scores: [ORModel.ArenaScore]) -> [Group] {
        let byArena = Dictionary(grouping: scores) { $0.arena ?? "models" }
        let arenas = byArena.keys.sorted { order($0) != order($1) ? order($0) < order($1) : $0 < $1 }
        return arenas.map { arena in
            let sorted = byArena[arena]!.sorted {
                let a = $0.category == overall, b = $1.category == overall
                return a != b ? a : $0.elo > $1.elo
            }
            return Group(title: arenas.count > 1 ? "\(arena.prefix(1).uppercased())\(arena.dropFirst()) arena" : nil, scores: sorted)
        }
    }

    private static func order(_ arena: String) -> Int { arena == "models" ? 0 : arena == "agents" ? 1 : 2 }

    /// Every code category together.
    static let overall = "codecategories"

    /// One 0-to-100 design score per model ID: the share of blind votes its all-coding Elo would be
    /// expected to win against every other model rated there (400 points is 10:1 odds). Variants of
    /// one model (":free" and the like) count once in the field.
    static func designScores(_ models: [ORModel]) -> [String: Double] {
        func elo(_ m: ORModel) -> Double? {
            m.benchmarks?.designArena?.first { $0.category == overall && ($0.arena ?? "models") == "models" }?.elo
        }
        var field: [String: Double] = [:]
        for m in models { if let e = elo(m) { field[m.canonicalSlug ?? m.id] = e } }
        guard field.count > 1 else { return [:] }
        var scores: [String: Double] = [:]
        for m in models {
            guard let e = elo(m) else { continue }
            let key = m.canonicalSlug ?? m.id
            let others = field.filter { $0.key != key }.values
            scores[m.id] = 100 * others.reduce(0) { $0 + 1 / (1 + pow(10, ($1 - e) / 400)) } / Double(others.count)
        }
        return scores
    }

    private static let names: [String: String] = [
        "codecategories": "All coding",
        "website": "Websites",
        "webapps": "Web apps",
        "fullstack": "Full-stack apps",
        "mobileapps": "Mobile apps",
        "androidnative": "Android apps",
        "uicomponent": "UI components",
        "gamedev": "Game development",
        "agenticgamedev": "Game development",
        "godotgamedev": "Godot games",
        "3d": "3D scenes",
        "blender3d": "Blender 3D",
        "dataviz": "Data visualization",
        "svg": "SVG graphics",
        "asciiart": "ASCII art",
        "spreadsheet": "Spreadsheets",
        "htmlslides": "HTML slides",
        "agentichtmlslides": "HTML slides",
        "agenticslides(html)": "HTML slides",
        "pptxslides": "PowerPoint slides",
        "python-pptxslides": "PowerPoint slides (python-pptx)",
        "agenticslides(python-pptx)": "PowerPoint slides (python-pptx)",
        "agenticslides": "Slides",
        "image": "Images",
        "imageediting": "Image editing",
        "graphicdesign": "Graphic design",
        "logo": "Logos",
        "text-to-speech": "Text to speech",
        "audiorealism": "Audio realism",
        "video": "Video",
    ]

    /// "gamedev" → "Game development"; a category not listed here gets its key, capitalized.
    static func name(_ category: String) -> String {
        if let name = names[category] { return name }
        let spaced = category.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// "61% won · #5", or whichever half is known.
    static func caption(_ score: ORModel.ArenaScore) -> String? {
        let parts = [score.winRate.map { "\(Int($0.rounded()))% won" }, score.rank.map { "#\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
