import AppIntents
import Foundation

/// A persona to answer with, for the Ask Halo shortcut.
struct PersonaEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Persona"
    static var defaultQuery = PersonaQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PersonaQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PersonaEntity] {
        AppModel.shared.personas.filter { identifiers.contains($0.id) }.map { PersonaEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PersonaEntity] {
        AppModel.shared.personas.map { PersonaEntity(id: $0.id, name: $0.name) }
    }
}

/// Asks a question and answers in place (Siri reads it out); the chat is kept in Halo.
struct AskHaloIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Halo"
    static var description = IntentDescription("Ask Halo a question and get the answer back. The chat is saved in Halo.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var question: String

    @Parameter(title: "Persona")
    var persona: PersonaEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Halo \(\.$question)") { \.$persona }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let app = AppModel.shared
        guard app.hasAPIKey else {
            let text = "Halo isn't connected to OpenRouter yet. Open Halo and sign in first."
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw $question.needsValueError() }
        let conversation = app.startChat(text: trimmed, persona: app.persona(id: persona?.id), brief: true)
        await app.engine.waitUntilIdle(conversation)
        app.engine.briefChats.remove(conversation.id)
        let text = Self.answer(in: conversation)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }

    /// The reply's text, or why there isn't one yet.
    @MainActor
    static func answer(in conversation: Conversation) -> String {
        let path = conversation.orderedMessages
        let lastUser = path.lastIndex { $0.role == .user } ?? -1
        let turn = path.suffix(from: lastUser + 1)
        if turn.contains(where: { $0.role == .tool && $0.toolState?.status == .awaitingApproval }) {
            return "Open Halo to approve the request in \"\(conversation.title)\"."
        }
        if let failed = turn.last(where: { $0.role == .assistant && $0.status == .failed }) {
            return failed.errorText ?? "Something went wrong. Open Halo to try again."
        }
        let text = turn.filter { $0.role == .assistant }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? "Halo didn't answer. Open the chat \"\(conversation.title)\" to see why." : text
    }
}

/// Opens Halo on a new chat, sending `text` when there is some.
struct NewHaloChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Halo chat"
    static var description = IntentDescription("Open Halo on a new chat, optionally sending a first message.")
    static var openAppWhenRun = true

    @Parameter(title: "Message")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New Halo chat with \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = AppModel.shared
        app.newChat()
        let message = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty && app.hasAPIKey {
            app.sendFromDraft(text: message, media: [])
        } else {
            app.requestComposer(prefill: message.isEmpty ? nil : message)
        }
        return .result()
    }
}

struct HaloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskHaloIntent(),
                    phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask Halo", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: NewHaloChatIntent(),
                    phrases: ["New \(.applicationName) chat", "Start a \(.applicationName) chat"],
                    shortTitle: "New Halo chat", systemImageName: "square.and.pencil")
    }
}
