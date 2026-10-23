import Foundation
import SwiftData
import SwiftUI

/// Finds chats by title or by the text of their messages (on any branch, archived chats included).
@MainActor
enum ChatSearch {
    /// Holds ids rather than models so a chat deleted while results are on screen can't be touched.
    struct Hit: Identifiable {
        let id: UUID
        /// The matching message, when the hit came from message text rather than the title.
        let messageID: UUID?
        let snippet: String?
    }

    static func run(_ query: String, conversations: [Conversation], context: ModelContext) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let titleHits = conversations
            .filter { $0.title.localizedStandardContains(q) }
            .map { Hit(id: $0.id, messageID: nil, snippet: nil) }
        var seen = Set(titleHits.map(\.id))

        let toolRole = MessageRole.tool.rawValue
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.roleRaw != toolRole && $0.text.localizedStandardContains(q) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 400
        var messageHits: [(hit: Hit, updatedAt: Date)] = []
        for m in (try? context.fetch(descriptor)) ?? [] {
            guard let c = m.conversation, seen.insert(c.id).inserted else { continue }
            messageHits.append((Hit(id: c.id, messageID: m.id, snippet: snippet(of: m.text, around: q)), c.updatedAt))
        }
        messageHits.sort { $0.updatedAt > $1.updatedAt }
        return titleHits + messageHits.map { $0.hit }
    }

    /// One line of text around the first match, with ellipses where it was cut.
    static func snippet(of text: String, around query: String, before: Int = 30, after: Int = 90) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let range = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(before + after))
        }
        let start = flat.index(range.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flat.startIndex { out = "…" + out }
        if end < flat.endIndex { out += "…" }
        return out
    }

    /// `text` with every occurrence of `query` emphasized.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return result }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            if let ar = Range(r, in: result) {
                result[ar].foregroundColor = Theme.textPrimary
                result[ar].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = r.upperBound
        }
        return result
    }
}
