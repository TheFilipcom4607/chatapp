import Foundation
#if os(macOS)

/// A real zsh shell for the `run_command` tool: the user's own programs and permissions, which is
/// why every command waits for approval in the popup above the composer. Runs off the main thread,
/// captures output up to a cap, and stops the command at the time limit or when the chat is stopped.
/// `Process` starts zsh as the leader of a process group of its own, so a stop signals the whole
/// group: zsh, its pipeline and anything it put in the background. SIGTERM first, SIGKILL after 3s.
/// The command is done when zsh exits. A job it left in the background that still writes to the
/// output gets a moment to finish; after that Halo stops reading and the result returns.
enum RealShell {
    static let timeLimit: TimeInterval = 120
    /// How long output may keep coming after zsh exits (a background job still holding the pipe).
    private static let drainGrace: TimeInterval = 0.5
    /// Comfortably above what the model (16k) or the card (20k) ever shows.
    private static let captureLimit = 65_536

    static func run(command: String, directory: URL) async -> ShellResult {
        let run = RunState()
        let start = Date()
        var result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: execute(command, directory: directory, run: run, start: start))
                }
            }
        }, onCancel: {
            run.stop(reason: .cancelled)
        })
        if let stop = run.stoppedReason {
            result.stderr += (result.stderr.isEmpty ? "" : "\n") + stop
            result.exitCode = -1
        }
        return result
    }

    private static func execute(_ command: String, directory: URL, run: RunState, start: Date) -> ShellResult {
        var result = ShellResult()
        let out = Capture(), err = Capture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            result.stderr = "Couldn't run the command: \(error.localizedDescription)"
            result.exitCode = 126
            result.duration = Date().timeIntervalSince(start)
            return result
        }
        run.set(process)
        // Each pipe signals once at end of file. Never readDataToEndOfFile: a job left running in
        // the background (`server &`) keeps the pipe open, and that read would wait for it forever.
        let drained = DispatchGroup()
        for (pipe, capture) in [(outPipe, out), (errPipe, err)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if capture.reachEnd() { drained.leave() }
                } else {
                    capture.add(data)
                }
            }
        }
        // The limit fires on a queue of its own; the run object makes the late call harmless.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit) {
            run.stop(reason: .timedOut)
        }

        process.waitUntilExit()
        let leftOpen = drained.wait(timeout: .now() + drainGrace) == .timedOut
        // From here a timeout or stop no longer touches the group: a job the command meant to leave
        // running (with its output sent elsewhere) keeps running.
        run.finish()
        if leftOpen {
            // Stop reading. The pipes close when they're released after this returns, and a job
            // still writing to them then gets SIGPIPE, as when a terminal closes. (Not closed here:
            // a read handler still in flight would hit a closed handle.)
            for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
            err.note("A background job still had the output open when the command ended, so Halo stopped reading it. To leave one running, send its output to a file: nohup cmd > log.txt 2>&1 &")
        }

        result.stdout = out.text
        result.stderr = err.text
        result.exitCode = process.terminationStatus
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// The reasons a run is stopped from outside; the wording goes to the model.
    private enum StopReason {
        case cancelled
        case timedOut

        var text: String {
            switch self {
            case .cancelled: return "The command was stopped."
            case .timedOut: return "Stopped after \(Int(RealShell.timeLimit))s."
            }
        }
    }

    /// Guards the launch/stop race (a cancel or timeout can arrive before the process exists) and
    /// the end: once the command is done, a late timeout or stop is ignored.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var group: pid_t?
        private var stopped: StopReason?
        private var finished = false

        var stoppedReason: String? {
            lock.lock(); defer { lock.unlock() }
            return stopped?.text
        }

        func set(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            // zsh leads its own process group (Process starts it that way), so its pid names the group.
            group = process.processIdentifier
            if stopped != nil { signal() }
        }

        func stop(reason: StopReason) {
            lock.lock(); defer { lock.unlock() }
            guard stopped == nil, !finished else { return }
            stopped = reason
            signal()
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            finished = true
        }

        /// SIGTERM to the whole group, then SIGKILL to whatever of it is still alive. Called under
        /// the lock, and only once (`stopped` is set exactly once).
        private func signal() {
            guard let group, group > 0 else { return }
            // Should zsh ever share Halo's group, signal zsh alone rather than Halo with it.
            let target = getpgid(group) == group ? -group : group
            kill(target, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                kill(target, SIGKILL)   // ESRCH once it's gone: harmless
            }
        }
    }

    /// Locked output buffer that stops growing past the cap, marking the rest as cut.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var cut = false
        private var notes: [String] = []
        private var ended = false

        var text: String {
            lock.lock(); defer { lock.unlock() }
            var text = buffer
            if cut { text += "\n… [output cut at \(captureLimit) characters]" }
            for note in notes { text += (text.isEmpty ? "" : "\n") + note }
            return text
        }

        /// True the first time only, so end of file is counted once per pipe.
        func reachEnd() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if ended { return false }
            ended = true
            return true
        }

        /// A line from Halo itself, added after the command's own output.
        func note(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            notes.append(line)
        }

        func add(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard !cut else { return }
            buffer += String(decoding: data, as: UTF8.self)
            if buffer.count > captureLimit {
                buffer = String(buffer.prefix(captureLimit))
                cut = true
            }
        }
    }
}

#endif
