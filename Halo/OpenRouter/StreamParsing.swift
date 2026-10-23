import Foundation

// MARK: - SSE

/// Parses OpenRouter's server-sent events line by line.
/// Each `data:` line carries one JSON chunk; `:` lines are keep-alive comments.
struct SSEParser {
    enum Event: Equatable {
        case data(String)
        case done
        case comment(String)
    }

    /// Returns the event a single line represents, or nil for blank/irrelevant lines.
    static func parse(line rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return nil }
        if line.hasPrefix(":") { return .comment(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        guard line.hasPrefix("data:") else { return nil }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == "[DONE]" { return .done }
        return .data(payload)
    }
}

// MARK: - Tool call accumulation

/// Groups streamed tool-call fragments by `index` into complete calls.
struct ToolCallAccumulator {
    private struct Partial {
        var id: String?
        var name: String = ""
        var arguments: String = ""
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []

    var isEmpty: Bool { partials.isEmpty }

    mutating func add(_ delta: ToolCallDelta) {
        let index = delta.index ?? (order.last ?? 0)
        if partials[index] == nil {
            partials[index] = Partial()
            order.append(index)
        }
        if let id = delta.id, !id.isEmpty { partials[index]?.id = id }
        if let name = delta.function?.name, !name.isEmpty {
            // Some providers resend the full name on every fragment; avoid duplicating it.
            let current = partials[index]?.name ?? ""
            if current.isEmpty { partials[index]?.name = name }
            else if current != name && !current.hasSuffix(name) { partials[index]?.name += name }
        }
        if let args = delta.function?.arguments { partials[index]?.arguments += args }
    }

    /// Snapshot of in-flight calls (name + raw partial arguments), in stream order.
    var drafts: [(index: Int, name: String, arguments: String)] {
        order.compactMap { i in partials[i].map { (i, $0.name, $0.arguments) } }
    }

    func finalized() -> [ToolCall] {
        order.compactMap { i -> ToolCall? in
            guard let p = partials[i], !p.name.isEmpty else { return nil }
            let args = p.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolCall(id: p.id ?? "call_\(i)_\(UUID().uuidString.prefix(8))",
                            function: .init(name: p.name, arguments: args.isEmpty ? "{}" : args))
        }
    }
}

// MARK: - Partial JSON

/// Best-effort reader for a JSON object that is still streaming in.
/// Extracts top-level string values (complete or truncated) so the UI can show
/// a document while the model is still writing the tool arguments.
enum PartialJSON {
    static func stringFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(text.unicodeScalars)
        var i = 0
        func skipWS() { while i < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[i]) { i += 1 } }

        /// Reads a JSON string starting at a quote. Returns (value, closed).
        func readString() -> (String, Bool) {
            guard i < chars.count, chars[i] == "\"" else { return ("", false) }
            i += 1
            var out = String.UnicodeScalarView()
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { i += 1; return (String(out), true) }
                if c == "\\" {
                    guard i + 1 < chars.count else { i += 1; return (String(out), false) }
                    let n = chars[i + 1]
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        if i + 5 < chars.count {
                            let hex = String(String.UnicodeScalarView(chars[(i + 2)...(i + 5)]))
                            if let v = UInt32(hex, radix: 16) {
                                // Handle UTF-16 surrogate pairs.
                                if (0xD800...0xDBFF).contains(v), i + 11 < chars.count, chars[i + 6] == "\\", chars[i + 7] == "u",
                                   let lo = UInt32(String(String.UnicodeScalarView(chars[(i + 8)...(i + 11)])), radix: 16) {
                                    let combined = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                                    if let s = Unicode.Scalar(combined) { out.append(s) }
                                    i += 12
                                    continue
                                }
                                if let s = Unicode.Scalar(v) { out.append(s) }
                            }
                            i += 6
                            continue
                        } else {
                            i = chars.count
                            return (String(out), false)
                        }
                    default: out.append(n)
                    }
                    i += 2
                    continue
                }
                out.append(c)
                i += 1
            }
            return (String(out), false)
        }

        /// Skips any non-string value (number, bool, nested object/array).
        func skipValue() {
            var depth = 0
            var inString = false
            while i < chars.count {
                let c = chars[i]
                if inString {
                    if c == "\\" { i += 2; continue }
                    if c == "\"" { inString = false }
                    i += 1
                    continue
                }
                switch c {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    if depth == 0 { return }
                    depth -= 1
                    if depth == 0 { i += 1; return }
                case ",": if depth == 0 { return }
                default: break
                }
                i += 1
            }
        }

        skipWS()
        guard i < chars.count, chars[i] == "{" else { return result }
        i += 1
        while i < chars.count {
            skipWS()
            guard i < chars.count else { break }
            if chars[i] == "}" { break }
            if chars[i] == "," { i += 1; continue }
            let (key, keyClosed) = readString()
            guard keyClosed else { break }
            skipWS()
            guard i < chars.count, chars[i] == ":" else { break }
            i += 1
            skipWS()
            guard i < chars.count else { break }
            if chars[i] == "\"" {
                let (value, _) = readString()
                result[key] = value
            } else {
                skipValue()
            }
        }
        return result
    }
}

// MARK: - Title extraction

/// Strips a leading `<title>…</title>` tag from a streaming reply and captures it.
struct TitleExtractor {
    private(set) var title: String?
    private var buffer = ""
    private var state: State = .detecting
    private let maxBuffer = 300

    private enum State { case detecting, passthrough }

    init(enabled: Bool = true) {
        state = enabled ? .detecting : .passthrough
    }

    /// Feeds a chunk; returns the text that should be shown to the user.
    mutating func feed(_ chunk: String) -> String {
        guard state == .detecting else { return chunk }
        buffer += chunk
        let trimmed = buffer.drop(while: { $0.isWhitespace })
        let open = "<title>"
        if trimmed.isEmpty { return "" }
        if trimmed.count < open.count {
            if open.hasPrefix(String(trimmed).lowercased()) { return "" }
            return flush()
        }
        guard trimmed.lowercased().hasPrefix(open) else { return flush() }
        if let closeRange = trimmed.range(of: "</title>", options: .caseInsensitive) {
            let titleStart = trimmed.index(trimmed.startIndex, offsetBy: open.count)
            let raw = String(trimmed[titleStart..<closeRange.lowerBound])
            title = Self.clean(raw)
            let rest = String(trimmed[closeRange.upperBound...]).drop(while: { $0.isWhitespace })
            buffer = ""
            state = .passthrough
            return String(rest)
        }
        if buffer.count > maxBuffer { return flush() }
        return ""
    }

    /// Call when the stream ends; returns anything still buffered.
    mutating func finish() -> String {
        guard state == .detecting else { return "" }
        return flush()
    }

    private mutating func flush() -> String {
        state = .passthrough
        let out = buffer
        buffer = ""
        return out
    }

    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'*#`"))
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    /// Fallback title from the user's first message.
    static func fallback(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "New chat" }
        return cleaned.count > 48 ? String(cleaned.prefix(48)) + "…" : cleaned
    }
}

// MARK: - Reasoning details

/// Merges streamed `reasoning_details` fragments: consecutive entries with the same
/// `index` and `type` are concatenated so the assistant message can be replayed intact.
enum ReasoningDetailsMerger {
    static func merge(_ existing: inout [JSONValue], _ incoming: [JSONValue]) {
        for item in incoming {
            guard case .object(var new) = item else { continue }
            if case .object(var last)? = existing.last,
               last["index"] != nil, last["index"] == new["index"],
               last["type"] == new["type"] {
                for key in ["text", "summary", "data"] {
                    if let add = new[key]?.stringValue {
                        last[key] = .string((last[key]?.stringValue ?? "") + add)
                    }
                }
                for key in ["signature", "id", "format"] {
                    if let v = new[key], v != .null { last[key] = v }
                }
                existing[existing.count - 1] = .object(last)
            } else {
                new = new.filter { $0.value != .null || $0.key == "signature" }
                existing.append(.object(new))
            }
        }
    }
}
