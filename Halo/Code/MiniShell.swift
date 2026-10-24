import Foundation

struct ShellResult: Sendable {
    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = 0
    /// Status of the last HTTP response, for the card's summary line.
    var httpStatus: Int?
    var duration: TimeInterval = 0

    static let modelLimit = 16_000

    /// Compact text given back to the model.
    var modelSummary: String {
        var parts = ["exit code: \(exitCode)"]
        if !stdout.isEmpty {
            var out = String(stdout.prefix(Self.modelLimit))
            if stdout.count > Self.modelLimit {
                out += "\n… [truncated: \(stdout.count - Self.modelLimit) more characters. Narrow it down with jq, grep or head.]"
            }
            parts.append("stdout:\n" + out)
        }
        if !stderr.isEmpty { parts.append("stderr:\n" + String(stderr.prefix(4000))) }
        if stdout.isEmpty && stderr.isEmpty { parts.append("(no output)") }
        return parts.joined(separator: "\n\n")
    }

    var consoleText: String {
        let text = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: stdout.hasSuffix("\n") ? "" : "\n")
        if text.isEmpty { return "(no output)" }
        return text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text
    }
}

/// A small pretend shell for the `shell` tool: enough to call web APIs (curl, wget) and trim what
/// comes back (jq, grep, head…). There is no filesystem and no processes; every command lives here.
enum MiniShell {
    static let commandNames = ["curl", "wget", "jq", "grep", "head", "tail", "wc", "sort", "uniq", "cat",
                               "echo", "printf", "base64", "date", "sleep", "export", "true", "false", "help"]
    static let downloadLimit = 4 << 20
    static let userAgent = "curl/8.7.1"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Whether the line can reach the network: only curl and wget can, as there are no files or other
    /// programs. A command named by a variable, or a line that doesn't parse, counts as yes.
    static func reachesNetwork(_ line: String) -> Bool {
        guard let statements = try? parse(tokenize(line)) else { return true }
        return statements.contains { statement in
            statement.pipeline.contains { command in
                guard let name = command.words.first else { return false }
                return name.contains(varMark) || name == "curl" || name == "wget"
            }
        }
    }

    static func run(_ line: String) async -> ShellResult {
        let start = Date()
        var result = ShellResult()
        do {
            let statements = try parse(tokenize(line))
            var env: [String: String] = [:]
            var status: Int32 = 0
            for statement in statements {
                if statement.joiner == .and && status != 0 { continue }
                if statement.joiner == .or && status == 0 { continue }
                if Task.isCancelled {
                    result.stderr += "Cancelled.\n"
                    status = 130
                    break
                }
                status = await run(statement.pipeline, env: &env, result: &result)
                env["?"] = String(status)
            }
            result.exitCode = status
        } catch {
            result.stderr += "sh: \(error.localizedDescription)\n"
            result.exitCode = 2
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    // MARK: - Parsing

    struct ShellError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    enum Token: Equatable {
        case word(String)
        case op(String)        // | && || ;
        case redirect(Int)     // 1 or 2; 0 means both (&>)
    }

    /// Stands in for `$NAME` until the command runs, since earlier commands can set variables.
    private static let varMark: Character = "\u{1}"

    static func tokenize(_ line: String) throws -> [Token] {
        let chars = Array(line)
        var tokens: [Token] = []
        var word = ""
        var inWord = false
        var i = 0

        func flush() {
            if inWord { tokens.append(.word(word)) }
            word = ""
            inWord = false
        }
        func next(_ offset: Int = 1) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
        /// Reads a `$…` reference at `i`, leaving `i` on its last character.
        func variable() throws {
            guard let n = next() else { word.append("$"); return }
            if n == "(" { throw ShellError("command substitution $(…) isn't supported") }
            if n == "{" {
                guard let end = chars[(i + 2)...].firstIndex(of: "}") else { throw ShellError("missing }") }
                word += "\(varMark)\(String(chars[(i + 2)..<end]))\(varMark)"
                i = end
            } else if n == "?" {
                word += "\(varMark)?\(varMark)"
                i += 1
            } else if n.isLetter || n == "_" {
                var name = ""
                while let c = next(), c.isLetter || c.isNumber || c == "_" { name.append(c); i += 1 }
                word += "\(varMark)\(name)\(varMark)"
            } else {
                word.append("$")
            }
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\r":
                flush()
            case "\n":
                flush()
                tokens.append(.op(";"))
            case "\\":
                if let n = next() {
                    if n != "\n" { word.append(n); inWord = true }
                    i += 1
                }
            case "'":
                guard let end = chars[(i + 1)...].firstIndex(of: "'") else { throw ShellError("unterminated quote") }
                word += String(chars[(i + 1)..<end])
                inWord = true
                i = end
            case "\"":
                inWord = true
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\", let n = next(), "\"\\$`\n".contains(n) {
                        if n != "\n" { word.append(n) }
                        i += 1
                    } else if chars[i] == "$" {
                        try variable()
                    } else if chars[i] == "`" {
                        throw ShellError("command substitution `…` isn't supported")
                    } else {
                        word.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { throw ShellError("unterminated quote") }
            case "$":
                inWord = true
                try variable()
            case "`":
                throw ShellError("command substitution `…` isn't supported")
            case "|":
                flush()
                if next() == "|" { tokens.append(.op("||")); i += 1 } else { tokens.append(.op("|")) }
            case "&":
                flush()
                if next() == "&" { tokens.append(.op("&&")); i += 1 }
                else if next() == ">" { tokens.append(.redirect(0)); i += 1; if next() == ">" { i += 1 } }
                else { tokens.append(.op(";")) }
            case ";":
                flush()
                tokens.append(.op(";"))
            case "<":
                throw ShellError("input redirection isn't supported; pipe text in with echo instead")
            case ">":
                var fd = 1
                if inWord && (word == "1" || word == "2") { fd = Int(word)!; word = ""; inWord = false }
                flush()
                tokens.append(.redirect(fd))
                if next() == ">" { i += 1 }
                if next() == "&", let d = next(2), d.isNumber {
                    tokens.append(.word("&\(d)"))
                    i += 2
                }
            case "#" where !inWord:
                i = chars.count
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        flush()
        return tokens
    }

    struct Command {
        var words: [String] = []
        var assignments: [(String, String)] = []
        var dropStdout = false
        var dropStderr = false
        var stderrToStdout = false
    }

    enum Joiner { case always, and, or }

    struct Statement {
        var joiner: Joiner
        var pipeline: [Command]
    }

    static func parse(_ tokens: [Token]) throws -> [Statement] {
        var statements: [Statement] = []
        var joiner = Joiner.always
        var pipeline: [Command] = []
        var command = Command()
        var i = 0

        func endCommand() throws {
            guard !command.words.isEmpty || !command.assignments.isEmpty else { throw ShellError("syntax error near unexpected operator") }
            pipeline.append(command)
            command = Command()
        }
        func endStatement() throws {
            try endCommand()
            statements.append(Statement(joiner: joiner, pipeline: pipeline))
            pipeline = []
        }

        while i < tokens.count {
            switch tokens[i] {
            case .word(let w):
                if command.words.isEmpty, let eq = w.firstIndex(of: "="), eq != w.startIndex,
                   w[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    command.assignments.append((String(w[..<eq]), String(w[w.index(after: eq)...])))
                } else {
                    command.words.append(w)
                }
            case .redirect(let fd):
                guard i + 1 < tokens.count, case .word(let target) = tokens[i + 1] else { throw ShellError("missing redirect target") }
                i += 1
                if target == "/dev/null" {
                    if fd != 2 { command.dropStdout = true }
                    if fd != 1 { command.dropStderr = true }
                } else if target == "&1" && fd == 2 {
                    command.stderrToStdout = true
                } else if target != "&2" {
                    throw ShellError("there is no filesystem, so output can't go to \(target). It comes back to you directly.")
                }
            case .op("|"):
                try endCommand()
            case .op(let op):
                if command.words.isEmpty && command.assignments.isEmpty && pipeline.isEmpty && op == ";" { break }
                try endStatement()
                joiner = op == "&&" ? .and : op == "||" ? .or : .always
            }
            i += 1
        }
        if !command.words.isEmpty || !command.assignments.isEmpty || !pipeline.isEmpty { try endStatement() }
        return statements
    }

    private static func expand(_ word: String, _ env: [String: String]) -> String {
        guard word.contains(varMark) else { return word }
        let parts = word.split(separator: varMark, omittingEmptySubsequences: false)
        // Odd parts are variable names.
        return parts.enumerated().map { $0.offset.isMultiple(of: 2) ? String($0.element) : env[String($0.element)] ?? "" }.joined()
    }

    // MARK: - Running

    struct Output {
        var stdout = ""
        var stderr = ""
        var status: Int32 = 0
    }

    private static func run(_ pipeline: [Command], env: inout [String: String], result: inout ShellResult) async -> Int32 {
        var input = ""
        var status: Int32 = 0
        for command in pipeline {
            for (name, value) in command.assignments { env[name] = expand(value, env) }
            let words = command.words.map { expand($0, env) }
            guard let name = words.first else { continue }
            var out: Output
            if name == "export" {
                for arg in words.dropFirst() {
                    if let eq = arg.firstIndex(of: "=") { env[String(arg[..<eq])] = String(arg[arg.index(after: eq)...]) }
                }
                out = Output()
            } else {
                out = await builtin(name, Array(words.dropFirst()), stdin: input, result: &result)
            }
            if command.stderrToStdout { out.stdout += out.stderr; out.stderr = "" }
            if command.dropStdout { out.stdout = "" }
            if command.dropStderr { out.stderr = "" }
            result.stderr += out.stderr
            input = out.stdout
            status = out.status
        }
        result.stdout += input
        return status
    }

    private static func builtin(_ name: String, _ args: [String], stdin: String, result: inout ShellResult) async -> Output {
        switch name {
        case "curl": return await curl(args, stdin: stdin, result: &result)
        case "wget": return await wget(args, stdin: stdin, result: &result)
        case "jq": return jq(args, stdin: stdin)
        case "grep", "egrep", "fgrep": return grep(args, stdin: stdin, fixed: name == "fgrep")
        case "head", "tail": return headTail(args, stdin: stdin, head: name == "head")
        case "wc": return wc(args, stdin: stdin)
        case "sort": return sort(args, stdin: stdin)
        case "uniq": return uniq(args, stdin: stdin)
        case "cat":
            if args.contains(where: { $0 != "-" }) { return fail("cat: there is no filesystem; pipe text in instead") }
            return Output(stdout: stdin)
        case "echo": return echo(args)
        case "printf": return printf(args)
        case "base64": return base64(args, stdin: stdin)
        case "date": return date(args)
        case "sleep":
            let seconds = min(Double(args.first ?? "0") ?? 0, 10)
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            return Output()
        case "true": return Output()
        case "false": return Output(status: 1)
        case "help": return Output(stdout: help)
        default:
            return Output(stderr: "sh: \(name): command not found. This is a minimal shell with only: \(commandNames.joined(separator: ", ")).\n", status: 127)
        }
    }

    static let help = """
    A minimal shell for calling web APIs. No filesystem, no other programs.
    Commands: \(commandNames.joined(separator: ", "))
    Pipes (|), &&, ||, ;, NAME=value and $NAME work; redirects only to /dev/null or 2>&1.
    curl: -X -H -d/--data(-raw|-binary|-urlencode) --json -G -i -I -s -f -L -u -A -m -w -o /dev/null. Data @- reads stdin.
    URLs without a scheme get https://; plain http:// only works on the local network.
    jq: paths (.a.b, .[0], .[], .[2:5]), |, commas, [..], {a, b: .c}, map(), keys, length, type, first, last; -r -c.

    """

    private static func fail(_ message: String, status: Int32 = 1) -> Output {
        Output(stderr: message + "\n", status: status)
    }

    private static func lines(_ text: String) -> [Substring] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    private static func joinLines<S: StringProtocol>(_ lines: [S]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Splits `-abc` style flags; options in `valued` take the rest of the word or the next one.
    private static func options(_ args: [String], valued: Set<Character>, long: [String: Character] = [:]) throws -> (flags: [(Character, String?)], operands: [String]) {
        var flags: [(Character, String?)] = []
        var operands: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { operands += args[(i + 1)...]; break }
            if a.hasPrefix("--") {
                var key = String(a.dropFirst(2))
                var value: String?
                if let eq = key.firstIndex(of: "=") { value = String(key[key.index(after: eq)...]); key = String(key[..<eq]) }
                guard let short = long[key] else { throw ShellError("unknown option --\(key)") }
                if valued.contains(short) && value == nil {
                    guard i + 1 < args.count else { throw ShellError("option --\(key) needs a value") }
                    i += 1
                    value = args[i]
                }
                flags.append((short, value))
            } else if a.hasPrefix("-") && a.count > 1 {
                let body = Array(a.dropFirst())
                var j = 0
                while j < body.count {
                    let c = body[j]
                    if valued.contains(c) {
                        var value = String(body[(j + 1)...])
                        if value.isEmpty {
                            guard i + 1 < args.count else { throw ShellError("option -\(c) needs a value") }
                            i += 1
                            value = args[i]
                        }
                        flags.append((c, value))
                        break
                    }
                    flags.append((c, nil))
                    j += 1
                }
            } else {
                operands.append(a)
            }
            i += 1
        }
        return (flags, operands)
    }

    // MARK: - curl / wget

    private static let curlLong: [String: Character] = [
        "request": "X", "header": "H", "data": "d", "data-raw": "d", "data-binary": "d", "data-ascii": "d",
        "data-urlencode": "U", "json": "J", "user": "u", "user-agent": "A", "max-time": "m", "connect-timeout": "m",
        "output": "o", "write-out": "w", "url": "R", "referer": "e", "cookie": "b", "form": "F",
        "include": "i", "head": "I", "silent": "s", "show-error": "S", "fail": "f", "fail-with-body": "f",
        "location": "L", "get": "G", "insecure": "k", "compressed": "z", "verbose": "v", "globoff": "g",
        "http1.1": "z", "http2": "z", "no-progress-meter": "s", "retry": "y", "max-redirs": "y",
    ]

    private struct HTTPCall {
        var method: String?
        var headers: [(String, String)] = []
        var data: [String] = []
        var url = ""
        var json = false
        var asQuery = false
        var timeout: TimeInterval = 30
        var user: String?
    }

    private static func curl(_ args: [String], stdin: String, result: inout ShellResult) async -> Output {
        let parsed: (flags: [(Character, String?)], operands: [String])
        do {
            parsed = try options(args, valued: ["X", "H", "d", "U", "J", "u", "A", "m", "o", "w", "R", "e", "b", "F", "y"], long: curlLong)
        } catch {
            return fail("curl: \(error.localizedDescription)", status: 2)
        }
        var call = HTTPCall()
        var include = false, headOnly = false, failOnError = false, discardBody = false
        var writeOut: String?
        var urls = parsed.operands
        for (flag, value) in parsed.flags {
            let v = value ?? ""
            switch flag {
            case "X": call.method = v.uppercased()
            case "H":
                guard let colon = v.firstIndex(of: ":") else { continue }
                call.headers.append((v[..<colon].trimmingCharacters(in: .whitespaces), v[v.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            case "d", "J", "U":
                var body = v
                if v == "@-" { body = stdin.hasSuffix("\n") ? String(stdin.dropLast()) : stdin }
                else if v.hasPrefix("@") { return fail("curl: there is no filesystem; pass the data inline or pipe it in with -d @-", status: 26) }
                if flag == "U" {
                    if let eq = body.firstIndex(of: "=") {
                        body = String(body[...eq]) + formEncode(String(body[body.index(after: eq)...]))
                    } else {
                        body = formEncode(body)
                    }
                }
                if flag == "J" { call.json = true }
                call.data.append(body)
            case "u": call.user = v
            case "A": call.headers.append(("User-Agent", v))
            case "e": call.headers.append(("Referer", v))
            case "b": call.headers.append(("Cookie", v))
            case "m": call.timeout = min(max(Double(v) ?? 30, 1), 60)
            case "o":
                if v == "/dev/null" { discardBody = true }
                else if v != "-" { return fail("curl: there is no filesystem; drop -o and the body comes back to you", status: 23) }
            case "w": writeOut = v
            case "R": urls.append(v)
            case "F": return fail("curl: multipart forms (-F) aren't supported; send JSON or -d form data instead", status: 2)
            case "i", "v": include = true
            case "I": headOnly = true
            case "f": failOnError = true
            case "G": call.asQuery = true
            case "s", "S", "L", "k", "z", "g", "y", "#", "N", "4", "6": break
            default: return fail("curl: option -\(flag) isn't supported here. Try `help`.", status: 2)
            }
        }
        guard let url = urls.first else { return fail("curl: no URL specified", status: 2) }
        call.url = url
        if headOnly && call.method == nil { call.method = "HEAD" }

        var output = Output()
        let response: HTTPResponse
        do {
            response = try await perform(call)
        } catch let error as ShellError {
            return fail("curl: \(error.message)", status: 3)
        } catch {
            return fail(curlMessage(error), status: curlCode(error))
        }
        result.httpStatus = response.status
        if failOnError && response.status >= 400 {
            return fail("curl: (22) The requested URL returned error: \(response.status)", status: 22)
        }
        if include || headOnly { output.stdout += response.headerText + "\n" }
        if !headOnly && !discardBody { output.stdout += response.bodyText }
        if let writeOut {
            output.stdout += writeOut
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "%{http_code}", with: String(response.status))
                .replacingOccurrences(of: "%{response_code}", with: String(response.status))
                .replacingOccurrences(of: "%{time_total}", with: String(format: "%.3f", response.duration))
                .replacingOccurrences(of: "%{size_download}", with: String(response.size))
                .replacingOccurrences(of: "%{content_type}", with: response.contentType ?? "")
                .replacingOccurrences(of: "%{url_effective}", with: response.finalURL)
        }
        return output
    }

    private static func wget(_ args: [String], stdin: String, result: inout ShellResult) async -> Output {
        // wget prints to stdout here: there's nowhere else for it to go.
        var curlArgs: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-O", "--output-document", "-o", "--output-file", "-t", "--tries", "-T", "--timeout":
                if a == "-T" || a == "--timeout", i + 1 < args.count { curlArgs += ["-m", args[i + 1]] }
                i += 1
            case "--header": if i + 1 < args.count { curlArgs += ["-H", args[i + 1]]; i += 1 }
            case "--method": if i + 1 < args.count { curlArgs += ["-X", args[i + 1]]; i += 1 }
            case "--post-data", "--body-data": if i + 1 < args.count { curlArgs += ["-d", args[i + 1]]; i += 1 }
            case "-S", "--server-response": curlArgs.append("-i")
            default:
                if let eq = a.firstIndex(of: "="), a.hasPrefix("--") {
                    let key = a[..<eq], value = String(a[a.index(after: eq)...])
                    switch key {
                    case "--header": curlArgs += ["-H", value]
                    case "--method": curlArgs += ["-X", value]
                    case "--post-data", "--body-data": curlArgs += ["-d", value]
                    case "--timeout": curlArgs += ["-m", value]
                    default: break
                    }
                } else if !a.hasPrefix("-") {
                    curlArgs.append(a)
                }
            }
            i += 1
        }
        var out = await curl(curlArgs, stdin: stdin, result: &result)
        out.stderr = out.stderr.replacingOccurrences(of: "curl:", with: "wget:")
        return out
    }

    private struct HTTPResponse {
        var status: Int
        var headerText: String
        var bodyText: String
        var size: Int
        var contentType: String?
        var finalURL: String
        var duration: TimeInterval
    }

    private static func makeURL(_ raw: String, query: [String]) throws -> URL {
        var text = raw.contains("://") ? raw : "https://" + raw
        if !query.isEmpty { text += (text.contains("?") ? "&" : "?") + query.joined(separator: "&") }
        if let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["#", "%"])).flatMap(URL.init(string:)),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil {
            return url
        }
        throw ShellError("(3) URL rejected: \(raw)")
    }

    private static func perform(_ call: HTTPCall) async throws -> HTTPResponse {
        let url = try makeURL(call.url, query: call.asQuery ? call.data : [])
        var request = URLRequest(url: url, timeoutInterval: call.timeout)
        let hasBody = !call.data.isEmpty && !call.asQuery
        request.httpMethod = call.method ?? (hasBody ? "POST" : "GET")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if hasBody {
            request.httpBody = Data(call.data.joined(separator: call.json ? "" : "&").utf8)
            request.setValue(call.json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if call.json { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        if let user = call.user {
            request.setValue("Basic " + Data(user.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        for (name, value) in call.headers { request.setValue(value, forHTTPHeaderField: name) }

        let start = Date()
        let (bytes, response) = try await session.bytes(for: request)
        var body = Data()
        var truncated = false
        for try await byte in bytes {
            body.append(byte)
            if body.count >= downloadLimit { truncated = true; break }
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // Like curl on HTTP/2: no reason phrase (URLSession only has localized ones, e.g. "no error").
        var headerText = "HTTP/2 \(status)\n"
        for (key, value) in (http?.allHeaderFields ?? [:]).sorted(by: { "\($0.key)" < "\($1.key)" }) {
            headerText += "\(key): \(value)\n"
        }
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        var text = decode(body, contentType: contentType)
        if truncated { text += "\n[stopped after \(downloadLimit >> 20) MB]\n" }
        return HTTPResponse(status: status, headerText: headerText, bodyText: text, size: body.count,
                            contentType: contentType, finalURL: http?.url?.absoluteString ?? url.absoluteString,
                            duration: Date().timeIntervalSince(start))
    }

    private static func decode(_ body: Data, contentType: String?) -> String {
        let type = contentType?.lowercased() ?? ""
        let binaryType = ["image/", "audio/", "video/", "application/octet-stream", "application/pdf", "application/zip"].contains { type.hasPrefix($0) }
        guard !binaryType, !body.prefix(4096).contains(0), let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) else {
            return "[binary data: \(ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file))\(type.isEmpty ? "" : ", \(type)")]\n"
        }
        // Terminal colors (wttr.in and friends) would just be noise.
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func curlCode(_ error: Error) -> Int32 {
        switch (error as? URLError)?.code {
        case .cannotFindHost, .dnsLookupFailed: return 6
        case .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost: return 7
        case .timedOut: return 28
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: return 60
        case .appTransportSecurityRequiresSecureConnection: return 1
        default: return 1
        }
    }

    private static func curlMessage(_ error: Error) -> String {
        if (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection {
            return "curl: (1) iOS only allows https:// here (plain http:// works on the local network only)"
        }
        return "curl: (\(curlCode(error))) \(error.localizedDescription)"
    }

    // MARK: - Text tools

    private static func jq(_ args: [String], stdin: String) -> Output {
        var raw = false, compact = false
        var filter: String?
        for a in args {
            if a == "--raw-output" { raw = true }
            else if a == "--compact-output" { compact = true }
            else if a.hasPrefix("-") && a.count > 1 && filter == nil {
                for c in a.dropFirst() {
                    switch c {
                    case "r", "j": raw = true
                    case "c": compact = true
                    case "e", "M", "C", "S": break
                    default: return fail("jq: option -\(c) isn't supported", status: 2)
                    }
                }
            } else if filter == nil {
                filter = a
            } else {
                return fail("jq: there is no filesystem; pipe JSON in instead", status: 2)
            }
        }
        do {
            return Output(stdout: try MiniJQ.run(filter: filter ?? ".", input: stdin, raw: raw, compact: compact))
        } catch {
            return fail("jq: error: \(error.localizedDescription)", status: 5)
        }
    }

    private static func echo(_ args: [String]) -> Output {
        var words = args
        var newline = true, escapes = false
        while let first = words.first, first.hasPrefix("-"), first.count > 1, first.dropFirst().allSatisfy({ "neE".contains($0) }) {
            if first.contains("n") { newline = false }
            if first.contains("e") { escapes = true }
            if first.contains("E") { escapes = false }
            words.removeFirst()
        }
        var text = words.joined(separator: " ")
        if escapes { text = unescape(text) }
        return Output(stdout: text + (newline ? "\n" : ""))
    }

    private static func printf(_ args: [String]) -> Output {
        guard let format = args.first else { return fail("printf: usage: printf format [arguments]", status: 2) }
        var values = Array(args.dropFirst())
        let chars = Array(unescape(format))
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                let spec = chars[i + 1]
                if spec == "%" { out.append("%") }
                else if "sdif".contains(spec) { out += values.isEmpty ? "" : values.removeFirst() }
                else { out += "%\(spec)" }
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return Output(stdout: out)
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func grep(_ args: [String], stdin: String, fixed: Bool) -> Output {
        let parsed: (flags: [(Character, String?)], operands: [String])
        do {
            parsed = try options(args, valued: ["e", "m", "A", "B", "C"], long: [
                "ignore-case": "i", "invert-match": "v", "count": "c", "only-matching": "o", "extended-regexp": "E",
                "fixed-strings": "F", "line-number": "n", "word-regexp": "w", "regexp": "e", "max-count": "m",
            ])
        } catch {
            return fail("grep: \(error.localizedDescription)", status: 2)
        }
        var ignoreCase = false, invert = false, count = false, only = false, literal = fixed, numbers = false, word = false
        var patterns: [String] = []
        var maxCount = Int.max
        for (flag, value) in parsed.flags {
            switch flag {
            case "i": ignoreCase = true
            case "v": invert = true
            case "c": count = true
            case "o": only = true
            case "F": literal = true
            case "n": numbers = true
            case "w": word = true
            case "e": patterns.append(value ?? "")
            case "m": maxCount = Int(value ?? "") ?? .max
            case "E", "s", "h", "H", "a", "A", "B", "C": break
            default: return fail("grep: option -\(flag) isn't supported", status: 2)
            }
        }
        var operands = parsed.operands
        if patterns.isEmpty {
            guard !operands.isEmpty else { return fail("grep: no pattern given", status: 2) }
            patterns.append(operands.removeFirst())
        }
        if !operands.isEmpty { return fail("grep: there is no filesystem; pipe text in instead", status: 2) }
        var regexes: [NSRegularExpression] = []
        for p in patterns {
            var source = literal ? NSRegularExpression.escapedPattern(for: p) : p.replacingOccurrences(of: "\\|", with: "|")
            if word { source = "\\b(?:\(source))\\b" }
            guard let re = try? NSRegularExpression(pattern: source, options: ignoreCase ? [.caseInsensitive] : []) else {
                return fail("grep: invalid pattern \(p)", status: 2)
            }
            regexes.append(re)
        }
        var out: [String] = []
        var matched = 0
        for (index, line) in lines(stdin).enumerated() where matched < maxCount {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            let hits = regexes.flatMap { $0.matches(in: s, range: range) }
            guard hits.isEmpty == invert else { continue }
            matched += 1
            if count { continue }
            let prefix = numbers ? "\(index + 1):" : ""
            if only && !invert {
                for hit in hits { if let r = Range(hit.range, in: s) { out.append(prefix + s[r]) } }
            } else {
                out.append(prefix + s)
            }
        }
        if count { return Output(stdout: "\(matched)\n", status: matched > 0 ? 0 : 1) }
        return Output(stdout: joinLines(out), status: matched > 0 ? 0 : 1)
    }

    private static func headTail(_ args: [String], stdin: String, head: Bool) -> Output {
        let name = head ? "head" : "tail"
        var normalized = args
        // `head -5` is shorthand for `head -n 5`.
        if let first = normalized.first, first.count > 1, first.hasPrefix("-"), Int(first.dropFirst()) != nil {
            normalized[0] = "-n" + first.dropFirst()
        }
        guard let parsed = try? options(normalized, valued: ["n", "c"], long: ["lines": "n", "bytes": "c"]) else {
            return fail("\(name): bad option", status: 2)
        }
        if !parsed.operands.isEmpty { return fail("\(name): there is no filesystem; pipe text in instead", status: 2) }
        var n = 10
        var bytes = false
        var fromStart = false   // tail -n +K: from line K on
        for (flag, value) in parsed.flags {
            guard let v = value, let number = Int(v.replacingOccurrences(of: "+", with: "")) else { continue }
            n = abs(number)
            bytes = flag == "c"
            fromStart = !head && v.hasPrefix("+")
        }
        if fromStart {
            let all = lines(stdin)
            return Output(stdout: joinLines(Array(all.dropFirst(max(n - 1, 0)))))
        }
        if bytes {
            let data = Array(stdin.utf8)
            let slice = head ? data.prefix(n) : data.suffix(n)
            return Output(stdout: String(decoding: slice, as: UTF8.self))
        }
        let all = lines(stdin)
        return Output(stdout: joinLines(head ? Array(all.prefix(n)) : Array(all.suffix(n))))
    }

    private static func wc(_ args: [String], stdin: String) -> Output {
        let counts: [Character: Int] = [
            "l": stdin.filter { $0 == "\n" }.count,
            "w": stdin.split(whereSeparator: { $0.isWhitespace }).count,
            "c": stdin.utf8.count,
            "m": stdin.count,
        ]
        let chosen = args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() }.filter { counts[$0] != nil }
        let order: [Character] = chosen.isEmpty ? ["l", "w", "c"] : ["l", "w", "m", "c"].filter(chosen.contains)
        return Output(stdout: order.map { String(counts[$0]!) }.joined(separator: " ") + "\n")
    }

    private static func sort(_ args: [String], stdin: String) -> Output {
        let flags = Set(args.filter { $0.hasPrefix("-") }.flatMap { $0.dropFirst() })
        var all = lines(stdin).map(String.init)
        if flags.contains("n") {
            all.sort { (Double($0.prefix { !$0.isWhitespace }) ?? 0) < (Double($1.prefix { !$0.isWhitespace }) ?? 0) }
        } else if flags.contains("f") {
            all.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } else {
            all.sort()
        }
        if flags.contains("r") { all.reverse() }
        if flags.contains("u") {
            var seen = Set<String>()
            all = all.filter { seen.insert($0).inserted }
        }
        return Output(stdout: joinLines(all))
    }

    private static func uniq(_ args: [String], stdin: String) -> Output {
        let showCount = args.contains { $0.hasPrefix("-") && $0.contains("c") }
        var runs: [(String, Int)] = []
        for line in lines(stdin) {
            if runs.last?.0 == String(line) { runs[runs.count - 1].1 += 1 } else { runs.append((String(line), 1)) }
        }
        return Output(stdout: joinLines(runs.map { showCount ? String(format: "%7d %@", $0.1, $0.0) : $0.0 }))
    }

    private static func base64(_ args: [String], stdin: String) -> Output {
        if args.contains(where: { $0 == "-d" || $0 == "-D" || $0 == "--decode" }) {
            let cleaned = stdin.filter { !$0.isWhitespace }
            let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
            guard let data = Data(base64Encoded: padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")) else {
                return fail("base64: invalid input")
            }
            return Output(stdout: decode(data, contentType: nil))
        }
        return Output(stdout: Data(stdin.utf8).base64EncodedString() + "\n")
    }

    private static func date(_ args: [String]) -> Output {
        var utc = false
        var format = "%a %b %e %H:%M:%S %Z %Y"
        for a in args {
            if a == "-u" || a == "--utc" { utc = true }
            else if a.hasPrefix("+") { format = String(a.dropFirst()) }
            else if a == "-I" || a == "--iso-8601" { format = "%Y-%m-%d" }
            else { return fail("date: only -u and +FORMAT are supported") }
        }
        var now = time(nil)
        var parts = tm()
        if utc { gmtime_r(&now, &parts) } else { localtime_r(&now, &parts) }
        var buffer = [Int8](repeating: 0, count: 256)
        let length = strftime(&buffer, buffer.count, format, &parts)
        let text = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return Output(stdout: text + "\n")
    }
}
