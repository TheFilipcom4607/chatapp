import Foundation
import Observation

/// Turns a Markdown reply into text worth hearing, in pieces a voice model accepts.
enum SpeechText {
    /// Drops what doesn't read aloud: code blocks become "Code omitted.", formulas likewise, links
    /// keep their words, and list, heading, table and emphasis marks go.
    static func plain(_ markdown: String) -> String {
        var out: [String] = []
        var fence: String?
        var inMath = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
                out.append("Code omitted.")
                continue
            }
            if inMath {
                if line.hasSuffix("$$") { inMath = false }
                continue
            }
            if line.hasPrefix("$$") {
                out.append("Formula omitted.")
                if !(line.count > 2 && line.hasSuffix("$$")) { inMath = true }
                continue
            }
            if line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            if line.hasPrefix("|") {
                // A table: skip the |---| row, read the cells of the others as a list.
                if line.range(of: #"^\|[\s:|-]+\|?$"#, options: .regularExpression) != nil { continue }
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                out.append(inline(cells.joined(separator: ", ")) + ".")
                continue
            }
            var text = line
            text = text.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            out.append(inline(text))
        }
        let joined = out.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inline(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://([^/\s)]+)[^\s)]*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>\n]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__|~~)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<!\w)_(?!\s)([^_\n]+?)(?<!\s)_(?!\w)"#, with: "$1", options: .regularExpression)
        return t
    }

    /// Splits at paragraph breaks into pieces of at most `limit` characters; a paragraph that's
    /// longer on its own splits between sentences, and a sentence that's longer between words.
    static func chunks(_ text: String, limit: Int = 4000) -> [String] {
        var pieces: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            let p = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if p.count <= limit { pieces.append(p) } else { pieces += split(p, limit: limit) }
        }
        var result: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 2 + piece.count <= limit {
                current += "\n\n" + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func split(_ paragraph: String, limit: Int) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub { sentences.append(sub) }
        }
        var result: [String] = []
        var current = ""
        for sentence in sentences {
            if current.count + sentence.count <= limit {
                current += sentence
                continue
            }
            if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
            current = ""
            var rest = Substring(sentence)
            while rest.count > limit {
                let window = rest.prefix(limit)
                let cut = window.lastIndex(of: " ").map { rest.index(after: $0) } ?? window.endIndex
                result.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
                rest = rest[cut...]
            }
            current = String(rest)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }
}

/// Plays a turn read aloud, one piece after another, starting as soon as the first is ready.
/// Shared, so one reading plays at a time and keeps going when its row scrolls away.
@MainActor
@Observable
final class ReadAloudPlayer {
    static let shared = ReadAloudPlayer()

    /// The turn (its last reply's id) whose audio is still being made.
    private(set) var loadingID: UUID?
    /// The turn playing now.
    private(set) var playingID: UUID?

    @ObservationIgnored private let audio = AudioController()
    @ObservationIgnored private var queue: [MediaItem] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var currentID: UUID?

    private init() {
        audio.onFinish = { [weak self] in
            Task { @MainActor in self?.playNext() }
        }
    }

    func toggle(_ messages: [Message], engine: ChatEngine) {
        guard let id = messages.last?.id else { return }
        if currentID == id {
            stop()
            Haptics.tap()
            return
        }
        stop()
        Haptics.tap()
        currentID = id
        loadingID = id
        task = Task { [weak self] in
            do {
                _ = try await engine.readAloud(messages) { item in self?.enqueue(item, for: id) }
            } catch {
                guard let self, self.currentID == id else { return }
                if !(error is CancellationError) && !Task.isCancelled {
                    Haptics.error()
                    AppModel.shared.showToast("Couldn't read it aloud: \(error.localizedDescription)")
                }
                self.stop()
                return
            }
            guard let self, self.currentID == id else { return }
            self.loadingID = nil
            if self.playingID == nil && self.queue.isEmpty { self.currentID = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        audio.stop()
        queue = []
        currentID = nil
        loadingID = nil
        playingID = nil
    }

    private func enqueue(_ item: MediaItem, for id: UUID) {
        guard currentID == id else { return }
        queue.append(item)
        if playingID == nil { playNext() }
    }

    private func playNext() {
        guard let id = currentID else { return }
        guard !queue.isEmpty else {
            playingID = nil
            // Still making the next piece: the spinner shows until it's ready. Otherwise, done.
            if loadingID == nil { currentID = nil }
            return
        }
        let item = queue.removeFirst()
        playingID = id
        audio.play(url: MediaStore.url(for: item))
    }
}
