import Foundation
import Observation

/// Observable state for the reply currently streaming in a conversation.
/// The UI renders this instead of the stored message until the reply is committed.
@MainActor
@Observable
final class LiveTurn {
    enum Phase: Equatable {
        case connecting
        case reasoning
        case writing
        case tool(String)
        case waitingApproval
        case runningTools
    }

    let conversationID: UUID
    var messageID: UUID?
    var phase: Phase = .connecting
    /// Text currently on screen (smoothly catches up to `target`).
    private(set) var displayed = ""
    private(set) var target = ""
    var reasoning = ""
    var toolDrafts: [(name: String, arguments: String)] = []
    var startedAt = Date()
    var firstTokenAt: Date?
    var handingOff = false
    var smooth = true

    private var revealTask: Task<Void, Never>?

    init(conversationID: UUID) {
        self.conversationID = conversationID
    }

    func beginMessage(_ id: UUID) {
        messageID = id
        displayed = ""
        target = ""
        reasoning = ""
        toolDrafts = []
        phase = .connecting
        startedAt = Date()
        firstTokenAt = nil
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        if firstTokenAt == nil { firstTokenAt = Date() }
        target += text
        phase = .writing
        if smooth { startRevealing() } else { displayed = target }
    }

    var isCaughtUp: Bool { displayed.count >= target.count }

    /// Reveals buffered characters at an adaptive pace (~60 fps), like a typist who speeds up
    /// when they fall behind. Keeps streaming silky even when chunks arrive in bursts.
    private func startRevealing() {
        guard revealTask == nil else { return }
        revealTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let backlog = self.target.count - self.displayed.count
                if backlog <= 0 { break }
                let step = max(1, min(backlog, backlog / 6 + 2))
                let end = self.target.index(self.target.startIndex, offsetBy: self.displayed.count + step)
                self.displayed = String(self.target[..<end])
                Haptics.streamTick()
                try? await Task.sleep(nanoseconds: 24_000_000)
            }
            self?.revealTask = nil
        }
    }

    /// Waits until all buffered text is shown (bounded so commits never hang).
    func drain() async {
        var spins = 0
        while !isCaughtUp && spins < 120 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            spins += 1
        }
        displayed = target
    }

    func stop() {
        revealTask?.cancel()
        revealTask = nil
    }
}
