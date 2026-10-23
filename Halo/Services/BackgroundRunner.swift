import Foundation

/// Finishes chat requests while the app is suspended, using a background URLSession
/// (the system daemon keeps the connection alive). Results are handed to the engine,
/// or persisted until the app is running again.
final class BackgroundRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "com.filip.halo.background"
    static let shared = BackgroundRunner()

    struct Job: Codable, Sendable {
        var conversationID: UUID
        var messageID: UUID
    }

    private struct StoredResult: Codable {
        var job: Job
        var status: Int
        var data: Data?
        var error: String?
    }

    var systemCompletionHandler: (() -> Void)?
    /// Set by the app once the engine exists. Called on the main actor.
    var deliver: (@MainActor (Job, Data?, Int, String?) -> Void)?

    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private static var workDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Background", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Recreates the session so pending events for it are delivered (call at launch).
    func activate() { _ = session }

    func enqueue(_ request: URLRequest, body: Data, job: Job) throws {
        let file = Self.workDir.appendingPathComponent("req-\(job.messageID.uuidString).json")
        try body.write(to: file, options: .atomic)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        task.resume()
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let desc = task.taskDescription, let job = try? JSONDecoder().decode(Job.self, from: Data(desc.utf8)) else { return }
        try? FileManager.default.removeItem(at: Self.workDir.appendingPathComponent("req-\(job.messageID.uuidString).json"))
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let result = StoredResult(job: job, status: status, data: data, error: error?.localizedDescription)
        // Persist first so nothing is lost if the app is terminated before the engine runs.
        let file = Self.workDir.appendingPathComponent("result-\(job.messageID.uuidString).json")
        if let encoded = try? JSONEncoder().encode(result) { try? encoded.write(to: file, options: .atomic) }
        DispatchQueue.main.async { self.drainPendingResults() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.drainPendingResults()
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }

    /// Hands stored results to the engine (main thread).
    func drainPendingResults() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let deliver else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.workDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("result-") {
            guard let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(StoredResult.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try? FileManager.default.removeItem(at: file)
            MainActor.assumeIsolated {
                deliver(result.job, result.data, result.status, result.error)
            }
        }
    }
}
