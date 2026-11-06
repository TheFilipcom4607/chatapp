import Foundation

/// Keeps a reply going while Halo is suspended or closed.
///
/// The reply's request goes out on a background URLSession: the system's networking daemon holds the
/// connection while the app sleeps, and even after iOS terminates it. Everything the stream sends is
/// appended to a file as it arrives, so none of it is lost with the app. When Halo is opened again the
/// engine picks the stream up (`events(for:)`): what came while it was away is replayed at once and the
/// rest arrives live, as if the phone had never slept. When the reply finishes while Halo is away, iOS
/// wakes the app, and the engine saves the reply from the file (`storedEvents(for:ending:)`).
///
/// A task started while the app is already in the background is discretionary: iOS may hold it until
/// the phone is charging on Wi-Fi. So the engine starts its copy as Halo leaves the screen, while the
/// app is still in the foreground.
///
/// Files, by the reply message's id: `req-` the request body to upload, `job-` what the reply belongs
/// to, `sse-` the stream so far, `end-` how it ended (written once it has).
final class BackgroundRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.filip.halo.background"
    static let shared = BackgroundRunner()

    struct Job: Codable, Sendable {
        var conversationID: UUID
        var messageID: UUID
        /// Whether the request asked the model for a title tag, which the reader takes out again.
        var titleEnabled: Bool?
        var serviceTier: String?
        var startedAt: Date?
        /// Started while Halo was on screen (or just leaving it), so iOS runs it straight away.
        var startedInForeground: Bool?
    }

    /// How a job ended.
    struct Ending: Codable, Sendable {
        var status: Int
        var error: String?
        /// Cancelled by the system rather than failed: what happens to background requests when
        /// Halo is force-quit from the app switcher.
        var cancelled: Bool
    }

    enum State {
        /// Still running, with how many bytes of the reply have come in.
        case running(Job, bytes: Int64)
        case finished(Ending)
        /// No request is running or finished for it (`hadJob` when one was started).
        case missing(hadJob: Bool)
    }

    /// The request was cancelled before it finished (Halo was force-quit), so the reply should start over.
    struct Interrupted: LocalizedError {
        var errorDescription: String? { "The reply was interrupted when Halo was closed." }
    }

    var systemCompletionHandler: (() -> Void)?
    /// Set by the app once the engine exists; called on the main actor with a job that has ended.
    /// Returns false to leave the job for later (its reply is still being written on screen).
    var deliver: (@MainActor (Job, Ending) -> Bool)?

    private let lock = NSLock()
    /// The stream a live reply is reading, by message.
    private var subscribers: [UUID: Subscriber] = [:]
    /// Jobs a live reply has taken; they're left alone by `drainPendingResults` until it lets go.
    private var claimed = Set<UUID>()
    /// Jobs cancelled here; anything that still arrives for them is dropped.
    private var cancelled = Set<UUID>()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // The stream sends a keep-alive comment while the model thinks, so a long gap means it's gone.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private static var workDir: URL {
        let dir = AppFolders.support.appendingPathComponent("Background", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ kind: String, _ id: UUID) -> URL {
        workDir.appendingPathComponent("\(kind)-\(id.uuidString).\(kind == "sse" ? "txt" : "json")")
    }

    /// Recreates the session so pending events for it are delivered (call at launch).
    func activate() {
        _ = session
        // Requests from before Halo kept job files (non-streaming ones that may still be waiting for
        // the phone to charge) have no reply to land in any more: stop them, and drop their old results.
        session.getAllTasks { tasks in
            for task in tasks {
                guard let id = Self.messageID(of: task) else { task.cancel(); continue }
                if !FileManager.default.fileExists(atPath: Self.file("job", id).path) { task.cancel() }
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.workDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("result-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Jobs

    func enqueue(_ request: URLRequest, body: Data, job: Job) throws {
        let id = job.messageID
        lock.lock()
        cancelled.remove(id)
        lock.unlock()
        for kind in ["sse", "end"] { try? FileManager.default.removeItem(at: Self.file(kind, id)) }
        let bodyFile = Self.file("req", id)
        try body.write(to: bodyFile, options: .atomic)
        let encoded = try JSONEncoder().encode(job)
        try encoded.write(to: Self.file("job", id), options: .atomic)
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = String(decoding: encoded, as: UTF8.self)
        task.resume()
    }

    func hasJob(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: Self.file("job", id).path)
    }

    func job(for id: UUID) -> Job? {
        (try? Data(contentsOf: Self.file("job", id))).flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
    }

    func ending(for id: UUID) -> Ending? {
        (try? Data(contentsOf: Self.file("end", id))).flatMap { try? JSONDecoder().decode(Ending.self, from: $0) }
    }

    /// Where a reply's background request stands. Asks the daemon, so it's async.
    func state(of id: UUID) async -> State {
        if let ending = ending(for: id) { return .finished(ending) }
        guard let job = job(for: id) else { return .missing(hadJob: false) }
        let tasks = await session.allTasks
        if let task = tasks.first(where: { Self.messageID(of: $0) == id }), task.state == .running || task.state == .suspended {
            let saved = (try? FileManager.default.attributesOfItem(atPath: Self.file("sse", id).path)[.size] as? NSNumber)?.int64Value ?? 0
            return .running(job, bytes: max(task.countOfBytesReceived, saved))
        }
        // It may have ended while we asked.
        if let ending = ending(for: id) { return .finished(ending) }
        return .missing(hadJob: true)
    }

    /// Stops a reply's background request, if it has one, and forgets it. Call once the reply is saved
    /// (or no longer wanted).
    func discard(_ id: UUID) {
        lock.lock()
        let hadJob = hasJob(id)
        if hadJob { cancelled.insert(id) }
        claimed.remove(id)
        let subscriber = subscribers.removeValue(forKey: id)
        for kind in ["req", "job", "sse", "end"] { try? FileManager.default.removeItem(at: Self.file(kind, id)) }
        lock.unlock()
        subscriber?.close()
        guard hadJob else { return }
        session.getAllTasks { tasks in
            tasks.filter { Self.messageID(of: $0) == id }.forEach { $0.cancel() }
        }
    }

    // MARK: Reading a reply

    /// The reply's stream from its first byte: what's been received so far, then `.caughtUp`, then the
    /// rest as it arrives. Nil when the reply has no background request. The job is the caller's until
    /// it calls `discard`, or the stream is cancelled.
    func events(for id: UUID) -> AsyncThrowingStream<ChatStreamEvent, Error>? {
        guard hasJob(id) else { return nil }
        let (stream, continuation) = AsyncThrowingStream<ChatStreamEvent, Error>.makeStream()
        let subscriber = Subscriber(continuation)
        lock.lock()
        let previous = subscribers.updateValue(subscriber, forKey: id)
        claimed.insert(id)
        let soFar = (try? Data(contentsOf: Self.file("sse", id))) ?? Data()
        subscriber.feed(soFar)
        subscriber.yield(.caughtUp)
        if let ending = ending(for: id) {
            subscribers[id] = nil
            subscriber.finish(Self.failure(for: ending, data: soFar))
        }
        lock.unlock()
        previous?.close()
        continuation.onTermination = { [weak self, weak subscriber] reason in
            // Stopped reading (Halo left again, or the user stopped it): the job goes back to waiting,
            // unless a newer reader has it.
            guard case .cancelled = reason, let self else { return }
            self.lock.lock()
            if self.subscribers[id] == nil || self.subscribers[id] === subscriber {
                self.subscribers[id] = nil
                self.claimed.remove(id)
            }
            self.lock.unlock()
        }
        return stream
    }

    /// The live reader stopped without saving the reply (Halo left the screen again): the job goes
    /// back to waiting, to be read again or saved when it ends.
    func release(_ id: UUID) {
        lock.lock()
        let subscriber = subscribers.removeValue(forKey: id)
        claimed.remove(id)
        lock.unlock()
        subscriber?.close()
    }

    /// Everything a finished reply's stream held, for saving it while no one is reading it.
    /// Throws the error it ended with (`Interrupted` when it was cut off by Halo being closed).
    func storedEvents(for id: UUID, ending: Ending) throws -> [ChatStreamEvent] {
        let data = (try? Data(contentsOf: Self.file("sse", id))) ?? Data()
        if let failure = Self.failure(for: ending, data: data) { throw failure }
        var splitter = SSELineSplitter()
        let decoder = JSONDecoder()
        var events: [ChatStreamEvent] = []
        for line in splitter.feed(data) + splitter.flush() {
            switch try OpenRouterClient.chatStreamStep(line, decoder: decoder) {
            case .event(let event): events.append(event)
            case .done: return events
            case nil: continue
            }
        }
        return events
    }

    /// The error a job ended with, if it failed. The body of a refused request is OpenRouter's error.
    private static func failure(for ending: Ending, data: Data) -> Error? {
        if ending.cancelled { return Interrupted() }
        if let error = ending.error { return OpenRouterError.stream(error) }
        guard (200..<300).contains(ending.status) else { return OpenRouterClient.errorFrom(status: ending.status, data: data) }
        return nil
    }

    /// Hands jobs that have ended, and that no live reply is reading, to the engine (main thread).
    func drainPendingResults() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let deliver else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.workDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("end-") {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: String(name.dropFirst(4))) else { continue }
            lock.lock()
            let isClaimed = claimed.contains(id)
            lock.unlock()
            guard !isClaimed else { continue }
            guard let job = job(for: id), let ending = ending(for: id) else {
                discard(id)
                continue
            }
            MainActor.assumeIsolated { _ = deliver(job, ending) }
        }
    }

    // MARK: URLSession delegate

    private static func messageID(of task: URLSessionTask) -> UUID? {
        guard let desc = task.taskDescription, let job = try? JSONDecoder().decode(Job.self, from: Data(desc.utf8)) else { return nil }
        return job.messageID
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = Self.messageID(of: dataTask) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled.contains(id), hasJob(id) else { return }
        let url = Self.file("sse", id)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        subscribers[id]?.feed(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = Self.messageID(of: task) else { return }
        lock.lock()
        guard cancelled.remove(id) == nil, hasJob(id) else {
            lock.unlock()
            return
        }
        try? FileManager.default.removeItem(at: Self.file("req", id))
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let nsError = error as NSError?
        let ending = Ending(status: status, error: error?.localizedDescription,
                            cancelled: nsError?.domain == NSURLErrorDomain && nsError?.code == NSURLErrorCancelled)
        if let encoded = try? JSONEncoder().encode(ending) { try? encoded.write(to: Self.file("end", id), options: .atomic) }
        let subscriber = subscribers.removeValue(forKey: id)
        let data = subscriber == nil ? Data() : ((try? Data(contentsOf: Self.file("sse", id))) ?? Data())
        lock.unlock()
        // The reader keeps its claim until it has saved the reply and called `discard`.
        subscriber?.finish(Self.failure(for: ending, data: data))
        DispatchQueue.main.async { self.drainPendingResults() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.drainPendingResults()
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}

/// Turns the bytes of one live reply into stream events for its reader.
private final class Subscriber: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    private var splitter = SSELineSplitter()
    private let decoder = JSONDecoder()
    private var closed = false

    init(_ continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func feed(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        consume(splitter.feed(data))
    }

    func yield(_ event: ChatStreamEvent) {
        guard !closed else { return }
        continuation.yield(event)
    }

    /// The request ended: the last line, then the end of the stream (or its error).
    func finish(_ failure: Error?) {
        guard !closed else { return }
        if failure == nil { consume(splitter.flush()) }
        guard !closed else { return }
        closed = true
        if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
    }

    /// Its reader is gone, or replaced. Ends with a cancellation, so nothing reads a cut-off stream as complete.
    func close() {
        guard !closed else { return }
        closed = true
        continuation.finish(throwing: CancellationError())
    }

    private func consume(_ lines: [String]) {
        for line in lines {
            guard !closed else { return }
            do {
                switch try OpenRouterClient.chatStreamStep(line, decoder: decoder) {
                case .event(let event): continuation.yield(event)
                case .done:
                    closed = true
                    continuation.finish()
                case nil: continue
                }
            } catch {
                closed = true
                continuation.finish(throwing: error)
            }
        }
    }
}
