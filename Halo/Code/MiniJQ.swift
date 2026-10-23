import Foundation

/// The everyday part of jq: paths, pipes, commas, collecting into arrays and objects, and a few
/// builtins. Values are what JSONSerialization produces (NSNull for null).
enum MiniJQ {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(filter: String, input: String, raw: Bool, compact: Bool) throws -> String {
        let values = try parseInputs(input)
        var out = ""
        for value in values {
            for result in try evaluate(filter, value) {
                if raw, let s = result as? String { out += s + "\n" } else { out += try encode(result, compact: compact) + "\n" }
            }
        }
        return out
    }

    /// One JSON document, or one per line (NDJSON).
    private static func parseInputs(_ input: String) throws -> [Any] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed) { return [value] }
        let lines = trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let values = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        guard values.count == lines.count else {
            let preview = String(trimmed.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            throw Failure(message: "input is not valid JSON (starts with: \(preview))")
        }
        return values
    }

    static func encode(_ value: Any, compact: Bool) throws -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]
        if !compact { options.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Evaluation

    static func evaluate(_ filter: String, _ input: Any) throws -> [Any] {
        let stages = split(filter, on: "|")
        var values = [input]
        for stage in stages {
            values = try values.flatMap { value in
                try split(stage, on: ",").flatMap { try term($0.trimmingCharacters(in: .whitespaces), value) }
            }
        }
        return values
    }

    private static func term(_ t: String, _ value: Any) throws -> [Any] {
        if t.isEmpty || t == "." { return [value] }
        // `f?` drops f's errors (paths handle their own, per step).
        if t.hasSuffix("?") && !t.hasPrefix(".") { return (try? term(String(t.dropLast()), value)) ?? [] }
        if t.hasPrefix("(") && t.hasSuffix(")") { return try evaluate(String(t.dropFirst().dropLast()), value) }
        if t.hasPrefix("[") && t.hasSuffix("]") { return [try evaluate(String(t.dropFirst().dropLast()), value)] }
        if t.hasPrefix("{") && t.hasSuffix("}") { return [try object(String(t.dropFirst().dropLast()), value)] }
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { return [String(t.dropFirst().dropLast())] }
        if let number = Double(t) { return [number] }
        if t == "null" { return [NSNull()] }
        if t == "true" || t == "false" { return [t == "true"] }
        if t.hasPrefix("map(") && t.hasSuffix(")") {
            let inner = String(t.dropFirst(4).dropLast())
            return [try elements(value, name: "map").flatMap { try evaluate(inner, $0) }]
        }
        if t.hasPrefix(".") { return try path(t, value) }
        switch t {
        case "keys":
            if let dict = value as? [String: Any] { return [dict.keys.sorted()] }
            if let array = value as? [Any] { return [Array(array.indices)] }
            throw Failure(message: "\(typeName(value)) has no keys")
        case "length":
            switch value {
            case let a as [Any]: return [a.count]
            case let d as [String: Any]: return [d.count]
            case let s as String: return [s.count]
            case is NSNull: return [0]
            case let n as NSNumber: return [abs(n.doubleValue)]
            default: return [0]
            }
        case "type": return [typeName(value)]
        case "first": return [try elements(value, name: "first").first ?? NSNull()]
        case "last": return [try elements(value, name: "last").last ?? NSNull()]
        case "values": return try elements(value, name: "values")
        case "tostring": return [try (value as? String) ?? encode(value, compact: true)]
        case "empty": return []
        default:
            throw Failure(message: "unsupported filter `\(t)`. Supported: paths, |, commas, [..], {..}, map(), keys, length, type, first, last.")
        }
    }

    private static func elements(_ value: Any, name: String) throws -> [Any] {
        if let array = value as? [Any] { return array }
        if let dict = value as? [String: Any] { return dict.keys.sorted().compactMap { dict[$0] } }
        throw Failure(message: "cannot use \(name) on \(typeName(value))")
    }

    /// `{a, b: .c, "d e": .f}`
    private static func object(_ body: String, _ value: Any) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for entry in split(body, on: ",") {
            let e = entry.trimmingCharacters(in: .whitespaces)
            if e.isEmpty { continue }
            let pieces = split(e, on: ":")
            var key = pieces[0].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 { key = String(key.dropFirst().dropLast()) }
            if key.hasPrefix(".") { key.removeFirst() }
            let expr = pieces.count > 1 ? pieces.dropFirst().joined(separator: ":") : "." + key
            result[key] = try evaluate(expr, value).first ?? NSNull()
        }
        return result
    }

    private enum Step {
        case key(String)
        case index(Int)
        case slice(Int?, Int?)
        case iterate

        var isIterate: Bool { if case .iterate = self { return true } else { return false } }
    }

    private static func path(_ text: String, _ value: Any) throws -> [Any] {
        let chars = Array(text)
        var steps: [(Step, optional: Bool)] = []
        var i = 0
        while i < chars.count {
            var step: Step?
            if chars[i] == "." {
                i += 1
                if i < chars.count, chars[i] == "\"" {
                    guard let end = chars[(i + 1)...].firstIndex(of: "\"") else { throw Failure(message: "unterminated string in \(text)") }
                    step = .key(String(chars[(i + 1)..<end]))
                    i = end + 1
                } else {
                    var name = ""
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
                    if !name.isEmpty { step = .key(name) }
                }
            } else if chars[i] == "[" {
                guard let end = chars[i...].firstIndex(of: "]") else { throw Failure(message: "missing ] in \(text)") }
                let inside = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces)
                if inside.isEmpty { step = .iterate }
                else if let n = Int(inside) { step = .index(n) }
                else if inside.hasPrefix("\""), inside.hasSuffix("\""), inside.count >= 2 { step = .key(String(inside.dropFirst().dropLast())) }
                else if inside.contains(":") {
                    let bounds = inside.split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    step = .slice(bounds[0], bounds.count > 1 ? bounds[1] : nil)
                } else {
                    throw Failure(message: "unsupported index [\(inside)]")
                }
                i = end + 1
            } else {
                throw Failure(message: "unsupported filter `\(text)`")
            }
            var optional = false
            if i < chars.count, chars[i] == "?" { optional = true; i += 1 }
            if let step { steps.append((step, optional)) }
        }

        var values = [value]
        for (step, optional) in steps {
            var next: [Any] = []
            for v in values {
                do { next += try apply(step, v) } catch { if !optional { throw error } }
            }
            values = next
        }
        return values
    }

    private static func apply(_ step: Step, _ value: Any) throws -> [Any] {
        if value is NSNull { return step.isIterate ? [] : [NSNull()] }
        switch step {
        case .key(let k):
            guard let dict = value as? [String: Any] else { throw Failure(message: "cannot index \(typeName(value)) with \"\(k)\"") }
            return [dict[k] ?? NSNull()]
        case .index(let n):
            guard let array = value as? [Any] else { throw Failure(message: "cannot index \(typeName(value)) with number") }
            let index = n < 0 ? array.count + n : n
            return [array.indices.contains(index) ? array[index] : NSNull()]
        case .slice(let from, let to):
            if let s = value as? String {
                let chars = Array(s)
                let r = clamp(from, to, chars.count)
                return [String(chars[r])]
            }
            guard let array = value as? [Any] else { throw Failure(message: "cannot slice \(typeName(value))") }
            return [Array(array[clamp(from, to, array.count)])]
        case .iterate:
            return try elements(value, name: ".[]")
        }
    }

    private static func clamp(_ from: Int?, _ to: Int?, _ count: Int) -> Range<Int> {
        func fix(_ n: Int) -> Int { min(max(n < 0 ? count + n : n, 0), count) }
        let lower = fix(from ?? 0), upper = fix(to ?? count)
        return lower..<max(lower, upper)
    }

    static func typeName(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? "boolean" : "number"
        case is String: return "string"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        default: return "unknown"
        }
    }

    /// Splits on `separator` outside brackets, parens, braces and strings.
    private static func split(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var previous: Character = " "
        for c in text {
            if c == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if "([{".contains(c) { depth += 1 }
                if ")]}".contains(c) { depth -= 1 }
                if c == separator && depth == 0 {
                    parts.append(current)
                    current = ""
                    previous = c
                    continue
                }
            }
            current.append(c)
            previous = c
        }
        parts.append(current)
        return parts
    }
}
