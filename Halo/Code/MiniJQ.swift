import Foundation

/// jq for the `shell` tool. It covers the language as people write it: paths, `|`, `,`, `//`,
/// arithmetic and comparisons, `and`/`or`, `if`, `as` bindings with destructuring, `reduce`,
/// `foreach`, `try`/`catch`, `def`, string interpolation, `@formats`, assignment (`=`, `|=`, `+=`…),
/// and the everyday builtins. Objects keep their key order. `label`/`break`, modules and streaming
/// aren't supported.
enum MiniJQ {
    struct Failure: LocalizedError {
        let value: Value
        init(_ message: String) { value = .string(message) }
        init(value: Value) { self.value = value }
        var errorDescription: String? {
            if case .string(let s) = value { return s }
            return "\(value.json()) (not a string)"
        }
    }

    struct Output {
        var stdout = ""
        var stderr = ""
        var status: Int32 = 0
    }

    /// `jq [options] filter [files]`. `stdin` is only read when there are no files; `readFile`
    /// reads the shell's scratch files.
    static func main(_ args: [String], stdin: () -> String, environment: [String: String], readFile: (String) -> String?) -> Output {
        var raw = false, join = false, compact = false, nullInput = false, slurp = false, rawInput = false
        var exitStatus = false, sortKeys = false, ascii = false, tab = false, indent = 2
        var named = Object()
        var positional: [Value] = []
        var filter: String?
        var files: [String] = []
        var restArePositional: Bool?   // true: --jsonargs
        var i = 0

        func usage(_ message: String) -> Output { Output(stderr: "jq: \(message)\n", status: 2) }
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }

        while i < args.count {
            let a = args[i]
            defer { i += 1 }
            if let json = restArePositional, filter != nil, !a.hasPrefix("-") || a == "-" {
                if json {
                    guard let v = try? Reader.parse(a).first else { return usage("Invalid JSON text passed to --jsonargs") }
                    positional.append(v)
                } else {
                    positional.append(.string(a))
                }
                continue
            }
            switch a {
            case "--raw-output": raw = true
            case "--join-output": raw = true; join = true
            case "--compact-output": compact = true
            case "--null-input": nullInput = true
            case "--slurp": slurp = true
            case "--raw-input": rawInput = true
            case "--exit-status": exitStatus = true
            case "--sort-keys": sortKeys = true
            case "--ascii-output": ascii = true
            case "--tab": tab = true
            case "--indent":
                guard let n = next().flatMap({ Int($0) }), (0...7).contains(n) else { return usage("--indent takes a number from 0 to 7") }
                indent = n
            case "--monochrome-output", "--color-output", "--unbuffered", "--stream-errors", "--seq": break
            case "--arg":
                guard let name = next(), let value = next() else { return usage("--arg takes two parameters (e.g. --arg varname value)") }
                named[name] = .string(value)
            case "--argjson":
                guard let name = next(), let text = next() else { return usage("--argjson takes two parameters (e.g. --argjson varname text)") }
                guard let values = try? Reader.parse(text), values.count == 1 else { return usage("Invalid JSON text passed to --argjson") }
                named[name] = values[0]
            case "--slurpfile", "--rawfile":
                guard let name = next(), let path = next() else { return usage("\(a) takes two parameters (e.g. \(a) varname filename)") }
                guard let text = readFile(path) else { return usage("error: Could not open \(path): No such file or directory") }
                if a == "--rawfile" {
                    named[name] = .string(text)
                } else {
                    guard let values = try? Reader.parse(text) else { return usage("Invalid JSON in \(path)") }
                    named[name] = .array(values)
                }
            case "--args": restArePositional = false
            case "--jsonargs": restArePositional = true
            case "-f", "--from-file":
                guard let path = next() else { return usage("-f takes a file name") }
                guard let text = readFile(path) else { return usage("error: Could not open \(path): No such file or directory") }
                if let filter { files.append(filter) }
                filter = text
            case "--":
                while let rest = next() {
                    if filter == nil { filter = rest } else if restArePositional != nil { positional.append(.string(rest)) } else { files.append(rest) }
                }
            default:
                if a.hasPrefix("--") { return usage("Unknown option: \(a)") }
                if a.hasPrefix("-") && a.count > 1 {
                    for c in a.dropFirst() {
                        switch c {
                        case "r": raw = true
                        case "j": raw = true; join = true
                        case "c": compact = true
                        case "n": nullInput = true
                        case "s": slurp = true
                        case "R": rawInput = true
                        case "e": exitStatus = true
                        case "S": sortKeys = true
                        case "a": ascii = true
                        case "M", "C": break
                        default: return usage("Unknown option: -\(c)")
                        }
                    }
                } else if filter == nil {
                    filter = a
                } else {
                    files.append(a)
                }
            }
        }

        let program: Expr
        do {
            var parser = Parser(tokens: try lex(filter ?? "."))
            program = try parser.parseProgram()
        } catch {
            return Output(stderr: "jq: error: \(error.localizedDescription)\njq: 1 compile error\n", status: 3)
        }

        var text: String
        if files.isEmpty {
            text = stdin()
        } else {
            text = ""
            for path in files {
                guard let content = readFile(path) else {
                    return Output(stderr: "jq: error: Could not open \(path): No such file or directory\n", status: 2)
                }
                text += content
            }
        }

        var inputs: [Value]
        if rawInput {
            inputs = slurp ? [.string(text)] : lines(text).map { .string($0) }
        } else {
            do {
                inputs = try Reader.parse(text)
            } catch {
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).replacingOccurrences(of: "\n", with: " ")
                return Output(stderr: "jq: parse error: \(error.localizedDescription) (the input isn't JSON; it starts with: \(preview))\n", status: 2)
            }
            if slurp { inputs = [.array(inputs)] }
        }

        var env = Object()
        for (k, v) in environment.sorted(by: { $0.key < $1.key }) { env[k] = .string(v) }
        var scope = Scope()
        scope.vars["ENV"] = .object(env)
        scope.vars["__prog_args"] = .array(positional)
        scope.vars["ARGS"] = .object(Object([("positional", .array(positional)), ("named", .object(named))]))
        for (k, v) in named.entries { scope.vars[k] = v }

        let evaluator = Evaluator(inputs: inputs)
        var output = Output()
        var outputSize = 0
        var last: Value?
        var produced = false
        let tooLarge = Failure("output is too large; narrow it down with select, limit or paths")

        func run(_ input: Value) {
            do {
                try evaluator.eval(program, input, scope) { value in
                    produced = true
                    last = value
                    var piece: String
                    if raw, case .string(let s) = value { piece = s } else {
                        piece = value.json(indent: compact ? 0 : indent, tab: tab && !compact, sortKeys: sortKeys, ascii: ascii)
                    }
                    if !join { piece += "\n" }
                    outputSize += piece.utf8.count
                    if outputSize > 32 << 20 { throw tooLarge }
                    output.stdout += piece
                }
            } catch let failure as Failure {
                output.stderr += "jq: error (at <stdin>:\(evaluator.consumed)): \(failure.localizedDescription)\n"
                output.status = 5
            } catch {
                output.stderr += "jq: error: \(error.localizedDescription)\n"
                output.status = 5
            }
        }

        if nullInput {
            run(.null)
        } else {
            while let input = evaluator.nextInput() {
                run(input)
                if outputSize > 32 << 20 { break }
            }
        }
        if exitStatus && output.status == 0 {
            output.status = !produced ? 4 : (last?.isTruthy == true ? 0 : 1)
        }
        return output
    }

    static func lines(_ text: String) -> [String] {
        var parts = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { slice -> String in
            var s = String(String.UnicodeScalarView(slice))
            if s.unicodeScalars.last == "\r" { s.unicodeScalars.removeLast() }
            return s
        }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    // MARK: - Lexer

    fileprivate enum Token: Equatable {
        case dot, dotdot
        case field(String)
        case ident(String)
        case variable(String)
        case format(String)
        case number(Double)
        case string([StringPiece])
        case op(String)

        var description: String {
            switch self {
            case .dot: return "'.'"
            case .dotdot: return "'..'"
            case .field(let n): return "'.\(n)'"
            case .ident(let n): return "'\(n)'"
            case .variable(let n): return "'$\(n)'"
            case .format(let n): return "'@\(n)'"
            case .number(let d): return "'\(MiniJQ.format(d))'"
            case .string: return "string"
            case .op(let o): return "'\(o)'"
            }
        }
    }

    fileprivate enum StringPiece: Equatable {
        case text(String)
        case code(String)
    }

    private static func isIdentStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
    private static func isIdent(_ c: Character) -> Bool { isIdentStart(c) || (c.isASCII && c.isNumber) }

    fileprivate static func lex(_ source: String) throws -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0

        func ident(_ j: inout Int) -> String {
            var name = ""
            while j < chars.count {
                if isIdent(chars[j]) {
                    name.append(chars[j])
                    j += 1
                } else if chars[j] == ":", j + 2 < chars.count, chars[j + 1] == ":", isIdentStart(chars[j + 2]) {
                    name += "::"
                    j += 2
                } else {
                    break
                }
            }
            return name
        }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "#" {
                while i < chars.count, !chars[i].isNewline { i += 1 }
                continue
            }
            if c == "\"" {
                tokens.append(.string(try lexString(chars, &i)))
                continue
            }
            if c == "." {
                if i + 1 < chars.count, chars[i + 1] == "." { tokens.append(.dotdot); i += 2; continue }
                if i + 1 < chars.count, isIdentStart(chars[i + 1]) {
                    i += 1
                    tokens.append(.field(ident(&i)))
                    continue
                }
                tokens.append(.dot)
                i += 1
                continue
            }
            if c == "$" || c == "@" {
                var j = i + 1
                let name = ident(&j)
                guard !name.isEmpty else { throw Failure("syntax error: unexpected '\(c)'") }
                tokens.append(c == "$" ? .variable(name) : .format(name))
                i = j
                continue
            }
            if c.isASCII && c.isNumber {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isNumber || chars[j] == "." { j += 1 }
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isASCII, chars[k].isNumber {
                        j = k
                        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                    }
                }
                guard let d = Double(String(chars[i..<j])) else { throw Failure("syntax error: bad number \(String(chars[i..<j]))") }
                tokens.append(.number(d))
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i
                tokens.append(.ident(ident(&j)))
                i = j
                continue
            }
            var matched = false
            for op in ["//=", "|=", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "//"] {
                let n = op.count
                if i + n <= chars.count, String(chars[i..<(i + n)]) == op {
                    tokens.append(.op(op))
                    i += n
                    matched = true
                    break
                }
            }
            if matched { continue }
            if "|,()[]{}:;?<>+-*/%=".contains(c) {
                tokens.append(.op(String(c)))
                i += 1
                continue
            }
            if c == "!" { throw Failure("syntax error: unexpected '!' (jq uses `not` and `!=`)") }
            throw Failure("syntax error: unexpected '\(c)'")
        }
        return tokens
    }

    /// Reads a string literal starting at the quote at `i`, leaving `i` after the closing quote.
    private static func lexString(_ chars: [Character], _ i: inout Int) throws -> [StringPiece] {
        var pieces: [StringPiece] = []
        var text = ""
        i += 1
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                i += 1
                if !text.isEmpty || pieces.isEmpty { pieces.append(.text(text)) }
                return pieces
            }
            guard c == "\\" else { text.append(c); i += 1; continue }
            guard i + 1 < chars.count else { break }
            let e = chars[i + 1]
            i += 2
            switch e {
            case "n": text += "\n"
            case "t": text += "\t"
            case "r": text += "\r"
            case "b": text += "\u{8}"
            case "f": text += "\u{C}"
            case "\"", "\\", "/": text.append(e)
            case "u":
                guard i + 4 <= chars.count, var scalar = UInt32(String(chars[i..<(i + 4)]), radix: 16) else {
                    throw Failure("syntax error: invalid \\u escape in string")
                }
                i += 4
                if (0xD800..<0xDC00).contains(scalar), i + 6 <= chars.count, chars[i] == "\\", chars[i + 1] == "u",
                   let low = UInt32(String(chars[(i + 2)..<(i + 6)]), radix: 16), (0xDC00..<0xE000).contains(low) {
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                text.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
            case "(":
                var depth = 1
                var j = i
                while j < chars.count {
                    if chars[j] == "\"" {
                        var k = j
                        _ = try lexString(chars, &k)
                        j = k
                        continue
                    }
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                guard j < chars.count else { throw Failure("syntax error: unterminated \\( in string") }
                if !text.isEmpty { pieces.append(.text(text)); text = "" }
                pieces.append(.code(String(chars[i..<j])))
                i = j + 1
            default:
                throw Failure("syntax error: invalid escape \\\(e) in string")
            }
        }
        throw Failure("syntax error: unterminated string")
    }

    // MARK: - Syntax tree

    fileprivate indirect enum Expr {
        case identity
        case literal(Value)
        case string([Piece], format: String?)
        case format(String)
        case index(Expr, Expr)
        case slice(Expr, Expr?, Expr?)
        case iterate(Expr)
        case attempt(Expr, Expr?)
        case array(Expr?)
        case object([(Expr, Expr)])
        case negate(Expr)
        case pipe(Expr, Expr)
        case comma(Expr, Expr)
        case alternative(Expr, Expr)
        case and(Expr, Expr)
        case or(Expr, Expr)
        case binary(String, Expr, Expr)
        case assign(String, Expr, Expr)
        case variable(String)
        case bind(Expr, Pattern, Expr)
        case cond([(Expr, Expr)], Expr?)
        case reduce(Expr, Pattern, Expr, Expr)
        case foreach(Expr, Pattern, Expr, Expr, Expr?)
        case define(String, [String], Expr, Expr)
        case call(String, [Expr])
    }

    fileprivate enum Piece {
        case text(String)
        case expr(Expr)
    }

    fileprivate indirect enum Pattern {
        case variable(String)
        case array([Pattern])
        case object([(key: Expr, variable: String?, pattern: Pattern?)])
    }

    // MARK: - Parser

    /// Precedence, loosest first, as in jq: `|`, `,`, `//`, assignment, `or`, `and`, comparison,
    /// `+ -`, `* / %`, then postfix terms.
    fileprivate struct Parser {
        var tokens: [Token]
        var p = 0

        var current: Token? { p < tokens.count ? tokens[p] : nil }
        func peek(_ n: Int) -> Token? { p + n < tokens.count ? tokens[p + n] : nil }
        func isOp(_ s: String) -> Bool { current == .op(s) }
        func isKeyword(_ s: String) -> Bool { current == .ident(s) }

        mutating func consumeOp(_ s: String) -> Bool {
            guard isOp(s) else { return false }
            p += 1
            return true
        }
        mutating func expectOp(_ s: String) throws {
            guard consumeOp(s) else { throw unexpected(expecting: "'\(s)'") }
        }
        mutating func expectKeyword(_ s: String) throws {
            guard isKeyword(s) else { throw unexpected(expecting: "'\(s)'") }
            p += 1
        }
        func unexpected(expecting: String? = nil) -> Failure {
            let found = current?.description ?? "end of filter"
            return Failure("syntax error: unexpected \(found)" + (expecting.map { ", expecting \($0)" } ?? ""))
        }

        mutating func parseProgram() throws -> Expr {
            if tokens.isEmpty { return .identity }
            let e = try pipe()
            guard current == nil else { throw unexpected() }
            return e
        }

        mutating func pipe() throws -> Expr {
            if isKeyword("def") { return try definition() }
            let lhs = try comma()
            if consumeOp("|") { return .pipe(lhs, try pipe()) }
            return lhs
        }

        /// Object values: a pipe without top-level commas.
        mutating func pipeNoComma() throws -> Expr {
            let lhs = try alternative()
            if consumeOp("|") { return .pipe(lhs, try pipeNoComma()) }
            return lhs
        }

        mutating func comma() throws -> Expr {
            var e = try alternative()
            while consumeOp(",") { e = .comma(e, try alternative()) }
            return e
        }

        mutating func alternative() throws -> Expr {
            let lhs = try assignment()
            if consumeOp("//") { return .alternative(lhs, try alternative()) }
            return lhs
        }

        mutating func assignment() throws -> Expr {
            let lhs = try or()
            if case .op(let op)? = current, ["=", "|=", "+=", "-=", "*=", "/=", "%=", "//="].contains(op) {
                p += 1
                return .assign(op, lhs, try or())
            }
            return lhs
        }

        mutating func or() throws -> Expr {
            var e = try and()
            while isKeyword("or") { p += 1; e = .or(e, try and()) }
            return e
        }

        mutating func and() throws -> Expr {
            var e = try comparison()
            while isKeyword("and") { p += 1; e = .and(e, try comparison()) }
            return e
        }

        mutating func comparison() throws -> Expr {
            let lhs = try additive()
            if case .op(let op)? = current, ["==", "!=", "<", "<=", ">", ">="].contains(op) {
                p += 1
                return .binary(op, lhs, try additive())
            }
            return lhs
        }

        mutating func additive() throws -> Expr {
            var e = try multiplicative()
            while case .op(let op)? = current, op == "+" || op == "-" {
                p += 1
                e = .binary(op, e, try multiplicative())
            }
            return e
        }

        mutating func multiplicative() throws -> Expr {
            var e = try unary()
            while case .op(let op)? = current, op == "*" || op == "/" || op == "%" {
                p += 1
                e = .binary(op, e, try unary())
            }
            return e
        }

        mutating func unary() throws -> Expr {
            if consumeOp("-") { return .negate(try unary()) }
            return try postfix()
        }

        mutating func postfix(allowBinding: Bool = true) throws -> Expr {
            var e = try primary()
            loop: while let token = current {
                switch token {
                case .field(let name):
                    p += 1
                    e = .index(e, .literal(.string(name)))
                case .dot:
                    if case .string(let pieces)? = peek(1) {
                        p += 2
                        e = .index(e, try stringExpr(pieces, format: nil))
                    } else if peek(1) == .op("[") {
                        p += 1
                    } else {
                        break loop
                    }
                case .op("["):
                    p += 1
                    e = try bracket(e)
                case .op("?"):
                    p += 1
                    e = .attempt(e, nil)
                default:
                    break loop
                }
            }
            if allowBinding, isKeyword("as") {
                p += 1
                let pattern = try self.pattern()
                try expectOp("|")
                return .bind(e, pattern, try pipe())
            }
            return e
        }

        mutating func bracket(_ base: Expr) throws -> Expr {
            if consumeOp("]") { return .iterate(base) }
            if consumeOp(":") {
                let to = try pipe()
                try expectOp("]")
                return .slice(base, nil, to)
            }
            let from = try pipe()
            if consumeOp(":") {
                if consumeOp("]") { return .slice(base, from, nil) }
                let to = try pipe()
                try expectOp("]")
                return .slice(base, from, to)
            }
            try expectOp("]")
            return .index(base, from)
        }

        mutating func primary() throws -> Expr {
            guard let token = current else { throw unexpected() }
            p += 1
            switch token {
            case .number(let d):
                return .literal(.number(d))
            case .string(let pieces):
                return try stringExpr(pieces, format: nil)
            case .format(let name):
                if case .string(let pieces)? = current {
                    p += 1
                    return try stringExpr(pieces, format: name)
                }
                return .format(name)
            case .dot:
                if case .string(let pieces)? = current {
                    p += 1
                    return .index(.identity, try stringExpr(pieces, format: nil))
                }
                return .identity
            case .dotdot:
                return .call("recurse", [])
            case .field(let name):
                return .index(.identity, .literal(.string(name)))
            case .variable(let name):
                return .variable(name)
            case .op("("):
                let e = try pipe()
                try expectOp(")")
                return e
            case .op("["):
                if consumeOp("]") { return .array(nil) }
                let e = try pipe()
                try expectOp("]")
                return .array(e)
            case .op("{"):
                return try object()
            case .op("-"):
                return .negate(try postfix())
            case .ident(let name):
                switch name {
                case "if": return try conditional()
                case "try":
                    let body = try postfix(allowBinding: false)
                    var handler: Expr?
                    if isKeyword("catch") {
                        p += 1
                        handler = try postfix(allowBinding: false)
                    }
                    return .attempt(body, handler ?? .call("empty", []))
                case "reduce":
                    let source = try postfix(allowBinding: false)
                    try expectKeyword("as")
                    let pattern = try self.pattern()
                    try expectOp("(")
                    let initial = try pipe()
                    try expectOp(";")
                    let update = try pipe()
                    try expectOp(")")
                    return .reduce(source, pattern, initial, update)
                case "foreach":
                    let source = try postfix(allowBinding: false)
                    try expectKeyword("as")
                    let pattern = try self.pattern()
                    try expectOp("(")
                    let initial = try pipe()
                    try expectOp(";")
                    let update = try pipe()
                    var extract: Expr?
                    if consumeOp(";") { extract = try pipe() }
                    try expectOp(")")
                    return .foreach(source, pattern, initial, update, extract)
                case "def":
                    p -= 1
                    return try definition()
                case "label", "import", "include":
                    throw Failure("\(name) isn't supported here")
                case "then", "elif", "else", "end", "as", "catch", "and", "or":
                    p -= 1
                    throw unexpected()
                case "null" where !isOp("("): return .literal(.null)
                case "true" where !isOp("("): return .literal(.bool(true))
                case "false" where !isOp("("): return .literal(.bool(false))
                default:
                    var args: [Expr] = []
                    if consumeOp("(") {
                        repeat { args.append(try pipe()) } while consumeOp(";")
                        try expectOp(")")
                    }
                    return .call(name, args)
                }
            default:
                p -= 1
                throw unexpected()
            }
        }

        mutating func conditional() throws -> Expr {
            var branches: [(Expr, Expr)] = []
            while true {
                let test = try pipe()
                try expectKeyword("then")
                branches.append((test, try pipe()))
                guard isKeyword("elif") else { break }
                p += 1
            }
            var otherwise: Expr?
            if isKeyword("else") {
                p += 1
                otherwise = try pipe()
            }
            try expectKeyword("end")
            return .cond(branches, otherwise)
        }

        mutating func object() throws -> Expr {
            var entries: [(Expr, Expr)] = []
            if consumeOp("}") { return .object([]) }
            repeat {
                if isOp("}") { break }
                guard let token = current else { throw unexpected() }
                p += 1
                let key: Expr
                var value: Expr?
                switch token {
                case .ident(let name):
                    key = .literal(.string(name))
                case .variable(let name):
                    key = .literal(.string(name))
                    value = .variable(name)
                case .string(let pieces):
                    key = try stringExpr(pieces, format: nil)
                case .format(let name):
                    if case .string(let pieces)? = current {
                        p += 1
                        key = try stringExpr(pieces, format: name)
                    } else {
                        key = .format(name)
                    }
                case .number(let d):
                    key = .literal(.number(d))
                case .op("("):
                    key = try pipe()
                    try expectOp(")")
                    guard isOp(":") else { throw unexpected(expecting: "':'") }
                default:
                    p -= 1
                    throw unexpected(expecting: "an object key")
                }
                if consumeOp(":") {
                    value = try pipeNoComma()
                }
                entries.append((key, value ?? .index(.identity, key)))
            } while consumeOp(",")
            try expectOp("}")
            return .object(entries)
        }

        mutating func pattern() throws -> Pattern {
            guard let token = current else { throw unexpected() }
            p += 1
            switch token {
            case .variable(let name):
                return .variable(name)
            case .op("["):
                var items: [Pattern] = []
                if !isOp("]") {
                    repeat { items.append(try pattern()) } while consumeOp(",")
                }
                try expectOp("]")
                return .array(items)
            case .op("{"):
                var entries: [(key: Expr, variable: String?, pattern: Pattern?)] = []
                repeat {
                    guard let t = current else { throw unexpected() }
                    p += 1
                    switch t {
                    case .variable(let name):
                        entries.append((.literal(.string(name)), name, consumeOp(":") ? try pattern() : nil))
                    case .ident(let name):
                        try expectOp(":")
                        entries.append((.literal(.string(name)), nil, try pattern()))
                    case .string(let pieces):
                        let key = try stringExpr(pieces, format: nil)
                        try expectOp(":")
                        entries.append((key, nil, try pattern()))
                    case .op("("):
                        let key = try pipe()
                        try expectOp(")")
                        try expectOp(":")
                        entries.append((key, nil, try pattern()))
                    default:
                        p -= 1
                        throw unexpected()
                    }
                } while consumeOp(",")
                try expectOp("}")
                return .object(entries)
            default:
                p -= 1
                throw unexpected(expecting: "a $variable")
            }
        }

        mutating func definition() throws -> Expr {
            try expectKeyword("def")
            guard case .ident(let name)? = current else { throw unexpected(expecting: "a function name") }
            p += 1
            var params: [String] = []
            if consumeOp("(") {
                repeat {
                    switch current {
                    case .ident(let n)?: params.append(n)
                    case .variable(let n)?: params.append("$" + n)
                    default: throw unexpected(expecting: "a parameter name")
                    }
                    p += 1
                } while consumeOp(";")
                try expectOp(")")
            }
            try expectOp(":")
            let body = try pipe()
            try expectOp(";")
            if current == nil || isOp(")") || isOp("]") { return .define(name, params, body, .identity) }
            return .define(name, params, body, try pipe())
        }

        func stringExpr(_ pieces: [StringPiece], format: String?) throws -> Expr {
            if format == nil, pieces.count == 1, case .text(let s) = pieces[0] { return .literal(.string(s)) }
            return .string(try pieces.map { piece in
                switch piece {
                case .text(let s): return .text(s)
                case .code(let source):
                    var sub = Parser(tokens: try MiniJQ.lex(source))
                    return .expr(try sub.parseProgram())
                }
            }, format: format)
        }
    }

    // MARK: - Evaluation

    fileprivate final class Closure {
        let params: [String]
        let body: Expr
        var scope: Scope
        init(params: [String], body: Expr, scope: Scope) {
            self.params = params
            self.body = body
            self.scope = scope
        }
    }

    fileprivate struct Scope {
        var vars: [String: Value] = [:]
        var funcs: [String: Closure] = [:]
    }

    private final class StopToken {}
    private struct Stop: Error { let token: StopToken }
    /// An error raised downstream of a `try`, on its way out untouched.
    private struct Downstream: Error { let error: Error }

    fileprivate typealias Emit = (Value) throws -> Void
    fileprivate typealias PathEmit = ([Value], Value) throws -> Void

    fileprivate final class Evaluator {
        private var inputs: [Value]
        private var nextIndex = 0
        private var ticks = 0
        private var depth = 0
        private let deadline = Date().addingTimeInterval(20)
        private var regexCache: [String: NSRegularExpression] = [:]

        init(inputs: [Value]) { self.inputs = inputs }

        var consumed: Int { nextIndex }

        func nextInput() -> Value? {
            guard nextIndex < inputs.count else { return nil }
            defer { nextIndex += 1 }
            return inputs[nextIndex]
        }

        private func tick() throws {
            ticks += 1
            if ticks & 0xFFFF == 0, Date() > deadline {
                throw Failure("gave up: the filter ran for more than 20 seconds")
            }
        }

        /// Runs `body`, passing its outputs on. Returns the error `body` itself raised, if any; errors
        /// raised further downstream propagate untouched.
        private func guarded<T>(_ body: ((T) throws -> Void) throws -> Void, _ emit: (T) throws -> Void) throws -> Failure? {
            try withoutActuallyEscaping(emit) { emit in
                do {
                    try body { value in
                        do { try emit(value) } catch { throw Downstream(error: error) }
                    }
                    return nil
                } catch let downstream as Downstream {
                    throw downstream.error
                } catch let failure as Failure {
                    return failure
                }
            }
        }

        private func collect(_ e: Expr, _ input: Value, _ scope: Scope) throws -> [Value] {
            var out: [Value] = []
            try eval(e, input, scope) { out.append($0) }
            return out
        }

        private func first(_ e: Expr, _ input: Value, _ scope: Scope) throws -> Value? {
            let token = StopToken()
            var result: Value?
            do {
                try eval(e, input, scope) { value in
                    result = value
                    throw Stop(token: token)
                }
            } catch let stop as Stop where stop.token === token {}
            return result
        }

        /// Calls `body` for every combination of the arguments' outputs.
        private func withArgs(_ args: [Expr], _ input: Value, _ scope: Scope, _ body: ([Value]) throws -> Void) throws {
            func go(_ i: Int, _ acc: [Value]) throws {
                if i == args.count { try body(acc); return }
                try eval(args[i], input, scope) { try go(i + 1, acc + [$0]) }
            }
            try go(0, [])
        }

        private func optional(_ e: Expr?, _ input: Value, _ scope: Scope, _ body: (Value?) throws -> Void) throws {
            guard let e else { try body(nil); return }
            try eval(e, input, scope) { try body($0) }
        }

        func eval(_ expr: Expr, _ input: Value, _ scope: Scope, _ emit: Emit) throws {
            try tick()
            switch expr {
            case .identity:
                try emit(input)
            case .literal(let v):
                try emit(v)
            case .string(let pieces, let format):
                try interpolate(pieces[...], input, scope, format, "", emit)
            case .format(let name):
                try emit(.string(try MiniJQ.format(name, input)))
            case .index(let base, let key):
                try eval(base, input, scope) { b in
                    try self.eval(key, input, scope) { k in try emit(try MiniJQ.index(b, k)) }
                }
            case .slice(let base, let from, let to):
                try eval(base, input, scope) { b in
                    try self.optional(from, input, scope) { f in
                        try self.optional(to, input, scope) { t in try emit(try MiniJQ.slice(b, f, t)) }
                    }
                }
            case .iterate(let base):
                try eval(base, input, scope) { b in
                    for x in try MiniJQ.elements(b) { try emit(x) }
                }
            case .attempt(let body, let handler):
                if let failure = try guarded({ try self.eval(body, input, scope, $0) }, emit), let handler {
                    try eval(handler, failure.value, scope, emit)
                }
            case .array(let body):
                var items: [Value] = []
                if let body { try eval(body, input, scope) { items.append($0) } }
                try emit(.array(items))
            case .object(let entries):
                try buildObject(entries[...], input, scope, Object(), emit)
            case .negate(let e):
                try eval(e, input, scope) { v in
                    guard case .number(let d, _) = v else { throw Failure("\(v.described) cannot be negated") }
                    try emit(.number(-d))
                }
            case .pipe(let a, let b):
                try eval(a, input, scope) { try self.eval(b, $0, scope, emit) }
            case .comma(let a, let b):
                try eval(a, input, scope, emit)
                try eval(b, input, scope, emit)
            case .alternative(let a, let b):
                var any = false
                _ = try guarded({ (yield: Emit) in
                    try self.eval(a, input, scope) { v in
                        if v.isTruthy {
                            any = true
                            try yield(v)
                        }
                    }
                }, emit)
                if !any { try eval(b, input, scope, emit) }
            case .and(let a, let b):
                try eval(a, input, scope) { l in
                    guard l.isTruthy else { try emit(.bool(false)); return }
                    try self.eval(b, input, scope) { try emit(.bool($0.isTruthy)) }
                }
            case .or(let a, let b):
                try eval(a, input, scope) { l in
                    guard !l.isTruthy else { try emit(.bool(true)); return }
                    try self.eval(b, input, scope) { try emit(.bool($0.isTruthy)) }
                }
            case .binary(let op, let a, let b):
                try eval(b, input, scope) { r in
                    try self.eval(a, input, scope) { l in try emit(try MiniJQ.binary(op, l, r)) }
                }
            case .assign(let op, let lhs, let rhs):
                try assign(op, lhs, rhs, input, scope, emit)
            case .variable(let name):
                if let v = scope.vars[name] {
                    try emit(v)
                } else if name == "__loc__" {
                    try emit(.object(Object([("file", .string("<stdin>")), ("line", .number(1))])))
                } else {
                    throw Failure("$\(name) is not defined")
                }
            case .bind(let source, let pattern, let body):
                try eval(source, input, scope) { v in
                    var inner = scope
                    try self.bind(pattern, v, input, &inner)
                    try self.eval(body, input, inner, emit)
                }
            case .cond(let branches, let otherwise):
                try conditional(branches[...], otherwise, input, scope, emit)
            case .reduce(let source, let pattern, let initial, let update):
                try eval(initial, input, scope) { start in
                    var acc = start
                    try self.eval(source, input, scope) { v in
                        var inner = scope
                        try self.bind(pattern, v, input, &inner)
                        var last: Value = .null
                        try self.eval(update, acc, inner) { last = $0 }
                        acc = last
                    }
                    try emit(acc)
                }
            case .foreach(let source, let pattern, let initial, let update, let extract):
                try eval(initial, input, scope) { start in
                    var acc = start
                    try self.eval(source, input, scope) { v in
                        var inner = scope
                        try self.bind(pattern, v, input, &inner)
                        try self.eval(update, acc, inner) { next in
                            acc = next
                            if let extract { try self.eval(extract, next, inner, emit) } else { try emit(next) }
                        }
                    }
                }
            case .define(let name, let params, let body, let rest):
                let closure = Closure(params: params, body: body, scope: scope)
                var inner = scope
                inner.funcs["\(name)/\(params.count)"] = closure
                closure.scope = inner
                defer { closure.scope = Scope() }   // breaks the reference cycle
                try eval(rest, input, inner, emit)
            case .call(let name, let args):
                if let closure = scope.funcs["\(name)/\(args.count)"] {
                    try call(closure, args, input, scope) { try self.eval($0, input, $1, emit) }
                } else {
                    try builtin(name, args, input, scope, emit)
                }
            }
        }

        private func interpolate(_ pieces: ArraySlice<Piece>, _ input: Value, _ scope: Scope, _ format: String?, _ prefix: String, _ emit: Emit) throws {
            guard let piece = pieces.first else { try emit(.string(prefix)); return }
            switch piece {
            case .text(let s):
                try interpolate(pieces.dropFirst(), input, scope, format, prefix + s, emit)
            case .expr(let e):
                try eval(e, input, scope) { v in
                    let s = try format.map { try MiniJQ.format($0, v) } ?? v.text
                    try self.interpolate(pieces.dropFirst(), input, scope, format, prefix + s, emit)
                }
            }
        }

        private func buildObject(_ entries: ArraySlice<(Expr, Expr)>, _ input: Value, _ scope: Scope, _ partial: Object, _ emit: Emit) throws {
            guard let (keyExpr, valueExpr) = entries.first else { try emit(.object(partial)); return }
            try eval(keyExpr, input, scope) { k in
                guard case .string(let key) = k else { throw Failure("Object keys must be strings") }
                try self.eval(valueExpr, input, scope) { v in
                    var next = partial
                    next[key] = v
                    try self.buildObject(entries.dropFirst(), input, scope, next, emit)
                }
            }
        }

        private func conditional(_ branches: ArraySlice<(Expr, Expr)>, _ otherwise: Expr?, _ input: Value, _ scope: Scope, _ emit: Emit) throws {
            guard let (test, then) = branches.first else {
                if let otherwise { try eval(otherwise, input, scope, emit) } else { try emit(input) }
                return
            }
            try eval(test, input, scope) { c in
                if c.isTruthy {
                    try self.eval(then, input, scope, emit)
                } else {
                    try self.conditional(branches.dropFirst(), otherwise, input, scope, emit)
                }
            }
        }

        private func bind(_ pattern: Pattern, _ value: Value, _ input: Value, _ scope: inout Scope) throws {
            switch pattern {
            case .variable(let name):
                scope.vars[name] = value
            case .array(let items):
                for (i, item) in items.enumerated() {
                    try bind(item, try MiniJQ.index(value, .number(Double(i))), input, &scope)
                }
            case .object(let entries):
                for entry in entries {
                    guard let key = try first(entry.key, input, scope) else { continue }
                    let v = try MiniJQ.index(value, key)
                    if let variable = entry.variable { scope.vars[variable] = v }
                    if let sub = entry.pattern { try bind(sub, v, input, &scope) }
                }
            }
        }

        /// Calls a `def`ined function; `run` evaluates its body (as values or as paths).
        private func call(_ closure: Closure, _ args: [Expr], _ input: Value, _ scope: Scope, _ run: (Expr, Scope) throws -> Void) throws {
            depth += 1
            defer { depth -= 1 }
            guard depth < 3000 else { throw Failure("too much recursion") }
            var inner = closure.scope
            var valueParams: [(String, Expr)] = []
            for (param, arg) in zip(closure.params, args) {
                if param.hasPrefix("$") {
                    valueParams.append((String(param.dropFirst()), arg))
                } else {
                    inner.funcs["\(param)/0"] = Closure(params: [], body: arg, scope: scope)
                }
            }
            func bindValues(_ params: ArraySlice<(String, Expr)>, _ s: Scope) throws {
                guard let (name, arg) = params.first else { try run(closure.body, s); return }
                try eval(arg, input, scope) { v in
                    var next = s
                    next.vars[name] = v
                    next.funcs["\(name)/0"] = Closure(params: [], body: .literal(v), scope: Scope())
                    try bindValues(params.dropFirst(), next)
                }
            }
            try bindValues(valueParams[...], inner)
        }

        // MARK: Paths and assignment

        func paths(_ expr: Expr, _ path: [Value], _ current: Value, _ scope: Scope, _ emit: PathEmit) throws {
            try tick()
            switch expr {
            case .identity:
                try emit(path, current)
            case .index(let base, let key):
                try paths(base, path, current, scope) { p, v in
                    try self.eval(key, current, scope) { k in try emit(p + [k], try MiniJQ.index(v, k)) }
                }
            case .slice(let base, let from, let to):
                try paths(base, path, current, scope) { p, v in
                    try self.optional(from, current, scope) { f in
                        try self.optional(to, current, scope) { t in
                            let key = Value.object(Object([("start", f ?? .null), ("end", t ?? .null)]))
                            try emit(p + [key], try MiniJQ.slice(v, f, t))
                        }
                    }
                }
            case .iterate(let base):
                try paths(base, path, current, scope) { p, v in
                    switch v {
                    case .array(let items):
                        for (i, x) in items.enumerated() { try emit(p + [.number(Double(i))], x) }
                    case .object(let object):
                        for (k, x) in object.entries { try emit(p + [.string(k)], x) }
                    case .null:
                        break
                    default:
                        throw Failure("Cannot iterate over \(v.described)")
                    }
                }
            case .pipe(let a, let b):
                try paths(a, path, current, scope) { p, v in try self.paths(b, p, v, scope, emit) }
            case .comma(let a, let b):
                try paths(a, path, current, scope, emit)
                try paths(b, path, current, scope, emit)
            case .attempt(let body, _):
                _ = try guarded({ (yield: ((([Value], Value)) throws -> Void)) in
                    try self.paths(body, path, current, scope) { try yield(($0, $1)) }
                }, { try emit($0.0, $0.1) })
            case .alternative(let a, let b):
                var any = false
                _ = try guarded({ (yield: ((([Value], Value)) throws -> Void)) in
                    try self.paths(a, path, current, scope) { p, v in
                        if v.isTruthy {
                            any = true
                            try yield((p, v))
                        }
                    }
                }, { try emit($0.0, $0.1) })
                if !any { try paths(b, path, current, scope, emit) }
            case .cond(let branches, let otherwise):
                func go(_ rest: ArraySlice<(Expr, Expr)>) throws {
                    guard let (test, then) = rest.first else {
                        if let otherwise { try paths(otherwise, path, current, scope, emit) } else { try emit(path, current) }
                        return
                    }
                    try eval(test, current, scope) { c in
                        if c.isTruthy { try self.paths(then, path, current, scope, emit) } else { try go(rest.dropFirst()) }
                    }
                }
                try go(branches[...])
            case .bind(let source, let pattern, let body):
                try eval(source, current, scope) { v in
                    var inner = scope
                    try self.bind(pattern, v, current, &inner)
                    try self.paths(body, path, current, inner, emit)
                }
            case .define(let name, let params, let body, let rest):
                let closure = Closure(params: params, body: body, scope: scope)
                var inner = scope
                inner.funcs["\(name)/\(params.count)"] = closure
                closure.scope = inner
                defer { closure.scope = Scope() }
                try paths(rest, path, current, inner, emit)
            case .call(let name, let args):
                if let closure = scope.funcs["\(name)/\(args.count)"] {
                    try call(closure, args, current, scope) { try self.paths($0, path, current, $1, emit) }
                    return
                }
                switch "\(name)/\(args.count)" {
                case "empty/0":
                    return
                case "error/0", "error/1":
                    try builtin(name, args, current, scope) { _ in }
                case "select/1":
                    try eval(args[0], current, scope) { c in if c.isTruthy { try emit(path, current) } }
                case "recurse/0":
                    try recursePaths(path, current, emit)
                case "recurse/1":
                    func walk(_ p: [Value], _ v: Value) throws {
                        try emit(p, v)
                        try paths(args[0], p, v, scope) { try walk($0, $1) }
                    }
                    try walk(path, current)
                case "first/1":
                    let token = StopToken()
                    do {
                        try paths(args[0], path, current, scope) { p, v in
                            try emit(p, v)
                            throw Stop(token: token)
                        }
                    } catch let stop as Stop where stop.token === token {}
                case "last/1":
                    var last: ([Value], Value)?
                    try paths(args[0], path, current, scope) { last = ($0, $1) }
                    if let last { try emit(last.0, last.1) }
                case "getpath/1":
                    try eval(args[0], current, scope) { pv in
                        guard case .array(let extra) = pv else { throw Failure("Path must be specified as an array") }
                        try emit(path + extra, (try? MiniJQ.getpath(current, extra)) ?? .null)
                    }
                case "values/0", "nulls/0", "booleans/0", "numbers/0", "strings/0", "arrays/0", "objects/0", "iterables/0", "scalars/0":
                    try builtin(name, [], current, scope) { _ in try emit(path, current) }
                default:
                    throw Failure("Invalid path expression: \(name)/\(args.count) doesn't produce a path")
                }
            case .literal(.null):
                try emit(path, .null)
            default:
                var result: Value?
                try? eval(expr, current, scope) { result = $0; throw Failure("") }
                throw Failure("Invalid path expression with result \(result?.brief ?? "?")")
            }
        }

        private func recursePaths(_ path: [Value], _ v: Value, _ emit: PathEmit) throws {
            try tick()
            try emit(path, v)
            switch v {
            case .array(let items):
                for (i, x) in items.enumerated() { try recursePaths(path + [.number(Double(i))], x, emit) }
            case .object(let object):
                for (k, x) in object.entries { try recursePaths(path + [.string(k)], x, emit) }
            default:
                break
            }
        }

        private func recurseValues(_ v: Value, _ emit: Emit) throws {
            try tick()
            try emit(v)
            switch v {
            case .array(let items): for x in items { try recurseValues(x, emit) }
            case .object(let object): for x in object.values { try recurseValues(x, emit) }
            default: break
            }
        }

        private func assign(_ op: String, _ lhs: Expr, _ rhs: Expr, _ input: Value, _ scope: Scope, _ emit: Emit) throws {
            var targets: [[Value]] = []
            try paths(lhs, [], input, scope) { p, _ in targets.append(p) }
            switch op {
            case "|=":
                var result = input
                var removals: [[Value]] = []
                for p in targets {
                    let old = try MiniJQ.getpath(result, p)
                    if let new = try first(rhs, old, scope) {
                        result = try MiniJQ.setpath(result, p[...], new)
                    } else {
                        removals.append(p)
                    }
                }
                if !removals.isEmpty { result = try MiniJQ.delpaths(result, removals) }
                try emit(result)
            case "=":
                try eval(rhs, input, scope) { r in
                    var result = input
                    for p in targets { result = try MiniJQ.setpath(result, p[...], r) }
                    try emit(result)
                }
            default:
                let arithmetic = String(op.dropLast())
                try eval(rhs, input, scope) { r in
                    var result = input
                    for p in targets {
                        let old = try MiniJQ.getpath(result, p)
                        let new = arithmetic == "//" ? (old.isTruthy ? old : r) : try MiniJQ.binary(arithmetic, old, r)
                        result = try MiniJQ.setpath(result, p[...], new)
                    }
                    try emit(result)
                }
            }
        }

        // MARK: Regular expressions

        private func regex(_ pattern: Value, _ flags: Value?) throws -> (NSRegularExpression, global: Bool, skipEmpty: Bool) {
            guard case .string(let source) = pattern else { throw Failure("\(pattern.described) cannot be matched, as it is not a string") }
            var options: NSRegularExpression.Options = []
            var global = false, skipEmpty = false
            var flagText = ""
            if let flags, !flags.isNull {
                guard case .string(let f) = flags else { throw Failure("\(flags.described) is not a string") }
                flagText = f
                for c in f {
                    switch c {
                    case "g": global = true
                    case "i": options.insert(.caseInsensitive)
                    case "x": options.insert(.allowCommentsAndWhitespace)
                    case "s": options.insert(.dotMatchesLineSeparators)
                    case "n": skipEmpty = true
                    case "p": options.insert(.dotMatchesLineSeparators); skipEmpty = true
                    case "l", "b": break
                    default: throw Failure("\(f) is not a valid modifier string")
                    }
                }
            }
            let key = flagText + "/" + source
            if let cached = regexCache[key] { return (cached, global, skipEmpty) }
            guard let compiled = try? NSRegularExpression(pattern: ShellRegex.icu(source, basic: false), options: options) else {
                throw Failure("\(source) (at offset 0) is not a valid regex")
            }
            regexCache[key] = compiled
            return (compiled, global, skipEmpty)
        }

        private func string(_ v: Value, _ what: String = "cannot be matched, as it is not a string") throws -> String {
            guard case .string(let s) = v else { throw Failure("\(v.described) \(what)") }
            return s
        }

        private func matches(_ s: String, _ re: NSRegularExpression, global: Bool, skipEmpty: Bool) -> [NSTextCheckingResult] {
            let all = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).filter { !(skipEmpty && $0.range.length == 0) }
            return global ? all : Array(all.prefix(1))
        }

        private func matchObject(_ m: NSTextCheckingResult, in s: String, names: [String?]) -> Value {
            func offset(_ utf16: Int) -> Int {
                let index = String.Index(utf16Offset: utf16, in: s)
                return s.unicodeScalars.distance(from: s.unicodeScalars.startIndex, to: index)
            }
            func describe(_ range: NSRange, name: String??) -> Value {
                var object = Object()
                if range.location == NSNotFound {
                    object["offset"] = .number(-1)
                    object["length"] = .number(0)
                    object["string"] = .null
                } else {
                    let start = offset(range.location)
                    object["offset"] = .number(Double(start))
                    object["length"] = .number(Double(offset(range.location + range.length) - start))
                    object["string"] = .string(Range(range, in: s).map { String(s[$0]) } ?? "")
                }
                if let name { object["name"] = name.map(Value.string) ?? .null }
                return .object(object)
            }
            var result = Object()
            if case .object(let whole) = describe(m.range, name: nil) {
                for (k, v) in whole.entries { result[k] = v }
            }
            var captures: [Value] = []
            for group in 1..<max(m.numberOfRanges, 1) {
                captures.append(describe(m.range(at: group), name: .some(group - 1 < names.count ? names[group - 1] : nil)))
            }
            result["captures"] = .array(captures)
            return .object(result)
        }

        private func captureObject(_ m: NSTextCheckingResult, in s: String, names: [String?]) -> Object {
            var object = Object()
            for (i, name) in names.enumerated() where i + 1 < m.numberOfRanges {
                guard let name else { continue }
                let range = m.range(at: i + 1)
                object[name] = range.location == NSNotFound ? .null : Range(range, in: s).map { .string(String(s[$0])) } ?? .null
            }
            return object
        }

        private func substitute(_ input: Value, _ args: [Expr], global: Bool, _ scope: Scope, _ emit: Emit) throws {
            let s = try string(input, "cannot be matched, as it is not a string")
            let flagsExpr = args.count > 2 ? args[2] : nil
            try eval(args[0], input, scope) { pattern in
                try self.optional(flagsExpr, input, scope) { flags in
                    let (re, g, skipEmpty) = try self.regex(pattern, flags)
                    let names = ShellRegex.captureNames(re.pattern)
                    var out = ""
                    var last = s.startIndex
                    for m in self.matches(s, re, global: global || g, skipEmpty: skipEmpty) {
                        guard let r = Range(m.range, in: s) else { continue }
                        out += s[last..<r.lowerBound]
                        let replacement = try self.first(args[1], .object(self.captureObject(m, in: s, names: names)), scope) ?? .string("")
                        out += try self.string(replacement, "cannot be added to a string")
                        last = r.upperBound
                    }
                    out += s[last...]
                    try emit(.string(out))
                }
            }
        }

        // MARK: Builtins

        private func number(_ v: Value, _ name: String) throws -> Double {
            guard case .number(let d, _) = v else { throw Failure("\(v.described) number required") }
            return d
        }

        private func keyed(_ items: [Value], by f: Expr, _ scope: Scope) throws -> [(key: Value, value: Value)] {
            let pairs = try items.map { (key: Value.array(try collect(f, $0, scope)), value: $0) }
            return pairs.enumerated().sorted { a, b in
                let c = MiniJQ.compare(a.element.key, b.element.key)
                return c != 0 ? c < 0 : a.offset < b.offset
            }.map(\.element)
        }

        private func array(_ v: Value, _ name: String) throws -> [Value] {
            guard case .array(let items) = v else { throw Failure("Cannot \(name) \(v.described), as it is not an array") }
            return items
        }

        private func time(_ v: Value) throws -> Double {
            switch v {
            case .number(let d, _): return d
            case .array(let parts):
                var t = try brokenDown(parts)
                let fraction = parts.count > 5 ? try number(parts[5], "mktime").truncatingRemainder(dividingBy: 1) : 0
                return Double(timegm(&t)) + fraction
            default: throw Failure("\(v.described) cannot be used as a time")
            }
        }

        private func brokenDown(_ parts: [Value]) throws -> tm {
            guard parts.count >= 6 else { throw Failure("mktime requires array of 6 numbers") }
            let n = try parts.map { try number($0, "mktime") }
            var t = tm()
            t.tm_year = Int32(clamping: (MiniJQ.int(n[0]) ?? 1970) - 1900)
            t.tm_mon = Int32(clamping: MiniJQ.int(n[1]) ?? 0)
            t.tm_mday = Int32(clamping: MiniJQ.int(n[2]) ?? 1)
            t.tm_hour = Int32(clamping: MiniJQ.int(n[3]) ?? 0)
            t.tm_min = Int32(clamping: MiniJQ.int(n[4]) ?? 0)
            t.tm_sec = Int32(clamping: MiniJQ.int(n[5]) ?? 0)
            return t
        }

        private func brokenDownValue(_ seconds: Double, local: Bool) -> Value {
            var t = tm()
            var whole = time_t(seconds.rounded(.down))
            if local { localtime_r(&whole, &t) } else { gmtime_r(&whole, &t) }
            let fraction = seconds - seconds.rounded(.down)
            return .array([
                .number(Double(t.tm_year) + 1900), .number(Double(t.tm_mon)), .number(Double(t.tm_mday)),
                .number(Double(t.tm_hour)), .number(Double(t.tm_min)), .number(Double(t.tm_sec) + fraction),
                .number(Double(t.tm_wday)), .number(Double(t.tm_yday)),
            ])
        }

        private func strftime(_ v: Value, _ format: Value, local: Bool) throws -> Value {
            let fmt = try string(format, "is not a valid strftime format")
            var t: tm
            switch v {
            case .number(let d, _):
                t = tm()
                var whole = time_t(d.rounded(.down))
                if local { localtime_r(&whole, &t) } else { gmtime_r(&whole, &t) }
            case .array(let parts):
                t = try brokenDown(parts)
            default:
                throw Failure("strftime/1 requires parsed datetime inputs")
            }
            return .string(MiniShell.strftime(fmt, &t))
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        private func builtin(_ name: String, _ args: [Expr], _ input: Value, _ scope: Scope, _ emit: Emit) throws {
            let v = input
            func emitAll(_ values: [Value]) throws { for x in values { try emit(x) } }
            func math(_ f: (Double) -> Double) throws { try emit(.number(f(try number(v, name)))) }
            func withArg(_ body: (Value) throws -> Void) throws { try eval(args[0], input, scope) { try body($0) } }

            switch "\(name)/\(args.count)" {
            case "empty/0": return
            case "not/0": try emit(.bool(!v.isTruthy))
            case "error/0": throw Failure(value: v)
            case "error/1": try withArg { throw Failure(value: $0) }
            case "type/0": try emit(.string(v.typeName))
            case "length/0":
                switch v {
                case .null: try emit(.number(0))
                case .bool: throw Failure("\(v.described) has no length")
                case .number(let d, _): try emit(.number(abs(d)))
                case .string(let s): try emit(.number(Double(s.unicodeScalars.count)))
                case .array(let a): try emit(.number(Double(a.count)))
                case .object(let o): try emit(.number(Double(o.count)))
                }
            case "utf8bytelength/0": try emit(.number(Double(try string(v, "only strings have UTF-8 byte length").utf8.count)))
            case "keys/0", "keys_unsorted/0":
                switch v {
                case .object(let o): try emit(.array((name == "keys" ? o.sortedKeys : o.keys).map(Value.string)))
                case .array(let a): try emit(.array(a.indices.map { .number(Double($0)) }))
                default: throw Failure("\(v.described) has no keys")
                }
            case "has/1":
                try withArg { k in
                    switch (v, k) {
                    case let (.object(o), .string(s)): try emit(.bool(o[s] != nil))
                    case let (.array(a), .number(d, _)): try emit(.bool(MiniJQ.int(d).map { $0 >= 0 && $0 < a.count } ?? false))
                    default: throw Failure("Cannot check whether \(v.typeName) has a \(k.typeName) key")
                    }
                }
            case "in/1":
                try withArg { o in try self.builtin("has", [.literal(v)], o, scope, emit) }
            case "contains/1": try withArg { try emit(.bool(try MiniJQ.contains(v, $0))) }
            case "inside/1": try withArg { try emit(.bool(try MiniJQ.contains($0, v))) }
            case "select/1":
                try eval(args[0], v, scope) { if $0.isTruthy { try emit(v) } }
            case "map/1":
                var out: [Value] = []
                for x in try MiniJQ.elements(v) { try eval(args[0], x, scope) { out.append($0) } }
                try emit(.array(out))
            case "map_values/1":
                switch v {
                case .object(var o):
                    for (k, x) in o.entries { o[k] = try first(args[0], x, scope) }
                    try emit(.object(o))
                case .array(let a):
                    try emit(.array(try a.compactMap { try first(args[0], $0, scope) }))
                default:
                    throw Failure("Cannot iterate over \(v.described)")
                }
            case "values/0": if !v.isNull { try emit(v) }
            case "nulls/0": if v.isNull { try emit(v) }
            case "booleans/0": if v.typeName == "boolean" { try emit(v) }
            case "numbers/0": if v.typeName == "number" { try emit(v) }
            case "strings/0": if v.typeName == "string" { try emit(v) }
            case "arrays/0": if v.typeName == "array" { try emit(v) }
            case "objects/0": if v.typeName == "object" { try emit(v) }
            case "iterables/0": if v.typeName == "array" || v.typeName == "object" { try emit(v) }
            case "scalars/0": if v.typeName != "array" && v.typeName != "object" { try emit(v) }
            case "add/0":
                var acc: Value = .null
                for x in try MiniJQ.elements(v) { acc = try MiniJQ.binary("+", acc, x) }
                try emit(acc)
            case "add/1":
                var acc: Value = .null
                try eval(args[0], v, scope) { acc = try MiniJQ.binary("+", acc, $0) }
                try emit(acc)
            case "any/0": try emit(.bool(try MiniJQ.elements(v).contains { $0.isTruthy }))
            case "all/0": try emit(.bool(try MiniJQ.elements(v).allSatisfy { $0.isTruthy }))
            case "any/1", "all/1":
                let wantAny = name == "any"
                var result = !wantAny
                for x in try MiniJQ.elements(v) {
                    if let c = try first(args[0], x, scope), c.isTruthy == wantAny { result = wantAny; break }
                }
                try emit(.bool(result))
            case "any/2", "all/2":
                let wantAny = name == "any"
                var result = !wantAny
                let token = StopToken()
                do {
                    try eval(args[0], v, scope) { x in
                        if let c = try self.first(args[1], x, scope), c.isTruthy == wantAny {
                            result = wantAny
                            throw Stop(token: token)
                        }
                    }
                } catch let stop as Stop where stop.token === token {}
                try emit(.bool(result))
            case "IN/1":
                var found = false
                let token = StopToken()
                do {
                    try eval(args[0], v, scope) { x in
                        if MiniJQ.compare(x, v) == 0 { found = true; throw Stop(token: token) }
                    }
                } catch let stop as Stop where stop.token === token {}
                try emit(.bool(found))
            case "IN/2":
                let candidates = try collect(args[1], v, scope)
                var found = false
                let token = StopToken()
                do {
                    try eval(args[0], v, scope) { x in
                        if candidates.contains(where: { MiniJQ.compare($0, x) == 0 }) { found = true; throw Stop(token: token) }
                    }
                } catch let stop as Stop where stop.token === token {}
                try emit(.bool(found))
            case "flatten/0", "flatten/1":
                func flatten(_ items: [Value], _ depth: Int) -> [Value] {
                    items.flatMap { x -> [Value] in
                        if depth > 0, case .array(let inner) = x { return flatten(inner, depth - 1) }
                        return [x]
                    }
                }
                if args.isEmpty {
                    try emit(.array(flatten(try array(v, "flatten"), 10_000)))
                } else {
                    try withArg { d in
                        let depth = try self.number(d, "flatten")
                        guard depth >= 0 else { throw Failure("flatten depth must not be negative") }
                        try emit(.array(flatten(try self.array(v, "flatten"), MiniJQ.int(depth) ?? 10_000)))
                    }
                }
            case "range/1", "range/2", "range/3":
                try withArgs(args, v, scope) { bounds in
                    let n = try bounds.map { try self.number($0, "range") }
                    let (from, to, by) = n.count == 1 ? (0, n[0], 1.0) : (n[0], n[1], n.count == 3 ? n[2] : 1)
                    guard by != 0 else { return }
                    var x = from
                    while by > 0 ? x < to : x > to {
                        try self.tick()
                        try emit(.number(x))
                        x += by
                    }
                }
            case "floor/0": try math { $0.rounded(.down) }
            case "ceil/0": try math { $0.rounded(.up) }
            case "round/0": try math { $0.rounded(.toNearestOrAwayFromZero) }
            case "trunc/0": try math { $0.rounded(.towardZero) }
            case "fabs/0", "abs/0": try math { abs($0) }
            case "sqrt/0": try math { $0.squareRoot() }
            case "log/0": try math { Foundation.log($0) }
            case "log2/0": try math { Foundation.log2($0) }
            case "log10/0": try math { Foundation.log10($0) }
            case "exp/0": try math { Foundation.exp($0) }
            case "exp2/0": try math { Foundation.exp2($0) }
            case "exp10/0": try math { Foundation.pow(10, $0) }
            case "sin/0": try math { Foundation.sin($0) }
            case "cos/0": try math { Foundation.cos($0) }
            case "tan/0": try math { Foundation.tan($0) }
            case "asin/0": try math { Foundation.asin($0) }
            case "acos/0": try math { Foundation.acos($0) }
            case "atan/0": try math { Foundation.atan($0) }
            case "significand/0": try math { $0 == 0 ? 0 : $0 / Foundation.pow(2, Foundation.floor(Foundation.log2(abs($0)))) }
            case "pow/2":
                try withArgs(args, v, scope) { try emit(.number(Foundation.pow(try self.number($0[0], "pow"), try self.number($0[1], "pow")))) }
            case "log/1", "atan2/2", "fmin/2", "fmax/2":
                try withArgs(args, v, scope) { a in
                    let n = try a.map { try self.number($0, name) }
                    switch name {
                    case "atan2": try emit(.number(Foundation.atan2(n[0], n[1])))
                    case "fmin": try emit(.number(Swift.min(n[0], n[1])))
                    case "fmax": try emit(.number(Swift.max(n[0], n[1])))
                    default: try emit(.number(Foundation.log(n[0])))
                    }
                }
            case "infinite/0": try emit(.number(.infinity))
            case "nan/0": try emit(.number(.nan))
            case "isinfinite/0": try emit(.bool(try number(v, name).isInfinite))
            case "isnan/0": try emit(.bool(try number(v, name).isNaN))
            case "isnormal/0": try emit(.bool(try number(v, name).isNormal))
            case "isvalid/1": try emit(.bool((try? collect(args[0], v, scope)) != nil))
            case "tostring/0": try emit(.string(v.text))
            case "tonumber/0":
                switch v {
                case .number: try emit(v)
                case .string(let s):
                    let trimmed = s.trimmingCharacters(in: .whitespaces)
                    guard let d = Double(trimmed), !trimmed.isEmpty, trimmed.lowercased() != "nan", !trimmed.lowercased().contains("inf") else {
                        throw Failure("Cannot parse '\(s)' as JSON")
                    }
                    try emit(.number(d))
                default: throw Failure("\(v.described) cannot be parsed as a number")
                }
            case "tojson/0": try emit(.string(v.json()))
            case "fromjson/0":
                let s = try string(v, "only strings can be parsed")
                guard let parsed = try? Reader.parse(s), parsed.count == 1 else { throw Failure("\(s) (while parsing '\(s)')") }
                try emit(parsed[0])
            case "ascii_downcase/0", "ascii_upcase/0":
                let s = try string(v, "cannot be case-converted, as it is not a string")
                var view = String.UnicodeScalarView()
                for c in s.unicodeScalars {
                    if name == "ascii_downcase", ("A"..."Z").contains(c) { view.append(Unicode.Scalar(c.value + 32)!) }
                    else if name == "ascii_upcase", ("a"..."z").contains(c) { view.append(Unicode.Scalar(c.value - 32)!) }
                    else { view.append(c) }
                }
                try emit(.string(String(view)))
            case "explode/0":
                try emit(.array(try string(v, "cannot be exploded, as it is not a string").unicodeScalars.map { .number(Double($0.value)) }))
            case "implode/0":
                var view = String.UnicodeScalarView()
                for x in try array(v, "implode") {
                    guard case .number(let d, _) = x, let n = MiniJQ.int(d), n >= 0, let scalar = Unicode.Scalar(UInt32(clamping: n)) else {
                        throw Failure("Unicode codepoint array required to implode")
                    }
                    view.append(scalar)
                }
                try emit(.string(String(view)))
            case "ltrimstr/1", "rtrimstr/1", "trimstr/1":
                try withArg { x in
                    guard case .string(var s) = v, case .string(let affix) = x, !affix.isEmpty else { try emit(v); return }
                    if name != "rtrimstr", s.hasPrefix(affix) { s = String(s.dropFirst(affix.count)) }
                    if name != "ltrimstr", s.hasSuffix(affix) { s = String(s.dropLast(affix.count)) }
                    try emit(.string(s))
                }
            case "startswith/1", "endswith/1":
                try withArg { x in
                    guard case .string(let s) = v, case .string(let affix) = x else { throw Failure("\(name)() requires string inputs") }
                    try emit(.bool(name == "startswith" ? s.hasPrefix(affix) : s.hasSuffix(affix)))
                }
            case "trim/0", "ltrim/0", "rtrim/0":
                var scalars = Array(try string(v, "trim input must be a string").unicodeScalars)
                if name != "rtrim" { while let c = scalars.first, c.properties.isWhitespace { scalars.removeFirst() } }
                if name != "ltrim" { while let c = scalars.last, c.properties.isWhitespace { scalars.removeLast() } }
                try emit(.string(String(String.UnicodeScalarView(scalars))))
            case "split/1":
                try withArg { sep in
                    guard case .string(let s) = v, case .string(let separator) = sep else { throw Failure("split input and separator must be strings") }
                    try emit(.array(MiniJQ.split(s, by: separator).map(Value.string)))
                }
            case "split/2", "splits/1", "splits/2":
                let s = try string(v)
                try withArgs(args, v, scope) { a in
                    let (re, _, skipEmpty) = try self.regex(a[0], a.count > 1 ? a[1] : nil)
                    var parts: [Value] = []
                    var last = s.startIndex
                    for m in self.matches(s, re, global: true, skipEmpty: skipEmpty) {
                        guard let r = Range(m.range, in: s) else { continue }
                        parts.append(.string(String(s[last..<r.lowerBound])))
                        last = r.upperBound
                    }
                    parts.append(.string(String(s[last...])))
                    if name == "split" { try emit(.array(parts)) } else { try emitAll(parts) }
                }
            case "join/1":
                try withArg { sep in
                    let separator = try self.string(sep, "cannot be used to join, as it is not a string")
                    let pieces = try MiniJQ.elements(v).map { x -> String in
                        switch x {
                        case .null: return ""
                        case .string(let s): return s
                        case .number, .bool: return x.text
                        default: throw Failure("Cannot join with \(x.typeName)")
                        }
                    }
                    try emit(.string(pieces.joined(separator: separator)))
                }
            case "test/1", "test/2":
                let s = try string(v)
                try withArgs(args, v, scope) { a in
                    let (re, _, _) = try self.regex(a[0], a.count > 1 ? a[1] : nil)
                    try emit(.bool(re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil))
                }
            case "match/1", "match/2", "capture/1", "capture/2", "scan/1", "scan/2":
                let s = try string(v)
                try withArgs(args, v, scope) { a in
                    let (re, g, skipEmpty) = try self.regex(a[0], a.count > 1 ? a[1] : nil)
                    let names = ShellRegex.captureNames(re.pattern)
                    for m in self.matches(s, re, global: g || name == "scan", skipEmpty: skipEmpty) {
                        switch name {
                        case "match": try emit(self.matchObject(m, in: s, names: names))
                        case "capture": try emit(.object(self.captureObject(m, in: s, names: names)))
                        default:
                            func text(_ r: NSRange) -> Value {
                                r.location == NSNotFound ? .null : Range(r, in: s).map { .string(String(s[$0])) } ?? .null
                            }
                            if m.numberOfRanges <= 1 {
                                try emit(text(m.range))
                            } else {
                                try emit(.array((1..<m.numberOfRanges).map { text(m.range(at: $0)) }))
                            }
                        }
                    }
                }
            case "sub/2", "sub/3": try substitute(v, args, global: false, scope, emit)
            case "gsub/2", "gsub/3": try substitute(v, args, global: true, scope, emit)
            case "ascii/0":
                guard case .number(let d, _) = v, let n = MiniJQ.int(d), let scalar = Unicode.Scalar(UInt32(clamping: n)) else {
                    throw Failure("ascii requires a codepoint")
                }
                try emit(.string(String(Character(scalar))))
            case "sort/0":
                try emit(.array(try array(v, "sort").enumerated().sorted { a, b in
                    let c = MiniJQ.compare(a.element, b.element)
                    return c != 0 ? c < 0 : a.offset < b.offset
                }.map(\.element)))
            case "sort_by/1": try emit(.array(try keyed(try array(v, "sort"), by: args[0], scope).map(\.value)))
            case "group_by/1", "unique_by/1":
                var groups: [[Value]] = []
                var lastKey: Value?
                for (key, value) in try keyed(try array(v, "group"), by: args[0], scope) {
                    if let lastKey, MiniJQ.compare(lastKey, key) == 0 { groups[groups.count - 1].append(value) } else { groups.append([value]) }
                    lastKey = key
                }
                try emit(.array(name == "group_by" ? groups.map(Value.array) : groups.map { $0[0] }))
            case "unique/0":
                var out: [Value] = []
                for x in try array(v, "unique").sorted(by: { MiniJQ.compare($0, $1) < 0 }) where out.last.map({ MiniJQ.compare($0, x) != 0 }) ?? true {
                    out.append(x)
                }
                try emit(.array(out))
            case "min/0", "max/0":
                let items = try array(v, name)
                let best = items.dropFirst().reduce(items.first) { acc, x in
                    guard let acc else { return x }
                    let c = MiniJQ.compare(x, acc)
                    return name == "min" ? (c < 0 ? x : acc) : (c >= 0 ? x : acc)
                }
                try emit(best ?? .null)
            case "min_by/1", "max_by/1":
                let pairs = try keyed(try array(v, name), by: args[0], scope)
                try emit((name == "min_by" ? pairs.first : pairs.last)?.value ?? .null)
            case "reverse/0":
                switch v {
                case .array(let a): try emit(.array(a.reversed()))
                case .string(let s): try emit(.string(String(s.reversed())))
                case .null: try emit(.array([]))
                default: throw Failure("Cannot reverse \(v.described)")
                }
            case "to_entries/0":
                guard case .object(let o) = v else { throw Failure("\(v.described) has no keys") }
                try emit(.array(o.entries.map { .object(Object([("key", .string($0.key)), ("value", $0.value)])) }))
            case "from_entries/0":
                var o = Object()
                for entry in try MiniJQ.elements(v) {
                    guard case .object(let e) = entry else { throw Failure("Cannot index \(entry.typeName) with \"key\"") }
                    let key = [e["key"], e["k"], e["name"], e["Name"], e["Key"], e["K"]].compactMap { $0 }.first { $0.isTruthy } ?? e["key"] ?? .null
                    let value = [e["value"], e["v"], e["Value"], e["V"]].compactMap { $0 }.first ?? .null
                    switch key {
                    case .string(let s): o[s] = value
                    case .number, .bool: o[key.text] = value
                    case .null: o["null"] = value
                    default: throw Failure("Cannot use \(key.described) as object key")
                    }
                }
                try emit(.object(o))
            case "with_entries/1":
                var entriesValue: Value = .null
                try builtin("to_entries", [], v, scope) { entriesValue = $0 }
                var mapped: Value = .null
                try builtin("map", args, entriesValue, scope) { mapped = $0 }
                try builtin("from_entries", [], mapped, scope, emit)
            case "walk/1":
                func walk(_ x: Value) throws -> [Value] {
                    var node = x
                    switch x {
                    case .array(let items): node = .array(try items.flatMap(walk))
                    case .object(let o):
                        var out = Object()
                        for (k, value) in o.entries { if let w = try walk(value).last { out[k] = w } }
                        node = .object(out)
                    default: break
                    }
                    return try collect(args[0], node, scope)
                }
                try emitAll(try walk(v))
            case "transpose/0":
                let rows = try array(v, "transpose").map { try array($0, "transpose") }
                let width = rows.map(\.count).max() ?? 0
                try emit(.array((0..<width).map { i in .array(rows.map { i < $0.count ? $0[i] : .null }) }))
            case "toarray/0":
                if case .array = v { try emit(v) } else { try emit(.array([v])) }
            case "recurse/0":
                try recurseValues(v, emit)
            case "recurse/1", "recurse/2":
                func walk(_ x: Value) throws {
                    try emit(x)
                    try eval(args[0], x, scope) { next in
                        if args.count == 2 {
                            guard let c = try self.first(args[1], next, scope), c.isTruthy else { return }
                        }
                        try walk(next)
                    }
                }
                try walk(v)
            case "env/0", "$ENV/0": try emit(scope.vars["ENV"] ?? .object(Object()))
            case "builtins/0": try emit(.array([]))
            case "input/0":
                guard let next = nextInput() else { throw Failure("No more inputs") }
                try emit(next)
            case "inputs/0":
                while let next = nextInput() { try emit(next) }
            case "debug/0", "debug/1", "stderr/0": try emit(v)
            case "input_filename/0": try emit(.null)
            case "input_line_number/0": try emit(.number(0))
            case "halt/0": throw Failure("halt")
            case "halt_error/0", "halt_error/1": throw Failure(value: v)
            case "first/0": try emit(try MiniJQ.index(v, .number(0)))
            case "last/0": try emit(try MiniJQ.index(v, .number(-1)))
            case "nth/1": try withArg { try emit(try MiniJQ.index(v, $0)) }
            case "first/1":
                if let x = try first(args[0], v, scope) { try emit(x) }
            case "last/1":
                var last: Value?
                try eval(args[0], v, scope) { last = $0 }
                if let last { try emit(last) }
            case "isempty/1":
                try emit(.bool(try first(args[0], v, scope) == nil))
            case "limit/2", "nth/2":
                try withArg { nv in
                    guard let n = MiniJQ.int(try self.number(nv, name)) else { return }
                    if name == "nth" {
                        guard n >= 0 else { throw Failure("Out of bounds negative array index") }
                    } else if n <= 0 {
                        return
                    }
                    var count = 0
                    let token = StopToken()
                    do {
                        try self.eval(args[1], v, scope) { x in
                            count += 1
                            if name == "limit" {
                                try emit(x)
                                if count >= n { throw Stop(token: token) }
                            } else if count == n + 1 {
                                try emit(x)
                                throw Stop(token: token)
                            }
                        }
                    } catch let stop as Stop where stop.token === token {}
                }
            case "until/2":
                func step(_ x: Value) throws {
                    try tick()
                    try eval(args[0], x, scope) { c in
                        if c.isTruthy { try emit(x) } else { try self.eval(args[1], x, scope) { try step($0) } }
                    }
                }
                try step(v)
            case "while/2":
                func step(_ x: Value) throws {
                    try tick()
                    try eval(args[0], x, scope) { c in
                        guard c.isTruthy else { return }
                        try emit(x)
                        try self.eval(args[1], x, scope) { try step($0) }
                    }
                }
                try step(v)
            case "repeat/1":
                func step(_ x: Value) throws {
                    try tick()
                    try emit(x)
                    try eval(args[0], x, scope) { try step($0) }
                }
                try step(v)
            case "paths/0":
                try recursePaths([], v) { p, _ in if !p.isEmpty { try emit(.array(p)) } }
            case "paths/1", "leaf_paths/0":
                try recursePaths([], v) { p, x in
                    guard !p.isEmpty else { return }
                    let keep: Bool
                    if name == "leaf_paths" { keep = x.typeName != "array" && x.typeName != "object" } else { keep = try self.first(args[0], x, scope)?.isTruthy ?? false }
                    if keep { try emit(.array(p)) }
                }
            case "path/1":
                try paths(args[0], [], v, scope) { p, _ in try emit(.array(p)) }
            case "pick/1":
                var result: Value = .null
                try paths(args[0], [], v, scope) { p, x in result = try MiniJQ.setpath(result, p[...], x) }
                try emit(result)
            case "del/1":
                var targets: [[Value]] = []
                try paths(args[0], [], v, scope) { p, _ in targets.append(p) }
                try emit(try MiniJQ.delpaths(v, targets))
            case "getpath/1":
                try withArg { p in
                    guard case .array(let path) = p else { throw Failure("Path must be specified as an array") }
                    try emit((try? MiniJQ.getpath(v, path)) ?? .null)
                }
            case "setpath/2":
                try withArgs(args, v, scope) { a in
                    guard case .array(let path) = a[0] else { throw Failure("Path must be specified as an array") }
                    try emit(try MiniJQ.setpath(v, path[...], a[1]))
                }
            case "delpaths/1":
                try withArg { ps in
                    let all = try self.array(ps, "delete paths of").map { p -> [Value] in
                        guard case .array(let path) = p else { throw Failure("Path must be specified as an array") }
                        return path
                    }
                    try emit(try MiniJQ.delpaths(v, all))
                }
            case "indices/1", "index/1", "rindex/1":
                try withArg { x in
                    var found: [Int]
                    switch (v, x) {
                    case (.null, _), (_, .null):
                        try emit(.null)
                        return
                    case let (.string(s), .string(sub)):
                        guard !sub.isEmpty else { try emit(.null); return }
                        let hay = Array(s.unicodeScalars), needle = Array(sub.unicodeScalars)
                        found = hay.count < needle.count ? [] : (0...(hay.count - needle.count)).filter { Array(hay[$0..<($0 + needle.count)]) == needle }
                    case let (.array(items), .array(sub)):
                        found = MiniJQ.indices(of: sub, in: items)
                    case let (.array(items), _):
                        found = items.indices.filter { MiniJQ.compare(items[$0], x) == 0 }
                    default:
                        throw Failure("Cannot determine the indices of \(x.described) in \(v.described)")
                    }
                    switch name {
                    case "index": try emit(found.first.map { .number(Double($0)) } ?? .null)
                    case "rindex": try emit(found.last.map { .number(Double($0)) } ?? .null)
                    default: try emit(.array(found.map { .number(Double($0)) }))
                    }
                }
            case "combinations/0":
                func combos(_ rest: ArraySlice<Value>, _ acc: [Value]) throws {
                    guard let head = rest.first else { try emit(.array(acc)); return }
                    for x in try MiniJQ.elements(head) { try combos(rest.dropFirst(), acc + [x]) }
                }
                try combos(try array(v, "combine")[...], [])
            case "combinations/1":
                try withArg { nv in
                    let n = MiniJQ.int(try self.number(nv, name)) ?? 0
                    try self.builtin("combinations", [], .array(Array(repeating: v, count: max(n, 0))), scope, emit)
                }
            case "now/0": try emit(.number(Date().timeIntervalSince1970))
            case "mktime/0": try emit(.number(try time(v).rounded(.down)))
            case "gmtime/0": try emit(brokenDownValue(try number(v, name), local: false))
            case "localtime/0": try emit(brokenDownValue(try number(v, name), local: true))
            case "strftime/1": try withArg { try emit(try self.strftime(v, $0, local: false)) }
            case "strflocaltime/1": try withArg { try emit(try self.strftime(v, $0, local: true)) }
            case "todate/0", "todateiso8601/0", "date/0":
                try emit(try strftime(v, .string("%Y-%m-%dT%H:%M:%SZ"), local: false))
            case "fromdate/0", "fromdateiso8601/0", "dateadd/0":
                let s = try string(v, "cannot be parsed as a date")
                guard let date = MiniShell.parseISODate(s) else {
                    throw Failure("date \"\(s)\" does not match format \"%Y-%m-%dT%H:%M:%SZ\"")
                }
                try emit(.number(date.timeIntervalSince1970.rounded(.down)))
            case "strptime/1":
                try withArg { f in
                    let s = try self.string(v, "strptime/1 requires string inputs and arguments")
                    let format = try self.string(f, "strptime/1 requires string inputs and arguments")
                    var t = tm()
                    guard let end = s.withCString({ cs in format.withCString { fs in strptime(cs, fs, &t) } }), end.pointee == 0 else {
                        throw Failure("date \"\(s)\" does not match format \"\(format)\"")
                    }
                    let seconds = Double(timegm(&t))
                    try emit(self.brokenDownValue(seconds, local: false))
                }
            case "tostream/0":
                func stream(_ path: [Value], _ x: Value) throws {
                    switch x {
                    case .array(let items) where !items.isEmpty:
                        for (i, item) in items.enumerated() { try stream(path + [.number(Double(i))], item) }
                        try emit(.array([.array(path + [.number(Double(items.count - 1))])]))
                    case .object(let o) where !o.isEmpty:
                        for (k, item) in o.entries { try stream(path + [.string(k)], item) }
                        try emit(.array([.array(path + [.string(o.keys.last!)])]))
                    default:
                        try emit(.array([.array(path), x]))
                    }
                }
                try stream([], v)
            default:
                if name.hasPrefix("@") { throw Failure("\(name) is not a valid format") }
                throw Failure("\(name)/\(args.count) is not defined")
            }
        }
    }
}

/// Regex helpers shared by grep, sed, awk and jq. Patterns run on ICU (NSRegularExpression).
enum ShellRegex {
    /// Rewrites a POSIX basic (`basic: true`) or extended pattern for ICU: in basic patterns `\( \) \{ \}
    /// \| \+ \?` are the operators and the bare characters are literal; GNU `\< \>` become `\b`; and a
    /// `{` that doesn't start a repetition count is literal, as in most regex engines but not ICU.
    static func icu(_ pattern: String, basic: Bool) -> String {
        let c = Array(pattern)
        var out = ""
        var i = 0
        var inClass = false
        func isInterval(at j: Int) -> Bool {
            var k = j + 1
            var digits = 0
            while k < c.count, c[k].isASCII, c[k].isNumber { k += 1; digits += 1 }
            if k < c.count, c[k] == "," {
                k += 1
                while k < c.count, c[k].isASCII, c[k].isNumber { k += 1; digits += 1 }
            }
            return digits > 0 && k < c.count && c[k] == "}"
        }
        var openIntervals = 0
        while i < c.count {
            let ch = c[i]
            if inClass {
                if ch == "[", i + 1 < c.count, c[i + 1] == ":" || c[i + 1] == "=" || c[i + 1] == "." {
                    // [:alpha:] and friends
                    let close = c[i + 1]
                    var j = i + 2
                    while j + 1 < c.count, !(c[j] == close && c[j + 1] == "]") { j += 1 }
                    out += String(c[i...min(j + 1, c.count - 1)])
                    i = j + 2
                    continue
                }
                if ch == "\\" && i + 1 < c.count && basic { out += "\\\\"; i += 1; continue }
                if ch == "[" { out += "\\[" } else { out.append(ch) }
                if ch == "]" { inClass = false }
                i += 1
                continue
            }
            if ch == "[" {
                inClass = true
                out.append(ch)
                i += 1
                if i < c.count, c[i] == "^" { out.append("^"); i += 1 }
                if i < c.count, c[i] == "]" { out += "\\]"; i += 1 }
                continue
            }
            if ch == "\\", i + 1 < c.count {
                let n = c[i + 1]
                i += 2
                if n == "<" || n == ">" { out += "\\b"; continue }
                if basic && "(){}|+?".contains(n) {
                    if n == "{" { openIntervals += 1 }
                    if n == "}" { openIntervals = max(openIntervals - 1, 0) }
                    out.append(n)
                } else {
                    out.append("\\")
                    out.append(n)
                }
                continue
            }
            if basic && "(){}|+?".contains(ch) {
                out += "\\" + String(ch)
            } else if ch == "{" && !isInterval(at: i) {
                out += "\\{"
            } else if ch == "{" {
                openIntervals += 1
                out.append(ch)
            } else if ch == "}" {
                if openIntervals > 0 { openIntervals -= 1; out.append(ch) } else { out += "\\}" }
            } else {
                out.append(ch)
            }
            i += 1
        }
        return out
    }

    /// Names of the capture groups, in order (nil for unnamed groups).
    static func captureNames(_ pattern: String) -> [String?] {
        var names: [String?] = []
        let c = Array(pattern)
        var i = 0
        var inClass = false
        while i < c.count {
            let ch = c[i]
            if ch == "\\" { i += 2; continue }
            if inClass {
                if ch == "]" { inClass = false }
                i += 1
                continue
            }
            if ch == "[" {
                inClass = true
                i += 1
                if i < c.count, c[i] == "^" { i += 1 }
                if i < c.count, c[i] == "]" { i += 1 }
                continue
            }
            if ch == "(" {
                if i + 1 < c.count, c[i + 1] == "?" {
                    var j = i + 2
                    if j < c.count, c[j] == "P" { j += 1 }
                    if j + 1 < c.count, c[j] == "<", c[j + 1] != "=", c[j + 1] != "!" {
                        var name = ""
                        j += 1
                        while j < c.count, c[j] != ">" { name.append(c[j]); j += 1 }
                        names.append(name)
                    }
                } else {
                    names.append(nil)
                }
            }
            i += 1
        }
        return names
    }

    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func compile(_ pattern: String, basic: Bool, ignoreCase: Bool = false) -> NSRegularExpression? {
        let key = "\(basic ? "b" : "e")\(ignoreCase ? "i" : "")/\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let re = try? NSRegularExpression(pattern: icu(pattern, basic: basic), options: ignoreCase ? [.caseInsensitive] : []) else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = re
        return re
    }
}
