import Foundation
import Observation
import SwiftData
import SwiftUI

/// Settings for a chat that hasn't been created yet (the home screen).
struct ChatDraft {
    var modelID: String
    var personaID: UUID?
    var webSearch: Bool
    var reasoningEffort: String?
}

enum SheetRoute: Identifiable {
    case settings
    case modelPicker
    case spend
    case personaEditor(UUID?)
    case details(UUID)
    case preview(String, String)
    case run(String, String)
    case artifact(UUID, Int?)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .modelPicker: return "models"
        case .spend: return "spend"
        case .personaEditor(let id): return "persona-\(id?.uuidString ?? "new")"
        case .details(let id): return "details-\(id)"
        case .preview(let l, let c): return "preview-\(l)-\(c.hashValue)"
        case .run(let l, let c): return "run-\(l)-\(c.hashValue)"
        case .artifact(let id, let v): return "artifact-\(id)-\(v ?? 0)"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let settings: AppSettings
    let client: OpenRouterClient
    let catalog: ModelCatalog
    let account: AccountStore
    let engine: ChatEngine

    var hasAPIKey: Bool
    var currentConversationID: UUID?
    var draft: ChatDraft
    var sheet: SheetRoute?
    var fullScreenArtifact: SheetRoute?
    var viewingImage: MediaItem?
    var sidebarOpen = false
    /// Incremented to ask the composer to focus; `composerPrefill` is inserted when set.
    var composerFocusTick = 0
    var composerPrefill: String?
    var toast: String?

    private init() {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, Persona.self, UsageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Last resort: a fresh store (e.g. after an incompatible schema change during development).
            let url = config.url
            try? FileManager.default.removeItem(at: url)
            container = try! ModelContainer(for: schema, configurations: [config])
        }
        self.container = container
        let settings = AppSettings()
        self.settings = settings
        let client = OpenRouterClient(keyProvider: { KeyStore.shared.apiKey })
        self.client = client
        self.catalog = ModelCatalog(client: client)
        self.account = AccountStore(client: client)
        self.engine = ChatEngine(client: client, catalog: catalog, settings: settings, account: account, context: container.mainContext)
        self.hasAPIKey = KeyStore.shared.apiKey?.isEmpty == false
        self.draft = ChatDraft(modelID: settings.defaultModelID, personaID: nil, webSearch: true, reasoningEffort: nil)

        BackgroundRunner.shared.deliver = { [weak self] job, data, status, error in
            self?.engine.applyBackgroundResult(job, data: data, status: status, error: error)
        }
        BackgroundRunner.shared.activate()
        seedPersonasIfNeeded()
        resetDraft()
        DemoSeeder.seedIfNeeded(app: self)
    }

    var context: ModelContext { container.mainContext }

    var currentConversation: Conversation? {
        guard let id = currentConversationID else { return nil }
        return engine.conversation(id: id)
    }

    // MARK: Auth

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeyStore.shared.apiKey = trimmed
        hasAPIKey = !trimmed.isEmpty
        Task {
            await account.refresh()
            await catalog.refreshIfNeeded()
        }
    }

    func signOut() {
        KeyStore.shared.apiKey = nil
        KeyStore.shared.managementKey = nil
        account.clear()
        hasAPIKey = false
    }

    // MARK: Personas

    var personas: [Persona] {
        let descriptor = FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.sortIndex)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func persona(id: UUID?) -> Persona? {
        guard let id else { return nil }
        return personas.first { $0.id == id }
    }

    private func seedPersonasIfNeeded() {
        guard !settings.didSeedPersonas else { return }
        for (i, seed) in DefaultPersonas.seeds.enumerated() {
            let p = Persona(name: seed.name, icon: seed.icon, colorHex: seed.color, systemPrompt: seed.prompt, modelID: seed.model,
                            reasoningEffort: seed.effort, capabilities: seed.caps, alwaysSearch: seed.alwaysSearch, isBuiltin: true, sortIndex: i)
            context.insert(p)
            if i == 0 { settings.defaultPersonaID = p.id.uuidString }
        }
        try? context.save()
        settings.didSeedPersonas = true
    }

    // MARK: Navigation

    func resetDraft(persona: Persona? = nil) {
        let p = persona ?? self.persona(id: settings.defaultPersonaID.flatMap(UUID.init(uuidString:)))
        draft = ChatDraft(modelID: p?.modelID ?? settings.defaultModelID,
                          personaID: p?.id,
                          webSearch: p.map { $0.alwaysSearch || $0.capabilities.contains(.search) } ?? true,
                          reasoningEffort: p?.reasoningEffort)
    }

    func newChat(persona: Persona? = nil) {
        currentConversationID = nil
        resetDraft(persona: persona)
        withAnimation(Motion.smooth) { sidebarOpen = false }
        Haptics.tap()
    }

    func open(_ conversation: Conversation) {
        currentConversationID = conversation.id
        engine.openConversationID = conversation.id
        withAnimation(Motion.smooth) { sidebarOpen = false }
        Haptics.selection()
    }

    func openConversation(id: UUID) {
        if let c = engine.conversation(id: id) { open(c) }
    }

    /// Creates the conversation for the current draft and sends the first message.
    func sendFromDraft(text: String, media: [MediaItem]) {
        let conversation = Conversation(modelID: draft.modelID, personaID: draft.personaID,
                                        webSearch: draft.webSearch, reasoningEffort: draft.reasoningEffort)
        context.insert(conversation)
        currentConversationID = conversation.id
        engine.openConversationID = conversation.id
        engine.send(text: text, media: media, in: conversation)
    }

    func delete(_ conversation: Conversation) {
        if currentConversationID == conversation.id { currentConversationID = nil }
        for m in conversation.messages { m.media.forEach(MediaStore.delete) }
        for a in engine.artifacts(in: conversation) { context.delete(a) }
        context.delete(conversation)
        try? context.save()
    }

    func requestComposer(prefill: String? = nil) {
        composerPrefill = prefill
        composerFocusTick += 1
    }

    func showToast(_ text: String) {
        withAnimation(Motion.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(Motion.gentle) { if toast == text { toast = nil } }
        }
    }
}
