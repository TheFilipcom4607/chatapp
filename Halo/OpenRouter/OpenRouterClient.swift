import Foundation

enum OpenRouterError: LocalizedError, Equatable {
    case noAPIKey
    case http(status: Int, message: String)
    case stream(String)
    case decoding(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Add your OpenRouter key in Settings to start chatting."
        case let .http(status, message):
            switch status {
            case 401: return "Your OpenRouter key was rejected. Sign in again in Settings."
            case 402: return "Out of OpenRouter credits. Top up at openrouter.ai/credits. \(message)"
            case 429: return "Rate limited by the provider. Try again in a moment."
            default: return message.isEmpty ? "OpenRouter error \(status)" : message
            }
        case let .stream(message): return message
        case let .decoding(message): return "Unexpected response: \(message)"
        case .invalidResponse: return "Unexpected response from OpenRouter."
        }
    }

    var statusCode: Int? {
        if case let .http(status, _) = self { return status }
        return nil
    }
}

/// Events emitted by a streaming chat completion.
enum ChatStreamEvent: Sendable {
    case generationID(String)
    case chunk(ChatChunk)
    case keepAlive
}

/// Thin, stateless HTTP client for the OpenRouter API.
final class OpenRouterClient: @unchecked Sendable {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!
    static let appURL = "https://github.com/TheFilipcom4607/chatapp"
    static let appTitle = "Halo"

    private let keyProvider: @Sendable () -> String?
    private let session: URLSession

    init(keyProvider: @escaping @Sendable () -> String?) {
        self.keyProvider = keyProvider
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: Request building

    static func makeRequest(path: String, method: String = "GET", key: String?, body: Data? = nil,
                            contentType: String = "application/json") -> URLRequest {
        let url: URL
        if path.hasPrefix("http") { url = URL(string: path)! }
        else {
            let trimmed = path.hasPrefix("/api/v1/") ? String(path.dropFirst(8)) : (path.hasPrefix("/") ? String(path.dropFirst()) : path)
            url = URL(string: trimmed, relativeTo: baseURL)!.absoluteURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue(appURL, forHTTPHeaderField: "HTTP-Referer")
        req.setValue(appTitle, forHTTPHeaderField: "X-OpenRouter-Title")
        req.setValue(appTitle, forHTTPHeaderField: "X-Title")
        req.setValue("general-chat", forHTTPHeaderField: "X-OpenRouter-Categories")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func requireKey() throws -> String {
        guard let key = keyProvider(), !key.isEmpty else { throw OpenRouterError.noAPIKey }
        return key
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static func errorFrom(status: Int, data: Data) -> OpenRouterError {
        if let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            var message = env.error.message ?? ""
            if let raw = env.error.metadata?["raw"]?.stringValue, !raw.isEmpty, message.count < 80 {
                message += " — " + raw.prefix(300)
            }
            return .http(status: status, message: message)
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self)
        return .http(status: status, message: text)
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.errorFrom(status: http.statusCode, data: data) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OpenRouterError.decoding(String(describing: error).prefix(300).description) }
    }

    // MARK: Chat

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try requireKey()
                    var body = request
                    body.stream = true
                    let data = try Self.encoder.encode(body)
                    var req = Self.makeRequest(path: "chat/completions", method: "POST", key: key, body: data)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
                    if let genID = http.value(forHTTPHeaderField: "X-Generation-Id") {
                        continuation.yield(.generationID(genID))
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errData = Data()
                        for try await b in bytes { errData.append(b); if errData.count > 8000 { break } }
                        throw Self.errorFrom(status: http.statusCode, data: errData)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let event = SSEParser.parse(line: line) else { continue }
                        switch event {
                        case .comment: continuation.yield(.keepAlive)
                        case .done:
                            continuation.finish()
                            return
                        case .data(let payload):
                            guard let d = payload.data(using: .utf8) else { continue }
                            if let chunk = try? decoder.decode(ChatChunk.self, from: d) {
                                if let err = chunk.error {
                                    throw OpenRouterError.stream(err.message ?? "The model stopped with an error.")
                                }
                                continuation.yield(.chunk(chunk))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completeChat(_ request: ChatRequest) async throws -> ChatCompletion {
        var body = request
        body.stream = false
        let req = Self.makeRequest(path: "chat/completions", method: "POST", key: try requireKey(),
                                   body: try Self.encoder.encode(body))
        return try await send(req, as: ChatCompletion.self)
    }

    /// Builds a non-streaming chat request for the background URLSession.
    func backgroundChatRequest(_ request: ChatRequest) throws -> (URLRequest, Data) {
        var body = request
        body.stream = false
        let data = try Self.encoder.encode(body)
        var req = Self.makeRequest(path: "chat/completions", method: "POST", key: try requireKey())
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        return (req, data)
    }

    // MARK: Models

    /// Most popular first (the website's "Most Popular"), so the picker's Popular sort is the API order.
    func models(outputModality: String = "text") async throws -> [ORModel] {
        let req = Self.makeRequest(path: "models?output_modalities=\(outputModality)&sort=most-popular", key: keyProvider())
        return try await send(req, as: ModelList<ORModel>.self).data
    }

    static let effortBenchmarksURL = URL(string: "https://openrouter.ai/api/frontend/v1/private/artificial-analysis-benchmarks/all")!

    /// Per-effort Artificial Analysis scores from OpenRouter's unofficial frontend API. A plain GET:
    /// it needs no key, and none is sent.
    func effortBenchmarks() async throws -> [AAEffortRow] {
        try await send(URLRequest(url: Self.effortBenchmarksURL), as: ModelList<AAEffortRow>.self).data
    }

    func imageModels() async throws -> [ImageModelInfo] {
        try await send(Self.makeRequest(path: "images/models", key: keyProvider()), as: ModelList<ImageModelInfo>.self).data
    }

    func endpoints(modelID: String) async throws -> ModelEndpoints {
        try await send(Self.makeRequest(path: "models/\(modelID)/endpoints", key: keyProvider()), as: ModelEndpoints.self)
    }

    func imageEndpoints(modelID: String) async throws -> ImageEndpoints {
        try await send(Self.makeRequest(path: "images/models/\(modelID)/endpoints", key: keyProvider()), as: ImageEndpoints.self)
    }

    func videoModels() async throws -> [VideoModelInfo] {
        try await send(Self.makeRequest(path: "videos/models", key: keyProvider()), as: ModelList<VideoModelInfo>.self).data
    }

    // MARK: Rankings (Data API)

    /// Days are UTC "YYYY-MM-DD"; nil leaves the API's default (the last 30 days).
    func rankingsDaily(start: String? = nil, end: String? = nil) async throws -> RankingsDaily {
        let query = [start.map { "start_date=\($0)" }, end.map { "end_date=\($0)" }].compactMap { $0 }.joined(separator: "&")
        return try await send(Self.makeRequest(path: "datasets/rankings-daily" + (query.isEmpty ? "" : "?\(query)"), key: try requireKey()),
                              as: RankingsDaily.self)
    }

    /// `sort` is "popular" or "trending".
    func appRankings(sort: String, limit: Int = 50) async throws -> AppRankings {
        try await send(Self.makeRequest(path: "datasets/app-rankings?sort=\(sort)&limit=\(limit)", key: try requireKey()), as: AppRankings.self)
    }

    func taskClassifications() async throws -> TaskClassifications {
        try await send(Self.makeRequest(path: "classifications/task", key: try requireKey()), as: TaskClassifications.self)
    }

    /// e.g. ["source": "openrouter", "benchmark_type": "gpqa_diamond"].
    func benchmarks(_ params: [String: String]) async throws -> BenchmarkList {
        let query = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return try await send(Self.makeRequest(path: "benchmarks?\(query)&max_results=100", key: try requireKey()), as: BenchmarkList.self)
    }

    // MARK: Media

    func generateImage(_ request: ImageGenerationRequest) async throws -> ImageGenerationResponse {
        var req = Self.makeRequest(path: "images", method: "POST", key: try requireKey(), body: try Self.encoder.encode(request))
        req.timeoutInterval = 300
        return try await send(req, as: ImageGenerationResponse.self)
    }

    /// Streams one image: `onPartial` gets each partial render as it lands, and the finished image
    /// comes back shaped like a non-streamed response.
    func streamImage(_ request: ImageGenerationRequest, onPartial: @escaping @MainActor (Data) -> Void) async throws -> ImageGenerationResponse {
        var body = request
        body.stream = true
        var req = Self.makeRequest(path: "images", method: "POST", key: try requireKey(), body: try Self.encoder.encode(body))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 300
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errData = Data()
            for try await b in bytes { errData.append(b); if errData.count > 8000 { break } }
            throw Self.errorFrom(status: http.statusCode, data: errData)
        }
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard case .data(let payload)? = SSEParser.parse(line: line), let d = payload.data(using: .utf8),
                  let event = try? decoder.decode(ImageStreamEvent.self, from: d) else { continue }
            switch event.type {
            case "image_generation.partial_image":
                if let b64 = event.b64JSON, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) { await onPartial(data) }
            case "image_generation.completed":
                return ImageGenerationResponse(data: [.init(b64JSON: event.b64JSON, mediaType: event.mediaType)], usage: event.usage)
            case "error":
                throw OpenRouterError.stream(event.error?.message ?? "Image generation failed.")
            default: continue
            }
        }
        throw OpenRouterError.stream("The image stream ended before the image was finished.")
    }

    /// Returns the audio, the generation id (for cost lookup) and the content type.
    func speech(_ request: SpeechRequest) async throws -> (data: Data, generationID: String?, contentType: String?) {
        var req = Self.makeRequest(path: "audio/speech", method: "POST", key: try requireKey(), body: try Self.encoder.encode(request))
        req.timeoutInterval = 180
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Self.errorFrom(status: http.statusCode, data: data) }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true {
            throw Self.errorFrom(status: 500, data: data)
        }
        return (data, http.value(forHTTPHeaderField: "X-Generation-Id"), http.value(forHTTPHeaderField: "Content-Type"))
    }

    func submitVideo(_ request: VideoGenerationRequest) async throws -> VideoJob {
        let req = Self.makeRequest(path: "videos", method: "POST", key: try requireKey(), body: try Self.encoder.encode(request))
        return try await send(req, as: VideoJob.self)
    }

    func pollVideo(jobID: String) async throws -> VideoJob {
        try await send(Self.makeRequest(path: "videos/\(jobID)", key: try requireKey()), as: VideoJob.self)
    }

    func downloadVideo(jobID: String, index: Int = 0) async throws -> Data {
        var req = Self.makeRequest(path: "videos/\(jobID)/content?index=\(index)", key: try requireKey())
        req.timeoutInterval = 600
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.errorFrom(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        }
        return data
    }

    func download(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "Download failed")
        }
        return data
    }

    // MARK: Account

    func keyInfo() async throws -> KeyInfo {
        try await send(Self.makeRequest(path: "key", key: try requireKey()), as: DataEnvelope<KeyInfo>.self).data
    }

    func credits(managementKey: String) async throws -> CreditsInfo {
        try await send(Self.makeRequest(path: "credits", key: managementKey), as: DataEnvelope<CreditsInfo>.self).data
    }

    /// Generation stats can 404 briefly after a request finishes, so retry with backoff.
    func generation(id: String, attempts: Int = 5) async throws -> GenerationStats {
        var delay: UInt64 = 800_000_000
        var lastError: Error = OpenRouterError.invalidResponse
        for attempt in 0..<attempts {
            do {
                return try await send(Self.makeRequest(path: "generation?id=\(id)", key: try requireKey()),
                                      as: DataEnvelope<GenerationStats>.self).data
            } catch {
                lastError = error
                if attempt == attempts - 1 { break }
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 5_000_000_000)
            }
        }
        throw lastError
    }

    // MARK: OAuth

    static func exchangeOAuthCode(code: String, verifier: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        let req = makeRequest(path: "auth/keys", method: "POST", key: nil, body: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw errorFrom(status: http.statusCode, data: data) }
        return try JSONDecoder().decode(OAuthKeyResponse.self, from: data).key
    }
}
