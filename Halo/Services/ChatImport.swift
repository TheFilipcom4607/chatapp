import Foundation
import SwiftData

/// Reads chats exported as Markdown from the chat page on openrouter.ai:
///
///     # Chat title
///
///     **User - --**
///
///     question
///
///     **Assistant - --**
///
///     answer
///
/// The part after the role may name the model; anything else there is ignored.
enum OpenRouterChatImport {
    struct Turn: Equatable {
        var role: MessageRole
        var text: String
        /// A model id ("anthropic/claude-sonnet-5.5") or display name, when the export names one.
        var model: String?
    }

    struct Chat: Equatable {
        var title: String?
        var turns: [Turn]
    }

    static func parse(_ markdown: String) -> Chat? {
        var title: String?
        var turns: [Turn] = []
        var current: Turn?
        var body: [Substring] = []
        var inFence = false

        func flush() {
            guard var turn = current else { return }
            turn.text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !turn.text.isEmpty { turns.append(turn) }
            current = nil
            body = []
        }

        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let header = header(trimmed) {
                flush()
                current = header
                continue
            }
            if current == nil {
                // Before the first message: only the title matters.
                if title == nil, trimmed.hasPrefix("# ") { title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                continue
            }
            body.append(line)
        }
        flush()
        guard turns.contains(where: { $0.role == .user }) else { return nil }
        return Chat(title: title?.isEmpty == false ? title : nil, turns: turns)
    }

    /// A line like `**User - --**` or `**Assistant - openai/gpt-6.1-sol**`.
    private static func header(_ line: String) -> Turn? {
        guard line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") else { return nil }
        let inner = line.dropFirst(2).dropLast(2)
        let parts = inner.components(separatedBy: " - ")
        let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let role: MessageRole
        switch name {
        case "user", "you", "human": role = .user
        case "assistant", "ai", "bot": role = .assistant
        default: return nil
        }
        var model: String?
        if role == .assistant {
            let rest = parts.dropFirst().joined(separator: " - ")
            let words = rest.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" })
            if let id = words.first(where: { $0.contains("/") }) {
                model = String(id)
            } else {
                let cleaned = rest.trimmingCharacters(in: CharacterSet(charactersIn: "-–— ").union(.whitespaces))
                if cleaned.contains(where: \.isLetter) { model = cleaned }
            }
        }
        return Turn(role: role, text: "", model: model)
    }
}

extension AppModel {
    /// Imports a JSON backup or an openrouter.ai Markdown chat, then opens the chat if there's one.
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "json" {
            do {
                let n = try ExportService.importBackup(from: url, context: context)
                showToast("Imported \(n) chat\(n == 1 ? "" : "s")")
            } catch {
                showToast("Import failed: \(error.localizedDescription)")
            }
            return
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let chat = OpenRouterChatImport.parse(text) else {
            showToast("That file doesn't look like an OpenRouter chat export")
            return
        }
        let conversation = importChat(chat)
        sheet = nil
        open(conversation)
        showToast("Imported \"\(conversation.title)\"")
    }

    @discardableResult
    func importChat(_ chat: OpenRouterChatImport.Chat) -> Conversation {
        resetDraft()
        let lastModel = chat.turns.last(where: { $0.role == .assistant && $0.model != nil })?.model
        let conversation = Conversation(modelID: resolveModel(lastModel) ?? draft.modelID, personaID: draft.personaID,
                                        webSearch: draft.webSearch, reasoningEffort: draft.reasoningEffort)
        let firstUser = chat.turns.first { $0.role == .user }?.text ?? ""
        conversation.title = chat.title ?? TitleExtractor.fallback(from: firstUser)
        // openrouter.ai titles are often the first words of the question; let the next reply name it properly.
        let squashed = firstUser.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        conversation.titleIsSet = !(chat.title.map { squashed.lowercased().hasPrefix($0.lowercased()) } ?? true)
        context.insert(conversation)

        var previous: Message?
        for (i, turn) in chat.turns.enumerated() {
            let model = turn.role == .assistant ? (resolveModel(turn.model) ?? conversation.modelID) : nil
            let m = Message(role: turn.role, text: turn.text, sortIndex: i, modelID: model)
            m.parentID = previous?.id
            m.conversation = conversation
            context.insert(m)
            previous = m
        }
        conversation.activeLeafID = previous?.id
        try? context.save()
        return conversation
    }

    /// Matches an id or display name from an export against the catalog.
    private func resolveModel(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if name.contains("/") { return name }
        let lower = name.lowercased()
        return catalog.models.first { $0.name.lowercased() == lower || $0.shortName.lowercased() == lower }?.id
    }
}
