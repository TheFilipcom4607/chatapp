import Foundation

/// A tool the user defines: a curl command whose `{{name}}` placeholders the model fills in.
/// Parameters are one per line, `name: what it is`; all are strings and all are required.
struct CustomTool: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var description = ""
    var parameters = ""
    var curl = ""
    var enabled = true

    /// The name the model calls: letters, digits, _ and -, at most 64 characters.
    var functionName: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(name.replacingOccurrences(of: " ", with: "_").filter { allowed.contains($0) })
        return String(cleaned.prefix(64))
    }

    var isValid: Bool { !functionName.isEmpty && !curl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// (name, description) pairs from the parameters text.
    var params: [(name: String, info: String)] {
        parameters.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            let name = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !name.isEmpty else { return nil }
            return (name, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
        }
    }

    var spec: ToolSpec {
        var properties: [String: JSONValue] = [:]
        for p in params {
            properties[p.name] = .object(["type": .string("string"), "description": .string(p.info.isEmpty ? p.name : p.info)])
        }
        return .function(
            name: functionName,
            description: description.isEmpty ? "Calls \(name)." : description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(params.map { .string($0.name) }),
            ]))
    }
}

/// Turns a custom tool's curl command into a URLRequest and runs it (iOS can't run curl itself).
enum CustomToolRunner {
    static func run(_ tool: CustomTool, args: JSONValue) async -> ToolOutcome {
        var values: [String: String] = [:]
        for p in tool.params {
            let v = args[p.name]
            values[p.name] = v?.stringValue ?? v.map(describe) ?? ""
        }
        let request: URLRequest
        do {
            request = try makeRequest(tool.curl, values: values)
        } catch {
            return .failure("Couldn't read the curl command: \(error.modelDescription)", summary: "Bad command")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var body = String(decoding: data, as: UTF8.self)
            if body.count > 30_000 { body = String(body.prefix(30_000)) + "\n… (cut at 30,000 characters)" }
            return ToolOutcome(ok: status < 400, text: "HTTP \(status)\n\n\(body)", summary: "\(tool.name) · HTTP \(status)")
        } catch {
            return .failure("Request failed: \(error.modelDescription)", summary: "Request failed")
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    struct ParseError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Supports the usual flags: -X, -H, -d/--data*, --data-urlencode, --json, -u, -A, -G, --url.
    /// Placeholders are filled after splitting, so values with spaces or quotes stay intact; in the
    /// URL they are percent-encoded.
    static func makeRequest(_ command: String, values: [String: String]) throws -> URLRequest {
        var tokens = try tokenize(command)
        if tokens.first == "curl" { tokens.removeFirst() }
        func fill(_ s: String, encode: Bool) -> String {
            var out = s
            for (k, v) in values {
                let value = encode ? (v.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? v) : v
                out = out.replacingOccurrences(of: "{{\(k)}}", with: value)
            }
            return out
        }
        var url: String?
        var method: String?
        var headers: [(String, String)] = []
        var data: [String] = []
        var asQuery = false
        var i = 0
        func next() throws -> String {
            i += 1
            guard i < tokens.count else { throw ParseError("\(tokens[i - 1]) needs a value") }
            return tokens[i]
        }
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case "-X", "--request": method = try next()
            case "-H", "--header":
                let h = fill(try next(), encode: false)
                if let colon = h.firstIndex(of: ":") {
                    headers.append((String(h[..<colon]).trimmingCharacters(in: .whitespaces),
                                    String(h[h.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii": data.append(fill(try next(), encode: false))
            case "--data-urlencode":
                let raw = fill(try next(), encode: false)
                if let eq = raw.firstIndex(of: "=") {
                    let value = String(raw[raw.index(after: eq)...])
                    data.append(String(raw[..<eq]) + "=" + (value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value))
                } else {
                    data.append(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? raw)
                }
            case "--json":
                data.append(fill(try next(), encode: false))
                headers.append(("Content-Type", "application/json"))
                headers.append(("Accept", "application/json"))
            case "-u", "--user":
                let creds = fill(try next(), encode: false)
                headers.append(("Authorization", "Basic " + Data(creds.utf8).base64EncodedString()))
            case "-A", "--user-agent": headers.append(("User-Agent", fill(try next(), encode: false)))
            case "-e", "--referer": headers.append(("Referer", fill(try next(), encode: false)))
            case "-b", "--cookie": headers.append(("Cookie", fill(try next(), encode: false)))
            case "-G", "--get": asQuery = true
            case "--url": url = fill(try next(), encode: true)
            case "-o", "--output", "-w", "--write-out", "-m", "--max-time", "--connect-timeout", "--retry": _ = try next()
            default:
                if t.hasPrefix("-") { break }   // -s, -L, -k, -i, --compressed and the like change nothing here
                url = fill(t, encode: true)
            }
            i += 1
        }
        guard var address = url else { throw ParseError("no URL") }
        if !address.contains("://") { address = "https://" + address }
        let body = data.joined(separator: "&")
        if asQuery, !body.isEmpty { address += (address.contains("?") ? "&" : "?") + body }
        guard let parsed = URL(string: address) else { throw ParseError("bad URL \(address)") }
        var request = URLRequest(url: parsed, timeoutInterval: 60)
        request.httpMethod = method ?? (!body.isEmpty && !asQuery ? "POST" : "GET")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if !body.isEmpty, !asQuery {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    /// Splits like a shell: quotes group, backslashes escape, a backslash-newline continues the line.
    static func tokenize(_ s: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\", q == "\"", let n = chars.first, "\"\\$`".contains(n) { current.append(chars.removeFirst()) }
                else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; inToken = true
            } else if c == "\\" {
                if let n = chars.popFirst(), !n.isNewline { current.append(n); inToken = true }
            } else if c.isWhitespace {
                if inToken { tokens.append(current); current = ""; inToken = false }
            } else {
                current.append(c); inToken = true
            }
        }
        if quote != nil { throw ParseError("unclosed quote") }
        if inToken { tokens.append(current) }
        return tokens
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()
}
