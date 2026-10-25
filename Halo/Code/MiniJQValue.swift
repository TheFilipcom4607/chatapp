import Foundation

extension MiniJQ {
    /// A JSON value. Objects keep their key order, as jq's do.
    enum Value {
        case null
        case bool(Bool)
        /// `literal` keeps the exact digits of a big integer from the input, which a Double can't hold
        /// (tweet ids and the like), so it comes back out unchanged.
        case number(Double, literal: String? = nil)
        case string(String)
        case array([Value])
        case object(Object)
    }

    struct Object {
        private(set) var keys: [String] = []
        private var storage: [String: Value] = [:]

        init() {}
        init(_ pairs: [(String, Value)]) {
            for (key, value) in pairs { self[key] = value }
        }

        var count: Int { keys.count }
        var isEmpty: Bool { keys.isEmpty }

        subscript(key: String) -> Value? {
            get { storage[key] }
            set {
                if let newValue {
                    if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
                } else if storage.removeValue(forKey: key) != nil {
                    keys.removeAll { $0 == key }
                }
            }
        }

        var entries: [(key: String, value: Value)] { keys.map { ($0, storage[$0]!) } }
        var values: [Value] { keys.map { storage[$0]! } }
        var sortedKeys: [String] { keys.sorted { MiniJQ.compareStrings($0, $1) < 0 } }
    }
}

extension MiniJQ.Value {
    typealias Value = MiniJQ.Value

    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        default: return true
        }
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }

    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// The value as text: strings as they are, everything else as compact JSON (jq's `tostring`).
    var text: String {
        if case .string(let s) = self { return s }
        return json()
    }

    /// Short JSON for error messages, like jq's `string ("abc...")`.
    var brief: String {
        let full = json()
        return full.count > 30 ? String(full.prefix(27)) + "..." : full
    }

    /// `typeName (brief)`, the way jq names a value in its errors.
    var described: String { "\(typeName) (\(brief))" }

    fileprivate var rank: Int {
        switch self {
        case .null: return 0
        case .bool(let b): return b ? 2 : 1
        case .number: return 3
        case .string: return 4
        case .array: return 5
        case .object: return 6
        }
    }

    // MARK: Writing

    func json(indent: Int = 0, tab: Bool = false, sortKeys: Bool = false, ascii: Bool = false) -> String {
        var out = ""
        let unit = tab ? "\t" : (indent > 0 ? String(repeating: " ", count: indent) : nil)
        write(&out, unit: unit, level: 0, sortKeys: sortKeys, ascii: ascii)
        return out
    }

    private func write(_ out: inout String, unit: String?, level: Int, sortKeys: Bool, ascii: Bool) {
        func newline(_ level: Int) {
            guard let unit else { return }
            out += "\n"
            for _ in 0..<level { out += unit }
        }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d, let literal): out += literal ?? MiniJQ.format(d)
        case .string(let s): MiniJQ.quote(s, ascii: ascii, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                newline(level + 1)
                item.write(&out, unit: unit, level: level + 1, sortKeys: sortKeys, ascii: ascii)
            }
            newline(level)
            out += "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{"
            for (n, key) in (sortKeys ? object.sortedKeys : object.keys).enumerated() {
                if n > 0 { out += "," }
                newline(level + 1)
                MiniJQ.quote(key, ascii: ascii, into: &out)
                out += unit == nil ? ":" : ": "
                object[key]!.write(&out, unit: unit, level: level + 1, sortKeys: sortKeys, ascii: ascii)
            }
            newline(level)
            out += "}"
        }
    }
}

extension MiniJQ {
    static func format(_ d: Double) -> String {
        if d.isNaN { return "null" }
        if d.isInfinite { return d < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308" }
        if d == d.rounded(.towardZero), abs(d) < 1e17 { return String(Int64(d)) }
        return "\(d)"
    }

    static func quote(_ s: String, ascii: Bool, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (ascii && scalar.value > 0x7E) {
                    if scalar.value > 0xFFFF {
                        let v = scalar.value - 0x10000
                        out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Bytewise UTF-8 order, which is codepoint order, as jq sorts strings.
    static func compareStrings(_ x: String, _ y: String) -> Int {
        var i = x.utf8.makeIterator(), j = y.utf8.makeIterator()
        while true {
            switch (i.next(), j.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (l?, r?): if l != r { return l < r ? -1 : 1 }
            }
        }
    }

    /// jq's total order: null < false < true < numbers < strings < arrays < objects.
    static func compare(_ a: Value, _ b: Value) -> Int {
        if a.rank != b.rank { return a.rank < b.rank ? -1 : 1 }
        switch (a, b) {
        case let (.number(x, _), .number(y, _)):
            return x < y ? -1 : (x > y ? 1 : 0)
        case let (.string(x), .string(y)):
            return compareStrings(x, y)
        case let (.array(x), .array(y)):
            for (l, r) in zip(x, y) {
                let c = compare(l, r)
                if c != 0 { return c }
            }
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        case let (.object(x), .object(y)):
            let kx = x.sortedKeys, ky = y.sortedKeys
            let c = compare(.array(kx.map(Value.string)), .array(ky.map(Value.string)))
            if c != 0 { return c }
            for k in kx {
                let c = compare(x[k]!, y[k]!)
                if c != 0 { return c }
            }
            return 0
        default:
            return 0
        }
    }

    /// A Double as an Int, when it fits comfortably.
    static func int(_ d: Double) -> Int? {
        guard d.isFinite, abs(d) < 1e15 else { return nil }
        return Int(d.rounded(.down))
    }

    // MARK: - Reading JSON

    /// Reads a stream of JSON values (one document, NDJSON, or several in a row).
    struct Reader {
        private let bytes: [UInt8]
        private var i = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        static func parse(_ text: String) throws -> [Value] {
            var reader = Reader(text)
            return try reader.readAll()
        }

        mutating func readAll() throws -> [Value] {
            var values: [Value] = []
            skipSpace()
            while i < bytes.count {
                values.append(try value(depth: 0))
                skipSpace()
            }
            return values
        }

        private mutating func skipSpace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                case 0xEF where i + 2 < bytes.count && bytes[i + 1] == 0xBB && bytes[i + 2] == 0xBF: i += 3   // BOM
                default: return
                }
            }
        }

        private func fail(_ what: String) -> Failure {
            var line = 1, column = 1
            for b in bytes[..<min(i, bytes.count)] {
                if b == 0x0A { line += 1; column = 1 } else { column += 1 }
            }
            return Failure("\(what) at line \(line), column \(column)")
        }

        private mutating func expect(_ byte: UInt8, _ what: String) throws {
            skipSpace()
            guard i < bytes.count, bytes[i] == byte else { throw fail(what) }
            i += 1
        }

        private mutating func value(depth: Int) throws -> Value {
            guard depth < 1000 else { throw fail("Exceeds depth limit for parsing") }
            skipSpace()
            guard i < bytes.count else { throw fail("Unfinished JSON term") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var object = Object()
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(object) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("Object keys must be strings") }
                    let key = try string()
                    try expect(UInt8(ascii: ":"), "Objects must consist of key:value pairs")
                    object[key] = try value(depth: depth + 1)
                    skipSpace()
                    guard i < bytes.count else { throw fail("Unfinished JSON term") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(object) }
                    throw fail("Expected separator between values")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [Value] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw fail("Unfinished JSON term") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw fail("Expected separator between values")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try number()
            default:
                throw fail("Invalid literal")
            }
        }

        private mutating func word(_ w: String) throws {
            let utf8 = Array(w.utf8)
            guard i + utf8.count <= bytes.count, Array(bytes[i..<(i + utf8.count)]) == utf8 else { throw fail("Invalid literal") }
            i += utf8.count
        }

        private mutating func number() throws -> Value {
            let start = i
            var integer = true
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            skipDigits()
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") { integer = false; i += 1; skipDigits() }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                integer = false
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                skipDigits()
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let d = Double(text) else { throw fail("Invalid numeric literal") }
            return .number(d, literal: integer && MiniJQ.format(d) != text ? text : nil)
        }

        private mutating func skipDigits() {
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
        }

        private mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
                throw fail("Invalid escape")
            }
            i += 4
            return v
        }

        private mutating func string() throws -> String {
            i += 1
            let start = i
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: bytes[start..<(i - 1)], as: UTF8.self)
                }
                if b == UInt8(ascii: "\\") { break }
                i += 1
            }
            var buffer = Array(bytes[start..<i])
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: buffer, as: UTF8.self)
                }
                guard b == UInt8(ascii: "\\") else { buffer.append(b); i += 1; continue }
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "/"), UInt8(ascii: "\\"), UInt8(ascii: "\""): buffer.append(e)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) }
                    }
                    UTF8.encode(Unicode.Scalar(scalar) ?? "\u{FFFD}") { buffer.append($0) }
                default:
                    throw fail("Invalid escape")
                }
            }
            throw fail("Unfinished string")
        }
    }

    // MARK: - Operations on values

    static func elements(_ v: Value) throws -> [Value] {
        switch v {
        case .array(let items): return items
        case .object(let object): return object.values
        case .null: throw Failure("Cannot iterate over null")
        default: throw Failure("Cannot iterate over \(v.described)")
        }
    }

    static func index(_ v: Value, _ key: Value) throws -> Value {
        switch (v, key) {
        case (.null, .string), (.null, .number), (.null, .null), (.null, .object):
            return .null
        case let (.object(object), .string(k)):
            return object[k] ?? .null
        case let (.array(items), .number(d, _)):
            guard var i = int(d) else { return .null }
            if i < 0 { i += items.count }
            return items.indices.contains(i) ? items[i] : .null
        case let (.array, .object(range)), let (.string, .object(range)):
            return try slice(v, range["start"], range["end"])
        case let (.array(items), .array(sub)):
            return .array(indices(of: sub, in: items).map { .number(Double($0)) })
        case (_, .string(let k)):
            throw Failure("Cannot index \(v.typeName) with \"\(k)\"")
        default:
            throw Failure("Cannot index \(v.typeName) with \(key.typeName)")
        }
    }

    static func indices(of sub: [Value], in items: [Value]) -> [Int] {
        guard !sub.isEmpty, sub.count <= items.count else { return [] }
        return (0...(items.count - sub.count)).filter { start in
            sub.indices.allSatisfy { compare(items[start + $0], sub[$0]) == 0 }
        }
    }

    static func sliceBounds(_ from: Value?, _ to: Value?, count: Int) throws -> Range<Int> {
        func bound(_ x: Value?, _ fallback: Int) throws -> Int {
            guard let x, !x.isNull else { return fallback }
            guard case .number(let d, _) = x else { throw Failure("Start and end indices of an array slice must be numbers") }
            guard var n = int(d) else { return d < 0 ? 0 : count }
            if n < 0 { n += count }
            return min(max(n, 0), count)
        }
        let lower = try bound(from, 0)
        return lower..<max(lower, try bound(to, count))
    }

    static func slice(_ v: Value, _ from: Value?, _ to: Value?) throws -> Value {
        switch v {
        case .null: return .null
        case .array(let items):
            return .array(Array(items[try sliceBounds(from, to, count: items.count)]))
        case .string(let s):
            let scalars = Array(s.unicodeScalars)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[try sliceBounds(from, to, count: scalars.count)])
            return .string(String(view))
        default:
            throw Failure("Cannot index \(v.typeName) with object")
        }
    }

    static func getpath(_ v: Value, _ path: [Value]) throws -> Value {
        var current = v
        for key in path {
            if current.isNull { return .null }
            current = try index(current, key)
        }
        return current
    }

    static func setpath(_ v: Value, _ path: ArraySlice<Value>, _ new: Value) throws -> Value {
        guard let key = path.first else { return new }
        let rest = path.dropFirst()
        switch (v, key) {
        case (.object(var object), .string(let k)):
            object[k] = try setpath(object[k] ?? .null, rest, new)
            return .object(object)
        case (.null, .string(let k)):
            var object = Object()
            object[k] = try setpath(.null, rest, new)
            return .object(object)
        case (.array, .number(let d, _)), (.null, .number(let d, _)):
            var items: [Value] = []
            if case .array(let a) = v { items = a }
            guard var i = int(d), i < 1_000_000 else { throw Failure("Array index too large") }
            if i < 0 {
                i += items.count
                guard i >= 0 else { throw Failure("Out of bounds negative array index") }
            }
            while items.count <= i { items.append(.null) }
            items[i] = try setpath(items[i], rest, new)
            return .array(items)
        case (.array, .object(let range)), (.null, .object(let range)):
            var items: [Value] = []
            if case .array(let a) = v { items = a }
            let bounds = try sliceBounds(range["start"], range["end"], count: items.count)
            guard case .array(let replacement) = try setpath(.array(Array(items[bounds])), rest, new) else {
                throw Failure("A slice of an array can only be assigned another array")
            }
            items.replaceSubrange(bounds, with: replacement)
            return .array(items)
        case (_, .string(let k)):
            throw Failure("Cannot index \(v.typeName) with \"\(k)\"")
        default:
            throw Failure("Cannot index \(v.typeName) with \(key.typeName)")
        }
    }

    static func delpaths(_ v: Value, _ paths: [[Value]]) throws -> Value {
        var result = v
        for path in paths.sorted(by: { compare(.array($0), .array($1)) > 0 }) {
            result = try delpath(result, path[...])
        }
        return result
    }

    private static func delpath(_ v: Value, _ path: ArraySlice<Value>) throws -> Value {
        guard let key = path.first else { return .null }
        if v.isNull { return .null }
        let rest = path.dropFirst()
        guard rest.isEmpty else {
            let child = try index(v, key)
            if child.isNull { return v }
            return try setpath(v, [key][...], try delpath(child, rest))
        }
        switch (v, key) {
        case (.object(var object), .string(let k)):
            object[k] = nil
            return .object(object)
        case (.array(var items), .number(let d, _)):
            guard var i = int(d) else { return v }
            if i < 0 { i += items.count }
            if items.indices.contains(i) { items.remove(at: i) }
            return .array(items)
        case (.array(var items), .object(let range)):
            items.removeSubrange(try sliceBounds(range["start"], range["end"], count: items.count))
            return .array(items)
        default:
            throw Failure("Cannot delete field at \(key.typeName) index of \(v.typeName)")
        }
    }

    static func binary(_ op: String, _ l: Value, _ r: Value) throws -> Value {
        switch op {
        case "==": return .bool(compare(l, r) == 0)
        case "!=": return .bool(compare(l, r) != 0)
        case "<": return .bool(compare(l, r) < 0)
        case "<=": return .bool(compare(l, r) <= 0)
        case ">": return .bool(compare(l, r) > 0)
        case ">=": return .bool(compare(l, r) >= 0)
        default: break
        }
        switch (op, l, r) {
        case ("+", .null, _): return r
        case ("+", _, .null): return l
        case let ("+", .number(a, _), .number(b, _)): return .number(a + b)
        case let ("+", .string(a), .string(b)): return .string(a + b)
        case let ("+", .array(a), .array(b)): return .array(a + b)
        case let ("+", .object(a), .object(b)):
            var merged = a
            for (k, v) in b.entries { merged[k] = v }
            return .object(merged)
        case let ("-", .number(a, _), .number(b, _)): return .number(a - b)
        case let ("-", .array(a), .array(b)):
            return .array(a.filter { x in !b.contains { compare(x, $0) == 0 } })
        case let ("*", .number(a, _), .number(b, _)): return .number(a * b)
        case let ("*", .string(s), .number(n, _)), let ("*", .number(n, _), .string(s)):
            guard let count = int(n), count > 0 else { return .null }
            guard s.utf8.count * count < 50_000_000 else { throw Failure("Repeat string result too long") }
            return .string(String(repeating: s, count: count))
        case let ("*", .object(a), .object(b)): return .object(deepMerge(a, b))
        case let ("/", .number(a, _), .number(b, _)):
            guard b != 0 else { throw Failure("\(l.described) and \(r.described) cannot be divided because the divisor is zero") }
            return .number(a / b)
        case let ("/", .string(a), .string(b)): return .array(split(a, by: b).map(Value.string))
        case let ("%", .number(a, _), .number(b, _)):
            guard let x = int(a.rounded(.towardZero)), let y = int(b.rounded(.towardZero)) else { return .number(fmod(a, b)) }
            guard y != 0 else { throw Failure("\(l.described) and \(r.described) cannot be divided because the divisor is zero") }
            return .number(Double(x % y))
        default: break
        }
        let verb = ["+": "added", "-": "subtracted", "*": "multiplied", "/": "divided", "%": "divided"][op] ?? "combined"
        throw Failure("\(l.described) and \(r.described) cannot be \(verb)")
    }

    private static func deepMerge(_ a: Object, _ b: Object) -> Object {
        var merged = a
        for (k, v) in b.entries {
            if case .object(let x)? = merged[k], case .object(let y) = v { merged[k] = .object(deepMerge(x, y)) } else { merged[k] = v }
        }
        return merged
    }

    /// Literal split; an empty separator splits into characters.
    static func split(_ s: String, by separator: String) -> [String] {
        if s.isEmpty { return [] }
        if separator.isEmpty { return s.map(String.init) }
        return s.components(separatedBy: separator)
    }

    static func contains(_ a: Value, _ b: Value) throws -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return try y.entries.allSatisfy { key, value in
                guard let mine = x[key] else { return false }
                return try contains(mine, value)
            }
        case let (.array(x), .array(y)):
            return try y.allSatisfy { wanted in try x.contains { try contains($0, wanted) } }
        case let (.string(x), .string(y)):
            return y.isEmpty || x.range(of: y) != nil
        default:
            guard a.typeName == b.typeName else {
                throw Failure("\(a.described) and \(b.described) cannot have their containment checked")
            }
            return compare(a, b) == 0
        }
    }

    /// `@text`, `@json`, `@csv`, `@tsv`, `@html`, `@uri`, `@sh`, `@base64`, `@base64d`.
    static func format(_ name: String, _ v: Value) throws -> String {
        switch name {
        case "text": return v.text
        case "json": return v.json()
        case "html":
            return v.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        case "uri":
            var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            allowed.insert(charactersIn: "-_.~")
            return v.text.addingPercentEncoding(withAllowedCharacters: allowed) ?? v.text
        case "csv", "tsv":
            guard case .array(let items) = v else { throw Failure("\(v.described) cannot be \(name)-formatted, only an array can be") }
            return try items.map { item -> String in
                switch item {
                case .number(let d, let literal): return literal ?? format(d)
                case .bool(let b): return b ? "true" : "false"
                case .null: return ""
                case .string(let s):
                    if name == "csv" { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
                        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                default:
                    throw Failure("\(item.described) is not valid in a csv row")
                }
            }.joined(separator: name == "csv" ? "," : "\t")
        case "sh":
            func quote(_ x: Value) throws -> String {
                switch x {
                case .string(let s): return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
                case .array, .object: throw Failure("\(x.described) can not be escaped for shell")
                default: return x.text
                }
            }
            if case .array(let items) = v { return try items.map(quote).joined(separator: " ") }
            return try quote(v)
        case "base64":
            return Data(v.text.utf8).base64EncodedString()
        case "base64d":
            let cleaned = v.text.filter { !$0.isWhitespace }
            let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
            guard let data = Data(base64Encoded: padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else {
                throw Failure("\(v.described) is not valid base64 data")
            }
            return String(decoding: data, as: UTF8.self)
        default:
            throw Failure("\(name) is not a valid format")
        }
    }
}
