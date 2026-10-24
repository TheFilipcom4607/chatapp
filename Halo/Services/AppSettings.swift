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
    /// Favorites you're only trying out: the model menu lists them in their own group.
    var trialModelIDs: [String] { didSet { store.set(trialModelIDs, forKey: "trialModelIDs") } }
    /// When the model browser was last opened; models added since then are marked New.
    var modelsSeenAt: Date? { didSet { store.set(modelsSeenAt, forKey: "modelsSeenAt") } }
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
    /// Ask for Face ID (or the passcode) when returning to the app.
    var appLock: Bool { didSet { store.set(appLock, forKey: "appLock") } }
    /// Seconds in the background before the lock engages again.
    var appLockDelay: Int { didSet { store.set(appLockDelay, forKey: "appLockDelay") } }
    /// What to do when a chat nears the model's context limit (a `LongChatMode` raw value).
    var longChatMode: String { didSet { store.set(longChatMode, forKey: "longChatMode") } }
    /// Tier for chats that haven't picked one (a `ServiceTier` raw value).
    var defaultServiceTier: String { didSet { store.set(defaultServiceTier, forKey: "defaultServiceTier") } }
    /// Show each shell command for approval before it runs.
    var askBeforeShell: Bool { didSet { store.set(askBeforeShell, forKey: "askBeforeShell") } }
    /// `ToolCapability` raw values switched off for every chat, whatever the persona allows.
    var disabledTools: [String] { didSet { store.set(disabledTools, forKey: "disabledTools") } }
    /// Personas were given the device and web tools once.
    var didAddToolsV2: Bool { didSet { store.set(didAddToolsV2, forKey: "didAddToolsV2") } }

    init() {
        userName = store.string(forKey: "userName") ?? ""
        defaultModelID = store.string(forKey: "defaultModelID") ?? Defaults.chatModel
        favoriteModelIDs = store.stringArray(forKey: "favoriteModelIDs") ?? Defaults.favorites
        trialModelIDs = store.stringArray(forKey: "trialModelIDs") ?? []
        modelsSeenAt = store.object(forKey: "modelsSeenAt") as? Date
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
        appLock = store.bool(forKey: "appLock")
        appLockDelay = store.integer(forKey: "appLockDelay")
        longChatMode = store.string(forKey: "longChatMode") ?? LongChatMode.ask.rawValue
        defaultServiceTier = store.string(forKey: "defaultServiceTier") ?? ServiceTier.standard.rawValue
        askBeforeShell = store.object(forKey: "askBeforeShell") as? Bool ?? true
        disabledTools = store.stringArray(forKey: "disabledTools") ?? []
        didAddToolsV2 = store.bool(forKey: "didAddToolsV2")
    }

    func isToolEnabled(_ capability: ToolCapability) -> Bool { !disabledTools.contains(capability.rawValue) }

    func setTool(_ capability: ToolCapability, enabled: Bool) {
        disabledTools.removeAll { $0 == capability.rawValue }
        if !enabled { disabledTools.append(capability.rawValue) }
    }

    /// A chat's tier: its own choice, else the default.
    func serviceTier(_ chosen: String?) -> ServiceTier {
        ServiceTier(rawValue: chosen ?? defaultServiceTier) ?? .standard
    }

    func toggleFavorite(_ id: String) {
        if let i = favoriteModelIDs.firstIndex(of: id) {
            favoriteModelIDs.remove(at: i)
            trialModelIDs.removeAll { $0 == id }
        } else {
            favoriteModelIDs.append(id)
        }
    }

    func isTrial(_ id: String) -> Bool { trialModelIDs.contains(id) }

    /// Moves a favorite between the everyday group and the ones you're trying out.
    func setTrial(_ id: String, _ trying: Bool) {
        trialModelIDs.removeAll { $0 == id }
        if trying && favoriteModelIDs.contains(id) { trialModelIDs.append(id) }
    }
}
