import Foundation
import Observation

enum Defaults {
    static let chatModel = "anthropic/claude-sonnet-5.5"
    static let favorites = [
        "anthropic/claude-sonnet-5.5",
        "anthropic/claude-opus-5.5",
        "openai/gpt-6.1-sol",
        "google/gemini-4-argon",
        "x-ai/grok-4.7",
        "deepseek/deepseek-v4.1-flash",
        "google/gemini-3.8-flash",
    ]
    static let imageModel = "google/gemini-3.1-flash-image"
    static let videoModel = "google/veo-3.1-fast"
    static let speechModel = "google/gemini-3.8-flash-tts"
    static let speechVoice = "Kore"
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let store = UserDefaults.standard

    var userName: String { didSet { store.set(userName, forKey: "userName") } }
    var defaultModelID: String { didSet { store.set(defaultModelID, forKey: "defaultModelID") } }
    var favoriteModelIDs: [String] { didSet { store.set(favoriteModelIDs, forKey: "favoriteModelIDs") } }
    var imageModelID: String { didSet { store.set(imageModelID, forKey: "imageModelID") } }
    var videoModelID: String { didSet { store.set(videoModelID, forKey: "videoModelID") } }
    var speechModelID: String { didSet { store.set(speechModelID, forKey: "speechModelID") } }
    var speechVoice: String { didSet { store.set(speechVoice, forKey: "speechVoice") } }
    var pdfEngine: String { didSet { store.set(pdfEngine, forKey: "pdfEngine") } }
    var promptCaching: Bool { didSet { store.set(promptCaching, forKey: "promptCaching") } }
    var haptics: Bool { didSet { store.set(haptics, forKey: "haptics") } }
    var smoothStreaming: Bool { didSet { store.set(smoothStreaming, forKey: "smoothStreaming") } }
    var notifyWhenDone: Bool { didSet { store.set(notifyWhenDone, forKey: "notifyWhenDone") } }
    var defaultPersonaID: String? { didSet { store.set(defaultPersonaID, forKey: "defaultPersonaID") } }
    var didSeedPersonas: Bool { didSet { store.set(didSeedPersonas, forKey: "didSeedPersonas") } }

    init() {
        userName = store.string(forKey: "userName") ?? "Filip"
        defaultModelID = store.string(forKey: "defaultModelID") ?? Defaults.chatModel
        favoriteModelIDs = store.stringArray(forKey: "favoriteModelIDs") ?? Defaults.favorites
        imageModelID = store.string(forKey: "imageModelID") ?? Defaults.imageModel
        videoModelID = store.string(forKey: "videoModelID") ?? Defaults.videoModel
        speechModelID = store.string(forKey: "speechModelID") ?? Defaults.speechModel
        speechVoice = store.string(forKey: "speechVoice") ?? Defaults.speechVoice
        pdfEngine = store.string(forKey: "pdfEngine") ?? "auto"
        promptCaching = store.object(forKey: "promptCaching") as? Bool ?? true
        haptics = store.object(forKey: "haptics") as? Bool ?? true
        smoothStreaming = store.object(forKey: "smoothStreaming") as? Bool ?? true
        notifyWhenDone = store.object(forKey: "notifyWhenDone") as? Bool ?? true
        defaultPersonaID = store.string(forKey: "defaultPersonaID")
        didSeedPersonas = store.bool(forKey: "didSeedPersonas")
    }

    func toggleFavorite(_ id: String) {
        if let i = favoriteModelIDs.firstIndex(of: id) { favoriteModelIDs.remove(at: i) }
        else { favoriteModelIDs.append(id) }
    }
}
