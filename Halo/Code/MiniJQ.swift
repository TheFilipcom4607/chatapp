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
        // Binary operators, loosest first: `//`, `or`, `and`, comparisons, `+`.
        let alternatives = splitTop(t, "//")
        if alternatives.count > 1 {
            for alt in alternatives.dropLast() {
                let values = ((try? evaluate(alt, value)) ?? []).filter(isTruthy)
                if !values.isEmpty { return values }
            }
            return try evaluate(alternatives.last!, value)
        }
        for word in [" or ", " and "] {
            let parts = splitTop(t, word)
            guard parts.count > 1 else { continue }
            let truths = try parts.map { try evaluate($0, value).contains(where: isTruthy) }
            return [word == " or " ? truths.contains(true) : !truths.contains(false)]
        }
        for op in ["==", "!=", "<=", ">=", "<", ">"] {
            let parts = splitTop(t, op)
            guard parts.count == 2 else { continue }
            let l = try evaluate(parts[0], value).first ?? NSNull(), r = try evaluate(parts[1], value).first ?? NSNull()
            let c = try compare(l, r)
            switch op {
            case "==": return [c == 0]
            case "!=": return [c != 0]
            case "<=": return [c <= 0]
            case ">=": return [c >= 0]
            case "<": return [c < 0]
            default: return [c > 0]
            }
        }
        let sums = splitTop(t, "+")
        if sums.count > 1 {
            var total: Any = try evaluate(sums[0], value).first ?? NSNull()
            for part in sums.dropFirst() { total = try add(total, try evaluate(part, value).first ?? NSNull()) }
            return [total]
        }
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
        if let (name, arg) = call(t) { return try function(name, arg, value) }
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
        case "not": return [!isTruthy(value)]
        case "add": return [try elements(value, name: "add").reduce(NSNull() as Any) { try add($0, $1) }]
        case "sort", "unique":
            var items = try elements(value, name: t)
            items.sort { ((try? compare($0, $1)) ?? 0) < 0 }
            if t == "unique" { items = items.enumerated().filter { $0.offset == 0 || (try? compare(items[$0.offset - 1], $0.element)) != 0 }.map(\.element) }
            return [items]
        case "reverse": return [Array(try elements(value, name: "reverse").reversed())]
        case "min", "max":
            let items = try elements(value, name: t).sorted { ((try? compare($0, $1)) ?? 0) < 0 }
            return [(t == "min" ? items.first : items.last) ?? NSNull()]
        case "to_entries":
            guard let dict = value as? [String: Any] else { throw Failure(message: "\(typeName(value)) has no keys") }
            return [dict.keys.sorted().map { ["key": $0, "value": dict[$0]!] as [String: Any] }]
        case "tonumber":
            if value is NSNumber, typeName(value) == "number" { return [value] }
            guard let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) else { throw Failure(message: "cannot parse \(typeName(value)) as a number") }
            return [d]
        case "ascii_downcase", "ascii_upcase":
            guard let s = value as? String else { throw Failure(message: "\(t) needs a string, not \(typeName(value))") }
            return [t == "ascii_downcase" ? s.lowercased() : s.uppercased()]
        case "@text": return [try (value as? String) ?? encode(value, compact: true)]
        case "@json": return [try encode(value, compact: true)]
        case "@csv", "@tsv":
            guard let row = value as? [Any] else { throw Failure(message: "\(typeName(value)) cannot be \(t)-formatted, only an array can be") }
            return [try row.map { cell -> String in
                if cell is NSNull { return "" }
                guard let s = cell as? String else { return try encode(cell, compact: true) }
                if t == "@csv" { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
            }.joined(separator: t == "@csv" ? "," : "\t")]
        default:
            throw Failure(message: "unsupported filter `\(t)`. Supported: paths, |, commas, //, and/or, comparisons, +, [..], {..}, map, select, test, join, split, has, contains, startswith, endswith, sort_by, keys, length, type, first, last, add, sort, unique, min, max, to_entries, tonumber, @csv, @tsv.")
        }
    }

    private static func isTruthy(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if typeName(value) == "boolean" { return (value as? Bool) ?? true }
        return true
    }

    /// jq's order: null < false < true < numbers < strings < arrays < objects.
    private static func compare(_ a: Any, _ b: Any) throws -> Int {
        let rank = ["null": 0, "boolean": 1, "number": 2, "string": 3, "array": 4, "object": 5]
        let ta = typeName(a), tb = typeName(b)
        if ta != tb { return (rank[ta] ?? 6) < (rank[tb] ?? 6) ? -1 : 1 }
        switch ta {
        case "boolean":
            let x = (a as? Bool) ?? false, y = (b as? Bool) ?? false
            return x == y ? 0 : (x ? 1 : -1)
        case "number":
            let x = (a as? NSNumber)?.doubleValue ?? 0, y = (b as? NSNumber)?.doubleValue ?? 0
            return x < y ? -1 : (x > y ? 1 : 0)
        case "string":
            let x = a as? String ?? "", y = b as? String ?? ""
            return x < y ? -1 : (x > y ? 1 : 0)
        default:
            let x = try encode(a, compact: true), y = try encode(b, compact: true)
            return x < y ? -1 : (x > y ? 1 : 0)
        }
    }

    private static func add(_ a: Any, _ b: Any) throws -> Any {
        if a is NSNull { return b }
        if b is NSNull { return a }
        switch (a, b) {
        case let (x as String, y as String): return x + y
        case let (x as [Any], y as [Any]): return x + y
        case let (x as [String: Any], y as [String: Any]): return x.merging(y) { $1 }
        default:
            if typeName(a) == "number", typeName(b) == "number", let x = a as? NSNumber, let y = b as? NSNumber { return x.doubleValue + y.doubleValue }
            throw Failure(message: "\(typeName(a)) and \(typeName(b)) cannot be added")
        }
    }

    /// `name(arg)` when the whole term is one call.
    private static func call(_ t: String) -> (String, String)? {
        guard t.hasSuffix(")"), let open = t.firstIndex(of: "("), open != t.startIndex,
              t[..<open].allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        // The paren after the name must be the one that closes at the end.
        var depth = 0
        var inString = false
        var previous: Character = " "
        for (offset, c) in t[open...].enumerated() {
            if c == "\"" && previous != "\\" { inString.toggle() }
            previous = c
            if inString { continue }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 && offset != t[open...].count - 1 { return nil }
            }
        }
        return (String(t[..<open]), String(t[t.index(after: open)...].dropLast()))
    }

    private static func function(_ name: String, _ arg: String, _ value: Any) throws -> [Any] {
        func argument() throws -> Any { try evaluate(arg, value).first ?? NSNull() }
        func string(_ what: String) throws -> String {
            guard let s = value as? String else { throw Failure(message: "\(what) needs a string input, not \(typeName(value))") }
            return s
        }
        switch name {
        case "map": return [try elements(value, name: "map").flatMap { try evaluate(arg, $0) }]
        case "select": return try evaluate(arg, value).contains(where: isTruthy) ? [value] : []
        case "sort_by":
            let keyed = try elements(value, name: "sort_by").map { (key: try evaluate(arg, $0).first ?? NSNull(), item: $0) }
            return [keyed.sorted { ((try? compare($0.key, $1.key)) ?? 0) < 0 }.map(\.item)]
        case "has":
            let key = try argument()
            if let dict = value as? [String: Any], let k = key as? String { return [dict[k] != nil] }
            if let array = value as? [Any], let n = key as? NSNumber { return [n.intValue >= 0 && n.intValue < array.count] }
            throw Failure(message: "cannot check whether \(typeName(value)) has a \(typeName(key)) key")
        case "join":
            let separator = try argument() as? String ?? ""
            return [try elements(value, name: "join").map { $0 is NSNull ? "" : try ($0 as? String) ?? encode($0, compact: true) }.joined(separator: separator)]
        case "split":
            let separator = try argument() as? String ?? ""
            return [try string("split").components(separatedBy: separator)]
        case "test":
            let pattern = try argument() as? String ?? ""
            let s = try string("test")
            guard let re = try? NSRegularExpression(pattern: pattern) else { throw Failure(message: "\(pattern) is not a valid regex") }
            return [re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil]
        case "startswith", "endswith", "ltrimstr", "rtrimstr":
            let affix = try argument() as? String ?? ""
            guard let s = value as? String else {
                if name.hasSuffix("trimstr") { return [value] }
                throw Failure(message: "\(name) needs a string input")
            }
            switch name {
            case "startswith": return [s.hasPrefix(affix)]
            case "endswith": return [s.hasSuffix(affix)]
            case "ltrimstr": return [s.hasPrefix(affix) ? String(s.dropFirst(affix.count)) : s]
            default: return [s.hasSuffix(affix) ? String(s.dropLast(affix.count)) : s]
            }
        case "contains":
            let needle = try argument()
            if let s = value as? String, let n = needle as? String { return [n.isEmpty || s.contains(n)] }
            if let array = value as? [Any] {
                let wanted = needle as? [Any] ?? [needle]
                return [wanted.allSatisfy { w in array.contains { (try? compare($0, w)) == 0 } }]
            }
            return [(try? compare(value, needle)) == 0]
        default:
            throw Failure(message: "unsupported function `\(name)(…)`")
        }
    }

    /// Splits on a multi-character operator outside brackets, parens, braces and strings.
    private static func splitTop(_ text: String, _ separator: String) -> [String] {
        let chars = Array(text), sep = Array(separator)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            if !inString {
                if "([{".contains(c) { depth += 1 }
                if ")]}".contains(c) { depth -= 1 }
                if depth == 0, i + sep.count <= chars.count, Array(chars[i..<(i + sep.count)]) == sep,
                   // `<` and `>` must not be half of `<=` / `>=`, and `=` of `==`.
                   !(sep.count == 1 && i + 1 < chars.count && chars[i + 1] == "="),
                   !(sep == ["/", "/"] && i + 2 < chars.count && chars[i + 2] == "=") {
                    parts.append(current)
                    current = ""
                    i += sep.count
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        parts.append(current)
        return parts
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
