import Foundation

/// The shell language: words with quoting and expansions, pipelines, `&&`/`||`, redirects and
/// here-documents, `for`/`while`/`until`/`if`, `{ }` and `( )` groups, functions, and `(( ))`.
extension MiniShell {
    struct ShellError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - Words

    enum WordPart {
        case literal(String, quoted: Bool)
        case variable(String, quoted: Bool)
        case parameter(Parameter, quoted: Bool)
        case command(String, quoted: Bool)
        case arithmetic(String, quoted: Bool)
    }

    /// `${…}` forms.
    struct Parameter {
        enum Operation {
            case plain
            case length                                          // ${#v}
            case fallback(String, kind: Character, colon: Bool)  // ${v:-w} ${v-w} ${v:=w} ${v:+w} ${v:?w}
            case trim(String, suffix: Bool, longest: Bool)       // ${v#p} ${v##p} ${v%p} ${v%%p}
            case replace(String, String, all: Bool, anchor: Character?)  // ${v/p/r} ${v//p/r} ${v/#p/r} ${v/%p/r}
            case substring(String, String?)                      // ${v:offset:length}
            case changeCase(upper: Bool, all: Bool)              // ${v^^} ${v,,} ${v^} ${v,}
        }
        var name: String
        var subscript_: String?   // ${a[0]}, ${a[@]}
        var operation: Operation = .plain
        var source: String        // the text between the braces
    }

    struct Word {
        var parts: [WordPart] = []
        /// Any quoting at all: a quoted word is never a keyword, and `""` is still a word.
        var quoted = false

        /// The text when the word is a plain, unquoted literal (keywords, names).
        var plainText: String? {
            guard !quoted, parts.count == 1, case .literal(let s, quoted: false) = parts[0] else { return nil }
            return s
        }

        /// The text when the word has no expansions.
        var staticText: String? {
            var text = ""
            for part in parts {
                guard case .literal(let s, _) = part else { return nil }
                text += s
            }
            return text
        }
    }

    // MARK: - Syntax tree

    indirect enum Node {
        case simple(assignments: [Assignment], words: [Word])
        case forLoop(String, [Word]?, [Statement])
        case arithmeticFor(String, String, String, [Statement])
        case loop(condition: [Statement], body: [Statement], until: Bool)
        case ifElse([(condition: [Statement], body: [Statement])], otherwise: [Statement]?)
        case group([Statement], subshell: Bool)
        case function(String, Command)
        case arithmetic(String)
    }

    struct Assignment {
        var name: String
        var value: Word
        var array: [Word]?
        var append = false
    }

    struct Redirect {
        var op: String
        var fd: Int?
        var target: Word
    }

    struct Command {
        var node: Node
        var redirects: [Redirect] = []
    }

    struct Pipeline {
        var commands: [Command]
        var negated = false
    }

    enum Joiner { case always, and, or }

    struct Statement {
        var joiner: Joiner
        var pipeline: Pipeline
    }

    static func parse(_ source: String) throws -> [Statement] {
        let parser = Parser(tokens: try Lexer(source).run())
        return try parser.parseScript()
    }

    // MARK: - Lexer

    enum Token {
        case word(Word)
        case op(String)            // | && || ; ( )   (newlines become ";")
        case redirect(String, Int?)
        case arithmetic(String)    // (( … ))
    }

    final class Lexer {
        private let c: [Character]
        private var i = 0
        private var tokens: [Token] = []
        private var word = Word()
        private var literal = ""
        private var literalQuoted = false
        private var inWord = false
        private var doubleBracket = false
        private var pendingHeredocs: [(index: Int, delimiter: String, quoted: Bool, stripTabs: Bool)] = []

        init(_ source: String) {
            // "\r\n" is one Character in Swift; the shell wants plain newlines.
            c = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        }

        private func next(_ offset: Int = 1) -> Character? { i + offset < c.count ? c[i + offset] : nil }

        private func flushLiteral() {
            if !literal.isEmpty { word.parts.append(.literal(literal, quoted: literalQuoted)) }
            literal = ""
        }

        private func add(_ s: String, quoted: Bool) {
            if quoted != literalQuoted {
                flushLiteral()
                literalQuoted = quoted
            }
            literal += s
            inWord = true
            if quoted { word.quoted = true }
        }

        private func add(_ part: WordPart) {
            flushLiteral()
            word.parts.append(part)
            inWord = true
        }

        private func endWord() {
            flushLiteral()
            if inWord {
                if let text = word.plainText {
                    if text == "[[" { doubleBracket = true }
                    if text == "]]" { doubleBracket = false }
                }
                tokens.append(.word(word))
            }
            word = Word()
            inWord = false
        }

        func run() throws -> [Token] {
            while i < c.count {
                let ch = c[i]
                switch ch {
                case " ", "\t", "\r":
                    endWord()
                case "\n":
                    endWord()
                    tokens.append(.op(";"))
                    if !pendingHeredocs.isEmpty { try readHeredocs() }
                case "\\":
                    if let n = next() {
                        if n != "\n" { add(String(n), quoted: true) }
                        i += 1
                    }
                case "'":
                    guard let end = c[(i + 1)...].firstIndex(of: "'") else { throw ShellError("unterminated quote") }
                    add(String(c[(i + 1)..<end]), quoted: true)
                    i = end
                case "\"":
                    try doubleQuoted()
                case "$":
                    try dollar(quoted: false)
                case "`":
                    add(.command(try backtick(), quoted: false))
                case "|":
                    if doubleBracket && next() == "|" { endWord(); tokens.append(.word(plain("||"))); i += 1; break }
                    endWord()
                    if next() == "|" {
                        tokens.append(.op("||"))
                        i += 1
                    } else {
                        if next() == "&" { i += 1 }
                        tokens.append(.op("|"))
                    }
                case "&":
                    if doubleBracket && next() == "&" { endWord(); tokens.append(.word(plain("&&"))); i += 1; break }
                    endWord()
                    if next() == "&" {
                        tokens.append(.op("&&"))
                        i += 1
                    } else if next() == ">" {
                        i += 1
                        if next() == ">" { i += 1; tokens.append(.redirect("&>>", nil)) } else { tokens.append(.redirect("&>", nil)) }
                    } else {
                        tokens.append(.op(";"))   // no background jobs: run it in turn
                    }
                case ";":
                    endWord()
                    if next() == ";" { throw ShellError("case … esac isn't supported; use if/elif instead") }
                    tokens.append(.op(";"))
                case "(":
                    if doubleBracket { endWord(); tokens.append(.word(plain("("))); break }
                    if !inWord && next() == "(" {
                        endWord()
                        let start = i + 2
                        let end = try closeArithmetic(from: start)
                        tokens.append(.arithmetic(String(c[start..<end])))
                        i = end + 1
                        break
                    }
                    endWord()
                    tokens.append(.op("("))
                case ")":
                    if doubleBracket { endWord(); tokens.append(.word(plain(")"))); break }
                    endWord()
                    tokens.append(.op(")"))
                case "<":
                    if doubleBracket { endWord(); tokens.append(.word(plain("<"))); break }
                    let fd = digitWord()
                    endWord()
                    if next() == "<" && next(2) == "<" {
                        i += 2
                        tokens.append(.redirect("<<<", fd))
                    } else if next() == "<" {
                        i += 1
                        var stripTabs = false
                        if next() == "-" { stripTabs = true; i += 1 }
                        try heredocStart(stripTabs: stripTabs)
                    } else if next() == "(" {
                        throw ShellError("process substitution <(…) isn't supported; use a pipe or $(…)")
                    } else if next() == "&" {
                        i += 1
                        tokens.append(.redirect("<&", fd))
                    } else {
                        tokens.append(.redirect("<", fd))
                    }
                case ">":
                    if doubleBracket { endWord(); tokens.append(.word(plain(">"))); break }
                    let fd = digitWord()
                    endWord()
                    if next() == ">" {
                        i += 1
                        tokens.append(.redirect(">>", fd))
                    } else if next() == "&" {
                        i += 1
                        tokens.append(.redirect(">&", fd))
                    } else if next() == "(" {
                        throw ShellError("process substitution >(…) isn't supported")
                    } else {
                        if next() == "|" { i += 1 }
                        tokens.append(.redirect(">", fd))
                    }
                case "#" where !inWord:
                    while i + 1 < c.count, c[i + 1] != "\n" { i += 1 }
                default:
                    add(String(ch), quoted: false)
                }
                i += 1
            }
            endWord()
            if !pendingHeredocs.isEmpty { try readHeredocs() }
            return tokens
        }

        private func plain(_ s: String) -> Word { Word(parts: [.literal(s, quoted: false)]) }

        /// `2>` and `1>`: a word that is just a file descriptor number becomes part of the redirect.
        private func digitWord() -> Int? {
            guard inWord, word.parts.isEmpty, !word.quoted, !literalQuoted, literal == "0" || literal == "1" || literal == "2" else { return nil }
            let fd = Int(literal)
            literal = ""
            inWord = false
            return fd
        }

        private func doubleQuoted() throws {
            word.quoted = true
            inWord = true
            i += 1
            while i < c.count && c[i] != "\"" {
                let ch = c[i]
                if ch == "\\", let n = next(), "\"\\$`\n".contains(n) {
                    if n != "\n" { add(String(n), quoted: true) }
                    i += 1
                } else if ch == "$" {
                    try dollar(quoted: true)
                } else if ch == "`" {
                    add(.command(try backtick(), quoted: true))
                } else {
                    add(String(ch), quoted: true)
                }
                i += 1
            }
            guard i < c.count else { throw ShellError("unterminated quote") }
        }

        /// Reads a `$…` expansion at `i`, leaving `i` on its last character.
        private func dollar(quoted: Bool) throws {
            guard let n = next() else { add("$", quoted: quoted); return }
            switch n {
            case "(":
                if next(2) == "(" {
                    let start = i + 3
                    let end = try closeArithmetic(from: start)
                    add(.arithmetic(String(c[start..<end]), quoted: quoted))
                    i = end + 1
                } else {
                    let start = i + 2
                    let end = try closeParen(from: start)
                    add(.command(String(c[start..<end]), quoted: quoted))
                    i = end
                }
            case "{":
                let start = i + 2
                let end = try closeBrace(from: start)
                add(.parameter(try parameter(String(c[start..<end])), quoted: quoted))
                i = end
            case "'" where !quoted:
                i += 2
                var text = ""
                while i < c.count, c[i] != "'" {
                    if c[i] == "\\", i + 1 < c.count {
                        text += MiniShell.unescape("\\" + String(c[i + 1]), ansiC: true)
                        i += 2
                    } else {
                        text.append(c[i])
                        i += 1
                    }
                }
                guard i < c.count else { throw ShellError("unterminated quote") }
                add(text, quoted: true)
            case "\"" where !quoted:
                break   // $"…" is just "…"
            default:
                if n.isLetter || n == "_" {
                    var name = ""
                    while let ch = next(), ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" {
                        name.append(ch)
                        i += 1
                    }
                    add(.variable(name, quoted: quoted))
                } else if n.isNumber || "?#@*$!-".contains(n) {
                    add(.variable(String(n), quoted: quoted))
                    i += 1
                } else {
                    add("$", quoted: quoted)
                }
            }
        }

        private func backtick() throws -> String {
            var j = i + 1
            var source = ""
            while j < c.count, c[j] != "`" {
                if c[j] == "\\", j + 1 < c.count, "`\\$".contains(c[j + 1]) {
                    source.append(c[j + 1])
                    j += 2
                    continue
                }
                source.append(c[j])
                j += 1
            }
            guard j < c.count else { throw ShellError("unterminated `") }
            i = j
            return source
        }

        /// The index of the `)` closing a `$(` whose contents start at `start`.
        private func closeParen(from start: Int) throws -> Int {
            var depth = 1
            var j = start
            while j < c.count {
                switch c[j] {
                case "\\": j += 1
                case "'":
                    guard let end = c[(j + 1)...].firstIndex(of: "'") else { throw ShellError("unterminated quote") }
                    j = end
                case "\"":
                    j += 1
                    while j < c.count, c[j] != "\"" {
                        if c[j] == "\\" { j += 1 } else if c[j] == "$", j + 1 < c.count, c[j + 1] == "(" { j = try closeParen(from: j + 2) }
                        j += 1
                    }
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return j }
                default: break
                }
                j += 1
            }
            throw ShellError("missing ) to close $(")
        }

        /// The index of the first `)` of the `))` closing an arithmetic expression.
        private func closeArithmetic(from start: Int) throws -> Int {
            var depth = 0
            var j = start
            while j < c.count {
                if c[j] == "(" { depth += 1 }
                if c[j] == ")" {
                    if depth == 0 {
                        guard j + 1 < c.count, c[j + 1] == ")" else { throw ShellError("missing )) in arithmetic") }
                        return j
                    }
                    depth -= 1
                }
                j += 1
            }
            throw ShellError("missing )) in arithmetic")
        }

        private func closeBrace(from start: Int) throws -> Int {
            var depth = 1
            var j = start
            while j < c.count {
                switch c[j] {
                case "\\": j += 1
                case "'":
                    if let end = c[(j + 1)...].firstIndex(of: "'") { j = end }
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return j }
                default: break
                }
                j += 1
            }
            throw ShellError("missing } in ${")
        }

        private func parameter(_ body: String) throws -> Parameter {
            var s = Substring(body)
            var param = Parameter(name: "", source: body)
            let lengthOf = s.hasPrefix("#") && s.count > 1
            if lengthOf { s = s.dropFirst() }
            if s.hasPrefix("!") { throw ShellError("${!…} indirection isn't supported") }
            if let first = s.first, first.isLetter || first == "_" {
                let name = s.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                param.name = String(name)
                s = s.dropFirst(name.count)
            } else if let first = s.first, first.isNumber || "?#@*$!-".contains(first) {
                param.name = String(first)
                s = s.dropFirst()
            } else {
                throw ShellError("${\(body)}: bad substitution")
            }
            if s.hasPrefix("[") {
                guard let close = s.firstIndex(of: "]") else { throw ShellError("${\(body)}: bad substitution") }
                param.subscript_ = String(s[s.index(after: s.startIndex)..<close])
                s = s[s.index(after: close)...]
            }
            if lengthOf {
                guard s.isEmpty else { throw ShellError("${\(body)}: bad substitution") }
                param.operation = .length
                return param
            }
            guard let op = s.first else { return param }
            let rest = s.dropFirst()
            switch op {
            case ":":
                if let k = rest.first, "-=+?".contains(k) {
                    param.operation = .fallback(String(rest.dropFirst()), kind: k, colon: true)
                } else {
                    let pieces = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    param.operation = .substring(String(pieces[0]), pieces.count > 1 ? String(pieces[1]) : nil)
                }
            case "-", "=", "+", "?":
                param.operation = .fallback(String(rest), kind: op, colon: false)
            case "#", "%":
                let longest = rest.first == op
                param.operation = .trim(String(longest ? rest.dropFirst() : rest), suffix: op == "%", longest: longest)
            case "/":
                var pattern = rest
                var all = false
                var anchor: Character?
                if pattern.first == "/" { all = true; pattern = pattern.dropFirst() } else if let a = pattern.first, a == "#" || a == "%" { anchor = a; pattern = pattern.dropFirst() }
                var p = ""
                var replacement: String?
                var j = pattern.startIndex
                while j < pattern.endIndex {
                    let ch = pattern[j]
                    if ch == "\\", pattern.index(after: j) < pattern.endIndex {
                        p.append(ch)
                        j = pattern.index(after: j)
                        p.append(pattern[j])
                    } else if ch == "/" {
                        replacement = String(pattern[pattern.index(after: j)...])
                        break
                    } else {
                        p.append(ch)
                    }
                    j = pattern.index(after: j)
                }
                param.operation = .replace(p, replacement ?? "", all: all, anchor: anchor)
            case "^", ",":
                param.operation = .changeCase(upper: op == "^", all: rest.first == op)
            default:
                throw ShellError("${\(body)}: bad substitution")
            }
            return param
        }

        private func heredocStart(stripTabs: Bool) throws {
            i += 1
            while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
            var delimiter = ""
            var quoted = false
            while i < c.count, !" \t\n;|&<>()".contains(c[i]) {
                let ch = c[i]
                if ch == "'" || ch == "\"" {
                    quoted = true
                    guard let end = c[(i + 1)...].firstIndex(of: ch) else { throw ShellError("unterminated quote") }
                    delimiter += String(c[(i + 1)..<end])
                    i = end + 1
                } else if ch == "\\" {
                    quoted = true
                    if i + 1 < c.count { delimiter.append(c[i + 1]) }
                    i += 2
                } else {
                    delimiter.append(ch)
                    i += 1
                }
            }
            guard !delimiter.isEmpty else { throw ShellError("syntax error: missing here-document delimiter after <<") }
            i -= 1
            tokens.append(.redirect("<<", nil))
            pendingHeredocs.append((tokens.count, delimiter, quoted, stripTabs))
            tokens.append(.word(Word()))   // filled in at the end of the line
        }

        private func readHeredocs() throws {
            for heredoc in pendingHeredocs {
                var body = ""
                var found = false
                var j = i + 1
                while j < c.count {
                    var end = j
                    while end < c.count, c[end] != "\n" { end += 1 }
                    var line = String(c[j..<end])
                    if heredoc.stripTabs { line = String(line.drop { $0 == "\t" }) }
                    j = end + 1
                    if line == heredoc.delimiter { found = true; break }
                    body += line + "\n"
                }
                i = min(j, c.count) - 1
                guard found || j >= c.count else { continue }
                var word: Word
                if heredoc.quoted {
                    word = Word(parts: body.isEmpty ? [] : [.literal(body, quoted: true)], quoted: true)
                } else {
                    word = try Lexer.heredocWord(body)
                }
                word.quoted = true
                tokens[heredoc.index] = .word(word)
            }
            pendingHeredocs = []
        }

        /// A here-document body: `$` expansions and `\` escapes work, quotes are plain text.
        static func heredocWord(_ body: String) throws -> Word {
            let lexer = Lexer(body)
            lexer.word.quoted = true
            lexer.inWord = true
            while lexer.i < lexer.c.count {
                let ch = lexer.c[lexer.i]
                if ch == "\\", let n = lexer.next(), "$`\\\n".contains(n) {
                    if n != "\n" { lexer.add(String(n), quoted: true) }
                    lexer.i += 1
                } else if ch == "$" {
                    try lexer.dollar(quoted: true)
                } else if ch == "`" {
                    lexer.add(.command(try lexer.backtick(), quoted: true))
                } else {
                    lexer.add(String(ch), quoted: true)
                }
                lexer.i += 1
            }
            lexer.flushLiteral()
            return lexer.word
        }

        /// One word from text, as if it were unquoted in a command (for `${v:-text}` and patterns).
        static func singleWord(_ text: String) throws -> Word {
            let lexer = Lexer(text)
            lexer.doubleBracket = true   // operators are just characters here
            while lexer.i < lexer.c.count {
                let ch = lexer.c[lexer.i]
                switch ch {
                case "\\":
                    if let n = lexer.next() { lexer.add(String(n), quoted: true); lexer.i += 1 }
                case "'":
                    guard let end = lexer.c[(lexer.i + 1)...].firstIndex(of: "'") else { throw ShellError("unterminated quote") }
                    lexer.add(String(lexer.c[(lexer.i + 1)..<end]), quoted: true)
                    lexer.i = end
                case "\"": try lexer.doubleQuoted()
                case "$": try lexer.dollar(quoted: false)
                case "`": lexer.add(.command(try lexer.backtick(), quoted: false))
                default: lexer.add(String(ch), quoted: false)
                }
                lexer.i += 1
            }
            lexer.flushLiteral()
            lexer.word.quoted = lexer.word.quoted || lexer.inWord
            return lexer.word
        }
    }

    // MARK: - Parser

    final class Parser {
        private let tokens: [Token]
        private var p = 0

        init(tokens: [Token]) { self.tokens = tokens }

        private var atEnd: Bool { p >= tokens.count }

        private func keyword(_ index: Int) -> String? {
            guard index < tokens.count, case .word(let w) = tokens[index] else { return nil }
            return w.plainText
        }
        private var currentKeyword: String? { keyword(p) }

        private func isOp(_ s: String) -> Bool {
            guard p < tokens.count, case .op(let op) = tokens[p] else { return false }
            return op == s
        }

        private func skipSeparators() { while isOp(";") { p += 1 } }

        private func describeCurrent() -> String {
            guard p < tokens.count else { return "end of input" }
            switch tokens[p] {
            case .op(let op): return "`\(op == ";" ? "newline or ;" : op)'"
            case .word(let w): return "`\(w.staticText ?? "word")'"
            case .redirect(let op, _): return "`\(op)'"
            case .arithmetic: return "`(('"
            }
        }

        private func expectKeyword(_ k: String) throws {
            guard currentKeyword == k else { throw ShellError("syntax error near \(describeCurrent()): expected `\(k)'") }
            p += 1
        }

        private static let reserved: Set<String> = ["then", "do", "done", "fi", "elif", "else", "}", "esac", "in"]

        func parseScript() throws -> [Statement] {
            let list = try parseList(until: [])
            guard atEnd else { throw ShellError("syntax error near unexpected token \(describeCurrent())") }
            return list
        }

        private func parseList(until terminators: Set<String>, closingParen: Bool = false) throws -> [Statement] {
            var list: [Statement] = []
            var joiner = Joiner.always
            skipSeparators()
            while !atEnd {
                if let k = currentKeyword, terminators.contains(k) { break }
                if closingParen && isOp(")") { break }
                if let k = currentKeyword, Self.reserved.contains(k) {
                    throw ShellError("syntax error near unexpected token `\(k)'")
                }
                list.append(Statement(joiner: joiner, pipeline: try parsePipeline()))
                if isOp("&&") || isOp("||") {
                    joiner = isOp("&&") ? .and : .or
                    p += 1
                    skipSeparators()
                    guard !atEnd else { throw ShellError("syntax error: unexpected end of input after \(joiner == .and ? "&&" : "||")") }
                    continue
                }
                joiner = .always
                if isOp(";") {
                    skipSeparators()
                    continue
                }
                break
            }
            return list
        }

        private func parsePipeline() throws -> Pipeline {
            var negated = false
            if currentKeyword == "!" {
                negated = true
                p += 1
            }
            var commands = [try parseCommand()]
            while isOp("|") {
                p += 1
                skipSeparators()
                commands.append(try parseCommand())
            }
            return Pipeline(commands: commands, negated: negated)
        }

        private func parseCommand() throws -> Command {
            guard !atEnd else { throw ShellError("syntax error: unexpected end of input") }
            var node: Node
            switch currentKeyword {
            case "for":
                p += 1
                node = try parseFor()
            case "while", "until":
                let until = currentKeyword == "until"
                p += 1
                let condition = try parseList(until: ["do"])
                try expectKeyword("do")
                let body = try parseList(until: ["done"])
                try expectKeyword("done")
                node = .loop(condition: condition, body: body, until: until)
            case "if":
                p += 1
                node = try parseIf()
            case "{":
                p += 1
                let body = try parseList(until: ["}"])
                try expectKeyword("}")
                node = .group(body, subshell: false)
            case "case":
                throw ShellError("case … esac isn't supported; use if/elif instead")
            case "select":
                throw ShellError("select isn't supported")
            case "function":
                p += 1
                guard let name = currentKeyword else { throw ShellError("syntax error: expected a function name") }
                p += 1
                if isOp("(") {
                    p += 1
                    guard isOp(")") else { throw ShellError("syntax error near \(describeCurrent())") }
                    p += 1
                }
                skipSeparators()
                node = .function(name, try parseCommand())
            default:
                if isOp("(") {
                    p += 1
                    let body = try parseList(until: [], closingParen: true)
                    guard isOp(")") else { throw ShellError("syntax error near \(describeCurrent()): expected `)'") }
                    p += 1
                    node = .group(body, subshell: true)
                } else if case .arithmetic(let source)? = p < tokens.count ? tokens[p] : nil {
                    p += 1
                    node = .arithmetic(source)
                } else if let name = currentKeyword, isName(name), p + 2 < tokens.count,
                          case .op("(") = tokens[p + 1], case .op(")") = tokens[p + 2] {
                    p += 3
                    skipSeparators()
                    node = .function(name, try parseCommand())
                } else {
                    return try parseSimple()
                }
            }
            var redirects: [Redirect] = []
            while p < tokens.count, case .redirect = tokens[p] { redirects.append(try parseRedirect()) }
            return Command(node: node, redirects: redirects)
        }

        private func isName(_ s: String) -> Bool {
            guard let first = s.first, first.isLetter || first == "_" else { return false }
            return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        }

        private func parseFor() throws -> Node {
            if p < tokens.count, case .arithmetic(let source) = tokens[p] {
                p += 1
                let parts = source.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { throw ShellError("syntax error in for ((…)): expected three parts separated by ;") }
                skipSeparators()
                try expectKeyword("do")
                let body = try parseList(until: ["done"])
                try expectKeyword("done")
                return .arithmeticFor(parts[0], parts[1], parts[2], body)
            }
            guard let name = currentKeyword, isName(name) else {
                throw ShellError("syntax error near \(describeCurrent()): expected a variable name after `for'")
            }
            p += 1
            var items: [Word]?
            skipSeparators()
            if currentKeyword == "in" {
                p += 1
                var list: [Word] = []
                while p < tokens.count, case .word(let w) = tokens[p] {
                    list.append(w)
                    p += 1
                }
                items = list
            }
            skipSeparators()
            try expectKeyword("do")
            let body = try parseList(until: ["done"])
            try expectKeyword("done")
            return .forLoop(name, items, body)
        }

        private func parseIf() throws -> Node {
            var branches: [(condition: [Statement], body: [Statement])] = []
            var otherwise: [Statement]?
            while true {
                let condition = try parseList(until: ["then"])
                try expectKeyword("then")
                let body = try parseList(until: ["elif", "else", "fi"])
                branches.append((condition, body))
                if currentKeyword == "elif" {
                    p += 1
                    continue
                }
                if currentKeyword == "else" {
                    p += 1
                    otherwise = try parseList(until: ["fi"])
                }
                try expectKeyword("fi")
                return .ifElse(branches, otherwise: otherwise)
            }
        }

        private func parseRedirect() throws -> Redirect {
            guard case .redirect(let op, let fd) = tokens[p] else { throw ShellError("syntax error") }
            p += 1
            guard p < tokens.count, case .word(let target) = tokens[p] else {
                throw ShellError("syntax error near \(describeCurrent()): missing a target after \(op)")
            }
            p += 1
            return Redirect(op: op, fd: fd, target: target)
        }

        private func parseSimple() throws -> Command {
            var assignments: [Assignment] = []
            var words: [Word] = []
            var redirects: [Redirect] = []
            loop: while p < tokens.count {
                switch tokens[p] {
                case .word(let w):
                    if words.isEmpty, var assignment = MiniShell.assignment(w) {
                        p += 1
                        if assignment.value.parts.isEmpty, isOp("(") {
                            p += 1
                            var items: [Word] = []
                            while p < tokens.count {
                                if isOp(")") { break }
                                if isOp(";") { p += 1; continue }
                                guard case .word(let item) = tokens[p] else { throw ShellError("syntax error in array assignment") }
                                items.append(item)
                                p += 1
                            }
                            guard isOp(")") else { throw ShellError("syntax error: missing ) in array assignment") }
                            p += 1
                            assignment.array = items
                        }
                        assignments.append(assignment)
                    } else {
                        words.append(w)
                        p += 1
                    }
                case .redirect:
                    redirects.append(try parseRedirect())
                case .arithmetic(let source):
                    // `echo ((1))` isn't valid; treat the text literally.
                    words.append(Word(parts: [.literal("((\(source)))", quoted: true)], quoted: true))
                    p += 1
                case .op:
                    break loop
                }
            }
            guard !(words.isEmpty && assignments.isEmpty && redirects.isEmpty) else {
                throw ShellError("syntax error near unexpected token \(describeCurrent())")
            }
            return Command(node: .simple(assignments: assignments, words: words), redirects: redirects)
        }
    }

    /// `NAME=value` or `NAME+=value` at the start of an unquoted word.
    static func assignment(_ word: Word) -> Assignment? {
        guard case .literal(let text, quoted: false)? = word.parts.first, let eq = text.firstIndex(of: "=") else { return nil }
        var name = String(text[..<eq])
        var append = false
        if name.hasSuffix("+") {
            append = true
            name.removeLast()
        }
        guard let first = name.first, first.isLetter || first == "_",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        var value = Word(parts: Array(word.parts.dropFirst()), quoted: word.quoted)
        let rest = String(text[text.index(after: eq)...])
        if !rest.isEmpty { value.parts.insert(.literal(rest, quoted: false), at: 0) }
        return Assignment(name: name, value: value, append: append)
    }

    // MARK: - Static checks

    /// Whether the line can reach the network: only curl and wget can, possibly through xargs or a
    /// function. A command named by an expansion, or a line that doesn't parse, counts as yes.
    static func reachesNetwork(_ line: String) -> Bool {
        guard let script = try? parse(line) else { return true }
        return reaches(script)
    }

    private static let networkCommands: Set<String> = ["curl", "wget"]

    private static func reaches(_ list: [Statement]) -> Bool {
        list.contains { $0.pipeline.commands.contains(where: reaches) }
    }

    private static func reaches(_ command: Command) -> Bool {
        if command.redirects.contains(where: { reaches($0.target) }) { return true }
        switch command.node {
        case .simple(let assignments, let words):
            if assignments.contains(where: { reaches($0.value) || ($0.array ?? []).contains(where: reaches) }) { return true }
            if words.contains(where: reaches) { return true }
            guard let first = words.first else { return false }
            guard let name = first.staticText else { return true }
            if networkCommands.contains(name) { return true }
            if name == "xargs" || name == "command" || name == "env" || name == "time" || name == "nohup" || name == "timeout" {
                return words.dropFirst().contains { word in
                    guard let text = word.staticText else { return true }
                    return networkCommands.contains(text)
                }
            }
            return false
        case .forLoop(_, let items, let body):
            return (items ?? []).contains(where: reaches) || reaches(body)
        case .arithmeticFor(let a, let b, let c, let body):
            return [a, b, c].contains(where: arithmeticReaches) || reaches(body)
        case .loop(let condition, let body, _):
            return reaches(condition) || reaches(body)
        case .ifElse(let branches, let otherwise):
            return branches.contains { reaches($0.condition) || reaches($0.body) } || reaches(otherwise ?? [])
        case .group(let body, _):
            return reaches(body)
        case .function(_, let body):
            return reaches(body)
        case .arithmetic(let source):
            return arithmeticReaches(source)
        }
    }

    private static func reaches(_ word: Word) -> Bool {
        word.parts.contains { part in
            switch part {
            case .literal, .variable: return false
            case .command(let source, _): return reachesNetwork(source)
            case .arithmetic(let source, _): return arithmeticReaches(source)
            case .parameter(let param, _): return param.source.contains("$(") || param.source.contains("`") ? reachesNetwork(param.source) : false
            }
        }
    }

    private static func arithmeticReaches(_ source: String) -> Bool {
        source.contains("$(") || source.contains("`") ? reachesNetwork("echo \(source)") : false
    }
}
