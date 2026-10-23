import Foundation

/// How much of the model's context window a chat fills.
struct ContextUsage: Equatable {
    let used: Int
    let limit: Int
    var fraction: Double { limit > 0 ? Double(used) / Double(limit) : 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
}

/// What Halo does when a chat gets close to the model's context limit.
enum LongChatMode: String, CaseIterable, Identifiable {
    /// Warn above the composer and offer a summary.
    case ask
    /// Summarize older messages automatically before sending.
    case summarize
    /// Let OpenRouter drop messages from the middle (its "middle-out" transform).
    case trim

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Warn me"
        case .summarize: return "Summarize automatically"
        case .trim: return "Drop middle messages"
        }
    }
}

/// Long chats are kept within the context window by summaries: a `.system` message on the branch
/// whose text stands in for everything before it. Requests send the summary plus later messages.
enum ContextBudget {
    static let warnAt = 0.8
    static let autoSummarizeAt = 0.85

    static func isSummary(_ m: Message) -> Bool {
        m.role == .system && m.status == .complete && !m.text.isEmpty
    }

    /// The latest summary on the branch and the messages after it (the whole branch if there's none).
    static func liveHistory(_ path: [Message]) -> (summary: Message?, messages: ArraySlice<Message>) {
        guard let i = path.lastIndex(where: isSummary) else { return (nil, path[...]) }
        return (path[i], path[(i + 1)...])
    }

    /// Measured from the token counts of the latest reply, plus an estimate for anything after it.
    static func usage(path: [Message], limit: Int?) -> ContextUsage? {
        guard let limit, limit > 0 else { return nil }
        let (summary, recent) = liveHistory(path)
        var used: Int
        var tail = recent
        if let i = recent.lastIndex(where: { $0.role == .assistant && ($0.usage?.promptTokens ?? 0) > 0 }),
           let u = recent[i].usage {
            // Reasoning isn't sent back, so it doesn't count toward the next request.
            let written = (u.completionTokens ?? 0) - (u.completionTokensDetails?.reasoningTokens ?? 0)
            used = (u.promptTokens ?? 0) + max(written, 0)
            tail = recent[(i + 1)...]
        } else {
            used = 1_500   // system prompt and tool definitions
            if let summary { used += estimate(summary) }
        }
        used += tail.reduce(0) { $0 + estimate($1) }
        return ContextUsage(used: used, limit: limit)
    }

    /// Rough token count: about four bytes of text per token, plus a flat amount per attachment.
    static func estimate(_ m: Message) -> Int {
        var bytes = m.text.utf8.count
        for call in m.toolCalls { bytes += call.function.arguments.utf8.count }
        let media = m.media.reduce(0) { total, item in
            switch item.kind {
            case .image: return total + 1_000
            case .pdf: return total + 4_000
            default: return total + 500
            }
        }
        return bytes / 4 + media
    }

    /// Whether an API error means the request didn't fit the model's context window.
    static func isOverflowError(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        let signs = ["context length", "context window", "context_length", "maximum context", "too many tokens",
                     "prompt is too long", "input is too long", "exceeds the context", "reduce the length", "token limit"]
        return signs.contains { t.contains($0) }
    }

    static let summaryInstruction = """
    Summarize our conversation so far so it can continue without the earlier messages, which will be removed. \
    Write the summary for yourself, not for me. Keep everything needed to carry on: my goals, preferences and \
    constraints; key facts, numbers, decisions and conclusions; code, file names, artifact titles and ids, and \
    image ids (img_…) that may come up again; open questions and what we were about to do next. If there is an \
    earlier summary, fold it in. Be concise but complete, using short Markdown sections and bullet points. \
    Do not call any tools. Reply with the summary only.
    """
}
