import Foundation

extension Error {
    /// The error as a tool reports it to the model: everything known, not the short line the user
    /// sees. OpenRouter's status and its own message, and for system errors the domain, code,
    /// failing URL and underlying error, so the model can tell a setting from a real limit and say
    /// what to change instead of guessing.
    var modelDescription: String {
        if let error = self as? OpenRouterError {
            switch error {
            case let .http(status, message):
                var text = "HTTP \(status) from OpenRouter"
                if !message.isEmpty { text += ": \(message)" }
                if let friendly = error.errorDescription, friendly != message, !friendly.isEmpty {
                    text += "\n(Halo shows the user: \(friendly))"
                }
                return text
            default:
                return error.errorDescription ?? String(describing: error)
            }
        }
        let ns = self as NSError
        var text = localizedDescription
        // Halo's own error types already say everything in their description.
        guard !ns.domain.hasPrefix("Halo.") else { return text }
        text += " [\(ns.domain) \(ns.code)]"
        if let url = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            text += "\nURL: \(url)"
        }
        if let reason = ns.localizedFailureReason, !text.contains(reason) {
            text += "\nReason: \(reason)"
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "\nUnderlying: \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }
}

extension String {
    /// At most `limit` characters for the model, keeping the start and, above all, the end: the end
    /// of a traceback or a long stderr is where the actual error is.
    func clippedForModel(_ limit: Int) -> String {
        guard count > limit else { return self }
        let head = limit / 4
        let tail = limit - head
        return String(prefix(head)) + "\n… [\(count - limit) characters cut from the middle] …\n" + String(suffix(tail))
    }
}
