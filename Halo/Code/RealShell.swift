import Foundation
#if os(macOS)

/// A real zsh shell for the `run_command` tool: the user's own programs and permissions, which is
/// why every command waits for approval in the popup above the composer. Runs off the main thread,
/// captures output up to a cap, and stops the shell at the time limit or when the chat is stopped.
/// SIGHUP is the stop signal: zsh forwards it to its running jobs before exiting, so a `sleep` or
/// `curl` inside the command dies with it; SIGKILL follows if the shell ignores the HUP.
enum RealShell {
    static let timeLimit: TimeInterval = 120
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
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { out.add(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { err.add(data) }
        }
        // The limit fires on a queue of its own; the run object makes the late call harmless.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit) {
            run.stop(reason: .timedOut)
        }

        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.add(outPipe.fileHandleForReading.readDataToEndOfFile())
        err.add(errPipe.fileHandleForReading.readDataToEndOfFile())

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

    /// Guards the launch/stop race: a cancel or timeout can arrive before the process exists.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped: StopReason?
        private var killScheduled = false

        var stoppedReason: String? {
            lock.lock(); defer { lock.unlock() }
            return stopped?.text
        }

        func set(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            if stopped != nil { signal(process) }
        }

        func stop(reason: StopReason) {
            lock.lock(); defer { lock.unlock() }
            guard stopped == nil else { return }
            stopped = reason
            if let process { signal(process) }
        }

        /// HUP first (zsh forwards it to its jobs), then SIGKILL if the shell is still alive.
        private func signal(_ process: Process) {
            if !killScheduled {
                killScheduled = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    /// Locked output buffer that stops growing past the cap, marking the rest as cut.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var cut = false

        var text: String {
            lock.lock(); defer { lock.unlock() }
            var text = buffer
            if cut { text += "\n… [output cut at \(captureLimit) characters]" }
            return text
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
