import Foundation

/// Lightweight regex-based tokenizer for syntax highlighting.
/// Produces non-overlapping (range, kind) spans in UTF-16 offsets.
enum SyntaxTokenizer {
    enum Kind: Equatable { case keyword, string, comment, number, type, function, attribute, tag, property }

    struct Token: Equatable {
        var range: NSRange
        var kind: Kind
    }

    private struct LanguageSpec {
        var keywords: Set<String>
        var lineComment: [String]
        var blockComment: (String, String)?
        var stringDelims: String = "\"'"
        var backtickStrings = false
        var tripleQuotes = false
        var hashComments: Bool { lineComment.contains("#") }
    }

    static func normalize(_ lang: String) -> String {
        let l = lang.lowercased().trimmingCharacters(in: .whitespaces)
        switch l {
        case "js", "javascript", "jsx", "mjs", "node": return "javascript"
        case "ts", "typescript", "tsx": return "typescript"
        case "py", "python", "python3": return "python"
        case "sh", "bash", "zsh", "shell", "console", "terminal": return "bash"
        case "c++", "cpp", "cc", "hpp", "h", "c", "objc", "objective-c", "objectivec": return "c"
        case "cs", "csharp", "c#": return "csharp"
        case "kt", "kotlin": return "kotlin"
        case "rs", "rust": return "rust"
        case "rb", "ruby": return "ruby"
        case "yml", "yaml": return "yaml"
        case "html", "xml", "svg", "xhtml", "vue": return "html"
        case "golang", "go": return "go"
        case "md", "markdown": return "markdown"
        default: return l
        }
    }

    private static let cKeywords: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "true", "false", "nullptr", "using", "include", "define", "bool", "try", "catch", "throw", "constexpr", "noexcept", "std"]

    private static func spec(for lang: String) -> LanguageSpec? {
        switch lang {
        case "swift":
            return LanguageSpec(keywords: ["import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "true", "false", "nil", "self", "Self", "init", "deinit", "throws", "throw", "try", "catch", "do", "async", "await", "public", "private", "fileprivate", "internal", "open", "static", "final", "override", "mutating", "some", "any", "where", "typealias", "associatedtype", "inout", "defer", "lazy", "weak", "unowned", "actor", "nonisolated", "get", "set", "willSet", "didSet", "is", "as", "super", "subscript", "operator", "convenience", "required", "rethrows", "consuming", "borrowing"],
                                lineComment: ["//"], blockComment: ("/*", "*/"), stringDelims: "\"", tripleQuotes: true)
        case "python":
            return LanguageSpec(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False", "global", "nonlocal", "assert", "del", "async", "await", "self", "print", "match", "case"],
                                lineComment: ["#"], blockComment: nil, tripleQuotes: true)
        case "javascript", "typescript":
            return LanguageSpec(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "true", "false", "null", "undefined", "yield", "static", "get", "set", "delete", "void", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "keyof", "declare", "namespace", "abstract", "satisfies"],
                                lineComment: ["//"], blockComment: ("/*", "*/"), backtickStrings: true)
        case "java", "kotlin", "csharp", "dart", "scala":
            return LanguageSpec(keywords: ["public", "private", "protected", "class", "interface", "enum", "static", "final", "void", "int", "long", "double", "float", "boolean", "bool", "char", "byte", "short", "string", "String", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "super", "extends", "implements", "import", "package", "try", "catch", "finally", "throw", "throws", "true", "false", "null", "val", "var", "fun", "object", "when", "is", "as", "in", "override", "abstract", "sealed", "data", "suspend", "using", "namespace", "async", "await", "const", "let", "def", "lazy", "open", "internal", "init"],
                                lineComment: ["//"], blockComment: ("/*", "*/"), tripleQuotes: lang == "kotlin")
        case "c":
            return LanguageSpec(keywords: cKeywords, lineComment: ["//"], blockComment: ("/*", "*/"))
        case "go":
            return LanguageSpec(keywords: ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "select", "struct", "interface", "map", "type", "var", "const", "true", "false", "nil", "make", "new", "len", "append", "string", "int", "error", "bool", "byte", "float64", "fallthrough", "goto"],
                                lineComment: ["//"], blockComment: ("/*", "*/"), backtickStrings: true)
        case "rust":
            return LanguageSpec(keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "return", "if", "else", "match", "for", "while", "loop", "in", "break", "continue", "true", "false", "as", "ref", "move", "where", "async", "await", "dyn", "unsafe", "type", "Some", "None", "Ok", "Err", "Box", "Vec", "String"],
                                lineComment: ["//"], blockComment: ("/*", "*/"), stringDelims: "\"")
        case "ruby":
            return LanguageSpec(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "true", "false", "nil", "self", "require", "attr_accessor", "puts", "and", "or", "not", "then", "case", "when", "lambda", "proc"],
                                lineComment: ["#"], blockComment: nil)
        case "php":
            return LanguageSpec(keywords: ["function", "return", "if", "else", "elseif", "foreach", "for", "while", "as", "echo", "class", "public", "private", "protected", "static", "new", "true", "false", "null", "use", "namespace", "array", "isset", "require", "include", "try", "catch", "throw"],
                                lineComment: ["//", "#"], blockComment: ("/*", "*/"))
        case "sql":
            let kw = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "distinct", "count", "sum", "avg", "min", "max", "primary", "key", "foreign", "references", "index", "union", "all", "case", "when", "then", "else", "end", "desc", "asc", "with", "default", "integer", "text", "varchar", "boolean", "exists"]
            return LanguageSpec(keywords: Set(kw + kw.map { $0.uppercased() }), lineComment: ["--"], blockComment: ("/*", "*/"))
        case "bash":
            return LanguageSpec(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "echo", "cd", "sudo", "exit", "source", "alias", "unset", "read", "set", "brew", "npm", "pip", "git", "curl", "cat", "ls", "mkdir", "rm", "cp", "mv"],
                                lineComment: ["#"], blockComment: nil)
        case "yaml", "toml", "ini":
            return LanguageSpec(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComment: ["#"], blockComment: nil)
        case "css", "scss", "less":
            return LanguageSpec(keywords: ["important", "media", "import", "from", "to", "keyframes", "root"], lineComment: lang == "css" ? [] : ["//"], blockComment: ("/*", "*/"))
        case "json":
            return LanguageSpec(keywords: ["true", "false", "null"], lineComment: [], blockComment: nil, stringDelims: "\"")
        default:
            return nil
        }
    }

    static func tokenize(_ code: String, language: String) -> [Token] {
        let lang = normalize(language)
        let ns = code as NSString
        let length = ns.length
        guard length > 0, length < 60_000 else { return [] }
        var claimed = [Bool](repeating: false, count: length)
        var tokens: [Token] = []

        func claim(_ regex: NSRegularExpression, _ kind: Kind, group: Int = 0) {
            for m in regex.matches(in: code, range: NSRange(location: 0, length: length)) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                var free = true
                for i in r.location..<(r.location + r.length) where claimed[i] { free = false; break }
                guard free else { continue }
                for i in r.location..<(r.location + r.length) { claimed[i] = true }
                tokens.append(Token(range: r, kind: kind))
            }
        }
        func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: p, options: opts)
        }

        if lang == "html" {
            if let r = re("<!--[\\s\\S]*?(-->|$)") { claim(r, .comment) }
            if let r = re("\"[^\"]*\"|'[^']*'") { claim(r, .string) }
            if let r = re("</?([A-Za-z][A-Za-z0-9-]*)") { claim(r, .tag, group: 1) }
            if let r = re("\\s([A-Za-z_:][A-Za-z0-9_:.-]*)(?==)") { claim(r, .attribute, group: 1) }
            return tokens.sorted { $0.range.location < $1.range.location }
        }

        guard let spec = spec(for: lang) else {
            // Generic fallback: strings + numbers + common comments.
            if let r = re("//[^\\n]*|#[^\\n]*") { claim(r, .comment) }
            if let r = re("\"(?:\\\\.|[^\"\\\\\\n])*\"?") { claim(r, .string) }
            if let r = re("\\b\\d+(?:\\.\\d+)?\\b") { claim(r, .number) }
            return tokens.sorted { $0.range.location < $1.range.location }
        }

        // 1. Comments and strings (order matters: whichever starts first wins via claiming).
        var patterns: [(String, Kind)] = []
        if let (open, close) = spec.blockComment {
            patterns.append((NSRegularExpression.escapedPattern(for: open) + "[\\s\\S]*?(?:" + NSRegularExpression.escapedPattern(for: close) + "|$)", .comment))
        }
        for lc in spec.lineComment {
            patterns.append((NSRegularExpression.escapedPattern(for: lc) + "[^\\n]*", .comment))
        }
        if spec.tripleQuotes {
            patterns.append(("\"\"\"[\\s\\S]*?(?:\"\"\"|$)", .string))
            if lang == "python" { patterns.append(("'''[\\s\\S]*?(?:'''|$)", .string)) }
        }
        if spec.backtickStrings { patterns.append(("`(?:\\\\.|[^`\\\\])*`?", .string)) }
        for d in spec.stringDelims {
            let q = NSRegularExpression.escapedPattern(for: String(d))
            patterns.append((q + "(?:\\\\.|[^" + q + "\\\\\\n])*" + q + "?", .string))
        }
        // Combine into one alternation so the earliest match wins.
        let combined = patterns.map { "(" + $0.0 + ")" }.joined(separator: "|")
        if let r = re(combined) {
            for m in r.matches(in: code, range: NSRange(location: 0, length: length)) {
                for (idx, p) in patterns.enumerated() {
                    let gr = m.range(at: idx + 1)
                    if gr.location != NSNotFound, gr.length > 0 {
                        for i in gr.location..<(gr.location + gr.length) { claimed[i] = true }
                        tokens.append(Token(range: gr, kind: p.1))
                        break
                    }
                }
            }
        }

        if lang == "json" {
            if let r = re("(\"(?:\\\\.|[^\"\\\\])*\")\\s*:") {
                // Re-tag keys as properties.
                for m in r.matches(in: code, range: NSRange(location: 0, length: length)) {
                    let kr = m.range(at: 1)
                    if let idx = tokens.firstIndex(where: { $0.range == kr }) { tokens[idx].kind = .property }
                }
            }
        }

        // 2. Attributes / decorators.
        if let r = re("@[A-Za-z_][A-Za-z0-9_]*") { claim(r, .attribute) }
        // 3. Numbers.
        if let r = re("\\b(?:0x[0-9A-Fa-f_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b") { claim(r, .number) }
        // 4. Keywords.
        if !spec.keywords.isEmpty, let r = re("\\b[A-Za-z_][A-Za-z0-9_]*\\b") {
            for m in r.matches(in: code, range: NSRange(location: 0, length: length)) {
                let word = ns.substring(with: m.range)
                guard spec.keywords.contains(word) else { continue }
                var free = true
                for i in m.range.location..<(m.range.location + m.range.length) where claimed[i] { free = false; break }
                guard free else { continue }
                for i in m.range.location..<(m.range.location + m.range.length) { claimed[i] = true }
                tokens.append(Token(range: m.range, kind: .keyword))
            }
        }
        // 5. Function calls, then capitalized types.
        if let r = re("\\b([A-Za-z_][A-Za-z0-9_]*)\\s*(?=\\()") { claim(r, .function, group: 1) }
        if lang != "sql", let r = re("\\b[A-Z][A-Za-z0-9_]*\\b") { claim(r, .type) }
        if lang == "css", let r = re("([a-z-]+)\\s*:") { claim(r, .property, group: 1) }
        if lang == "yaml", let r = re("^\\s*([A-Za-z0-9_.-]+)\\s*:", [.anchorsMatchLines]) { claim(r, .property, group: 1) }

        return tokens.sorted { $0.range.location < $1.range.location }
    }
}
