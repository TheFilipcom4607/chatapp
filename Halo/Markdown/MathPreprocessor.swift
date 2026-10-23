import Foundation

/// Rewrites LaTeX math into forms the markdown parser preserves:
/// display math → ```math fenced blocks, inline math → `⁣math:…` code spans.
/// Code fences and inline code are left untouched.
enum MathPreprocessor {
    static let inlineMarker = "\u{2063}math:"

    static func process(_ input: String) -> String {
        guard input.contains("$") || input.contains("\\(") || input.contains("\\[") else { return input }
        var out = ""
        out.reserveCapacity(input.count + 32)
        let lines = input.components(separatedBy: "\n")
        var inFence = false
        var fenceMarker = ""
        var mathBuffer: [String]? = nil   // collecting a multi-line $$ … $$ / \[ … \] block
        var mathCloser = "$$"

        func emit(_ line: String) { out += line + "\n" }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                emit(line)
                if trimmed.hasPrefix(fenceMarker) { inFence = false }
                continue
            }
            if var buffer = mathBuffer {
                if let r = trimmed.range(of: mathCloser) {
                    buffer.append(String(trimmed[..<r.lowerBound]))
                    emit("```math")
                    buffer.filter { !$0.isEmpty }.forEach { emit($0) }
                    emit("```")
                    mathBuffer = nil
                    let rest = String(trimmed[r.upperBound...])
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty { emit(processInline(rest)) }
                } else {
                    buffer.append(line)
                    mathBuffer = buffer
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
                emit(line)
                continue
            }
            // Display math starting on its own line.
            for (opener, closer) in [("$$", "$$"), ("\\[", "\\]")] where trimmed.hasPrefix(opener) {
                let afterOpen = String(trimmed.dropFirst(opener.count))
                if let r = afterOpen.range(of: closer) {
                    let latex = String(afterOpen[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    emit("```math")
                    emit(latex)
                    emit("```")
                    let rest = String(afterOpen[r.upperBound...])
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty { emit(processInline(rest)) }
                } else {
                    mathBuffer = afterOpen.isEmpty ? [] : [afterOpen]
                    mathCloser = closer
                }
                break
            }
            if mathBuffer != nil || (trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[")) { continue }
            emit(processInline(line))
        }
        if let buffer = mathBuffer {
            // Unterminated (still streaming): show as math block so far.
            emit("```math")
            buffer.filter { !$0.isEmpty }.forEach { emit($0) }
            emit("```")
        }
        if out.hasSuffix("\n") && !input.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// Converts `$…$` and `\(…\)` spans within a single line, skipping `code` spans.
    static func processInline(_ line: String) -> String {
        guard line.contains("$") || line.contains("\\(") else { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                // Copy code span verbatim.
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                out += String(chars[i..<min(j + 1, chars.count)])
                i = j + 1
                continue
            }
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                if let end = find(chars, from: i + 2, pattern: ["\\", ")"]) {
                    out += code(String(chars[(i + 2)..<end]))
                    i = end + 2
                    continue
                }
            }
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                out += "$"
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count, chars[i + 1] != "$", chars[i + 1] != " " {
                // Find closing $ on the same line, not followed by a digit (avoid "$5 and $10").
                var j = i + 1
                var found: Int? = nil
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "$" {
                        let prevSpace = chars[j - 1] == " "
                        let nextDigit = j + 1 < chars.count && chars[j + 1].isNumber
                        if !prevSpace && !nextDigit { found = j }
                        break
                    }
                    j += 1
                }
                if let end = found {
                    let body = String(chars[(i + 1)..<end])
                    // Heuristic: plain currency like "$5" shouldn't become math.
                    if !(body.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }) {
                        out += code(body)
                        i = end + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func find(_ chars: [Character], from start: Int, pattern: [Character]) -> Int? {
        guard start < chars.count else { return nil }
        var i = start
        while i + pattern.count <= chars.count {
            if Array(chars[i..<(i + pattern.count)]) == pattern { return i }
            i += 1
        }
        return nil
    }

    private static func code(_ latex: String) -> String {
        // Use a double-backtick span if the latex itself contains a backtick.
        let body = inlineMarker + latex.trimmingCharacters(in: .whitespaces)
        return body.contains("`") ? "`` \(body) ``" : "`\(body)`"
    }
}
