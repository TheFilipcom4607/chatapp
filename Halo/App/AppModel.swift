import Foundation
import Observation
import SwiftData
import SwiftUI

/// Unsent text and attachments in a chat's composer, kept until sent or cleared.
struct ComposerDraft: Codable {
    var text: String
    var attachments: [MediaItem]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
}

/// Settings for a chat that hasn't been created yet (the home screen).
struct ChatDraft {
    var modelID: String
    var personaID: UUID?
    var searchMode: SearchMode
    var reasoningEffort: String?
    var serviceTier: String?
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
    case archived
    case selectText(String)

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
        case .archived: return "archived"
        case .selectText(let text): return "select-\(text.hashValue)"
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
    let lock: AppLock

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
    /// Incremented when a chat's saved draft changed outside the composer (something shared in), so
    /// a composer on screen reloads it.
    var composerDraftTick = 0
    /// A message the chat should scroll to once it's on screen (e.g. a search hit).
    var scrollTarget: UUID?
    var toast: String?
    /// Set when the chat store couldn't be opened at launch and a fresh one was started.
    var storeProblem: String?

    private init() {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, Persona.self, UsageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        var problem: String?
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Last resort: a fresh store (e.g. after a schema change that can't migrate). The old one is
            // moved aside rather than deleted, so the chats in it can still be recovered.
            // SQLite keeps -wal / -shm sidecar files next to the store; move those too.
            let path = config.url.path
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try? FileManager.default.moveItem(atPath: path + suffix, toPath: "\(path).unreadable-\(stamp)\(suffix)")
            }
            container = try! ModelContainer(for: schema, configurations: [config])
            problem = "Halo couldn't open its saved chats (\(error.localizedDescription)), so it started with an empty list. The old data was kept on this iPhone and hasn't been deleted."
        }
        self.container = container
        let settings = AppSettings()
        self.settings = settings
        let client = OpenRouterClient(keyProvider: { KeyStore.shared.apiKey })
        self.client = client
        self.catalog = ModelCatalog(client: client)
        self.account = AccountStore(client: client)
        self.engine = ChatEngine(client: client, catalog: catalog, settings: settings, account: account, context: container.mainContext)
        self.lock = AppLock(settings: settings)
        self.hasAPIKey = KeyStore.shared.apiKey?.isEmpty == false
        self.draft = ChatDraft(modelID: settings.defaultModelID, personaID: nil, searchMode: .auto, reasoningEffort: nil)

        BackgroundRunner.shared.deliver = { [weak self] job, data, status, error in
            self?.engine.applyBackgroundResult(job, data: data, status: status, error: error)
        }
        BackgroundRunner.shared.activate()
        storeProblem = problem
        recoverInterruptedReplies()
        seedPersonasIfNeeded()
        addToolsV2IfNeeded()
        resetDraft()
        DemoSeeder.seedIfNeeded(app: self)
    }

    var context: ModelContext { container.mainContext }

    var currentConversation: Conversation? {
        guard let id = currentConversationID else { return nil }
        return engine.conversation(id: id)
    }

    // MARK: Composer drafts

    /// Keyed by chat id, "new" for the home screen. Saved so a draft survives switching chats and relaunches.
    @ObservationIgnored private lazy var composerDrafts: [String: ComposerDraft] =
        UserDefaults.standard.data(forKey: "composerDrafts")?.decoded([String: ComposerDraft].self) ?? [:]

    func composerDraft(for conversationID: UUID?) -> ComposerDraft? {
        composerDrafts[conversationID?.uuidString ?? "new"]
    }

    func saveComposerDraft(_ draft: ComposerDraft?, for conversationID: UUID?) {
        let key = conversationID?.uuidString ?? "new"
        composerDrafts[key] = draft?.isEmpty == false ? draft : nil
        UserDefaults.standard.set(try? JSONEncoder().encode(composerDrafts), forKey: "composerDrafts")
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

    /// Replies that were streaming when the app was killed can never finish; stop them cleanly.
    private func recoverInterruptedReplies() {
        let streaming = MessageStatus.streaming.rawValue
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.statusRaw == streaming })
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }
        for m in stuck {
            if m.role == .system, let c = m.conversation {
                c.unlink(m, in: context)   // an unfinished summary
                continue
            }
            if m.text.isEmpty && m.reasoning.isEmpty && m.toolCalls.isEmpty {
                if let c = m.conversation { c.deleteBranch(from: m, in: context) } else { context.delete(m) }
            } else {
                m.status = .cancelled
            }
        }
        try? context.save()
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

    /// Hands the device and web tools to personas made before they existed: everything to Halo (and
    /// any persona that had every tool), the fitting ones to Researcher and Coder.
    private func addToolsV2IfNeeded() {
        guard !settings.didAddToolsV2 else { return }
        let added = Set(ToolCapability.allCases).subtracting(ToolCapability.original)
        let defaultID = settings.defaultPersonaID.flatMap(UUID.init(uuidString:))
        for p in personas {
            var caps = p.capabilities
            if p.id == defaultID || ToolCapability.original.isSubset(of: caps) {
                caps.formUnion(added)
            } else if p.isBuiltin && p.name == "Researcher" {
                caps.formUnion([.webPages, .location, .maps])
            } else if p.isBuiltin && p.name == "Coder" {
                caps.formUnion([.webPages, .device])
            }
            if caps != p.capabilities { p.capabilities = caps }
        }
        try? context.save()
        settings.didAddToolsV2 = true
    }

    // MARK: Navigation

    func resetDraft(persona: Persona? = nil) {
        let p = persona ?? self.persona(id: settings.defaultPersonaID.flatMap(UUID.init(uuidString:)))
        draft = ChatDraft(modelID: p?.modelID ?? settings.defaultModelID,
                          personaID: p?.id,
                          searchMode: p?.searchMode ?? .auto,
                          reasoningEffort: p?.reasoningEffort)
    }

    func newChat(persona: Persona? = nil) {
        currentConversationID = nil
        scrollTarget = nil
        resetDraft(persona: persona)
        withAnimation(Motion.smooth) { sidebarOpen = false }
        Haptics.tap()
    }

    /// Opens a chat; `messageID` (a search hit) is scrolled to, switching to its branch if needed.
    func open(_ conversation: Conversation, revealing messageID: UUID? = nil) {
        if let messageID, !conversation.orderedMessages.contains(where: { $0.id == messageID }),
           let message = engine.message(id: messageID) {
            engine.showBranch(through: message, in: conversation)
        }
        scrollTarget = messageID
        currentConversationID = conversation.id
        withAnimation(Motion.smooth) { sidebarOpen = false }
        Haptics.selection()
    }

    func openConversation(id: UUID) {
        if let c = engine.conversation(id: id) { open(c) }
    }

    /// Starts a chat with the default persona (or `persona`) and sends `text`, without opening it.
    /// Used by Siri and Shortcuts.
    @discardableResult
    func startChat(text: String, persona chosen: Persona? = nil, brief: Bool = false) -> Conversation {
        let p = chosen ?? persona(id: settings.defaultPersonaID.flatMap(UUID.init(uuidString:)))
        let conversation = Conversation(modelID: p?.modelID ?? settings.defaultModelID, personaID: p?.id,
                                        searchMode: p?.searchMode ?? .auto, reasoningEffort: p?.reasoningEffort)
        context.insert(conversation)
        if brief { engine.briefChats.insert(conversation.id) }
        engine.send(text: text, media: [], in: conversation)
        return conversation
    }

    /// Creates the conversation for the current draft and sends the first message.
    func sendFromDraft(text: String, media: [MediaItem]) {
        let conversation = Conversation(modelID: draft.modelID, personaID: draft.personaID,
                                        searchMode: draft.searchMode, reasoningEffort: draft.reasoningEffort)
        conversation.serviceTier = draft.serviceTier
        context.insert(conversation)
        currentConversationID = conversation.id
        engine.send(text: text, media: media, in: conversation)
    }

    func delete(_ conversation: Conversation) {
        if currentConversationID == conversation.id { currentConversationID = nil }
        guard engine.isBusy(conversation) else {
            performDelete(conversation)
            return
        }
        // Let the running turn wind down first so it never touches deleted models.
        let id = conversation.id
        Task {
            await engine.stopAndWait(conversation)
            if let c = engine.conversation(id: id) { performDelete(c) }
        }
    }

    private func performDelete(_ conversation: Conversation) {
        composerDraft(for: conversation.id)?.attachments.forEach(MediaStore.delete)
        saveComposerDraft(nil, for: conversation.id)
        for m in conversation.messages {
            m.media.forEach(MediaStore.delete)
            m.spokenAudio.forEach(MediaStore.delete)
        }
        for a in engine.artifacts(in: conversation) { context.delete(a) }
        context.delete(conversation)
        try? context.save()
    }

    // MARK: Pinning & archive

    func togglePin(_ conversation: Conversation) {
        if conversation.isPinned {
            conversation.isPinned = false
            conversation.pinOrder = nil
        } else {
            // New pins go on top.
            conversation.pinOrder = (pinnedConversations().compactMap(\.pinOrder).min() ?? 0) - 1
            conversation.isPinned = true
            conversation.isArchived = false
        }
        try? context.save()
        Haptics.selection()
    }

    /// Moves a pinned chat up (-1) or down (+1) among the pinned chats.
    func movePinned(_ conversation: Conversation, by offset: Int) {
        var pinned = pinnedConversations()
        guard let i = pinned.firstIndex(where: { $0.id == conversation.id }) else { return }
        let j = i + offset
        guard pinned.indices.contains(j) else { return }
        pinned.swapAt(i, j)
        for (n, c) in pinned.enumerated() { c.pinOrder = n }
        try? context.save()
        Haptics.selection()
    }

    func pinnedConversations() -> [Conversation] {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.isPinned })
        return Self.pinOrdered((try? context.fetch(descriptor)) ?? [])
    }

    /// Pinned chats in their chosen order; chats pinned before ordering existed follow, newest first.
    static func pinOrdered(_ conversations: [Conversation]) -> [Conversation] {
        conversations.sorted {
            let a = $0.pinOrder ?? .max, b = $1.pinOrder ?? .max
            return a != b ? a < b : $0.updatedAt > $1.updatedAt
        }
    }

    func setArchived(_ conversation: Conversation, _ archived: Bool) {
        conversation.isArchived = archived
        if archived {
            conversation.isPinned = false
            conversation.pinOrder = nil
        }
        try? context.save()
        Haptics.selection()
        if archived { showToast("Chat archived") }
    }

    func requestComposer(prefill: String? = nil) {
        composerPrefill = prefill
        composerFocusTick += 1
    }

    // MARK: Shared into Halo

    /// Puts what was shared from other apps (text, links, images) into a new chat's message box,
    /// for the user to check and send.
    func drainShareInbox() {
        let entries = ShareInbox.pending()
        guard !entries.isEmpty else { return }
        var parts: [String] = []
        var media: [MediaItem] = []
        var hosts: [String] = []
        for entry in entries {
            let item = entry.item
            for piece in [item.note, item.text, item.url] {
                if let piece = piece?.trimmingCharacters(in: .whitespacesAndNewlines), !piece.isEmpty { parts.append(piece) }
            }
            if let host = item.url.flatMap(URL.init(string:))?.host { hosts.append(host.replacingOccurrences(of: "www.", with: "")) }
            for name in item.imageFiles {
                if let data = try? Data(contentsOf: entry.folder.appendingPathComponent(name)),
                   let saved = try? MediaStore.save(data, kind: .image, mimeType: "image/jpeg", ext: "jpg", originalName: "Shared image") {
                    media.append(saved)
                }
            }
            ShareInbox.remove(entry.folder)
        }
        guard !parts.isEmpty || !media.isEmpty else { return }
        sheet = nil
        newChat()
        var draft = composerDraft(for: nil) ?? ComposerDraft(text: "", attachments: [])
        draft.text = ([draft.text] + parts).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        draft.attachments += media
        saveComposerDraft(draft, for: nil)
        composerDraftTick += 1
        requestComposer()
        showToast(hosts.first.map { "Shared from \($0)" } ?? "Shared into a new chat")
    }

    func showToast(_ text: String) {
        withAnimation(Motion.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(Motion.gentle) { if toast == text { toast = nil } }
        }
    }
}
