import Foundation

// MARK: - Request

struct ChatRequest: Encodable, Sendable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool = true
    var tools: [ToolSpec]? = nil
    var toolChoice: String? = nil
    var parallelToolCalls: Bool? = nil
    var reasoning: ReasoningConfig? = nil
    var maxTokens: Int? = nil
    var temperature: Double? = nil
    var plugins: [JSONValue]? = nil
    var cacheControl: JSONValue? = nil
    var sessionID: String? = nil
    var maxToolCalls: Int? = nil
    var user: String? = nil
    var transforms: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools, reasoning, temperature, plugins, user, transforms
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case maxTokens = "max_tokens"
        case cacheControl = "cache_control"
        case sessionID = "session_id"
        case maxToolCalls = "max_tool_calls"
    }
}

struct ReasoningConfig: Codable, Hashable, Sendable {
    var effort: String? = nil
    var maxTokens: Int? = nil
    var exclude: Bool? = nil
    var enabled: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case effort, exclude, enabled
        case maxTokens = "max_tokens"
    }
}

/// A tool offered to the model. Either a client-side function or an OpenRouter server tool.
enum ToolSpec: Encodable, Sendable {
    case function(name: String, description: String, parameters: JSONValue)
    case server(type: String, parameters: JSONValue?)

    enum CodingKeys: String, CodingKey { case type, function, parameters }
    enum FunctionKeys: String, CodingKey { case name, description, parameters }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .function(name, description, parameters):
            try c.encode("function", forKey: .type)
            var f = c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
            try f.encode(name, forKey: .name)
            try f.encode(description, forKey: .description)
            try f.encode(parameters, forKey: .parameters)
        case let .server(type, parameters):
            try c.encode(type, forKey: .type)
            if let parameters { try c.encode(parameters, forKey: .parameters) }
        }
    }

    var name: String {
        switch self {
        case .function(let name, _, _): return name
        case .server(let type, _): return type
        }
    }
}

struct ChatMessage: Codable, Hashable, Sendable {
    var role: String
    var content: MessageContent?
    var toolCalls: [ToolCall]? = nil
    var toolCallID: String? = nil
    var reasoning: String? = nil
    var reasoningDetails: [JSONValue]? = nil
    var annotations: [JSONValue]? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning, annotations
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningDetails = "reasoning_details"
    }

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: .text(text)) }
    static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: .text(text)) }
    static func user(parts: [ContentPart]) -> ChatMessage { ChatMessage(role: "user", content: .parts(parts)) }
    static func assistant(_ text: String?, toolCalls: [ToolCall]? = nil) -> ChatMessage {
        ChatMessage(role: "assistant", content: text.map { .text($0) }, toolCalls: toolCalls)
    }
    static func tool(callID: String, content: String) -> ChatMessage {
        ChatMessage(role: "tool", content: .text(content), toolCallID: callID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        // Assistant messages that only carry tool calls must send `content: null`.
        if let content { try c.encode(content, forKey: .content) } else { try c.encodeNil(forKey: .content) }
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encodeIfPresent(reasoningDetails, forKey: .reasoningDetails)
        try c.encodeIfPresent(annotations, forKey: .annotations)
    }
}

enum MessageContent: Codable, Hashable, Sendable {
    case text(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .parts(try c.decode([ContentPart].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .parts(let p): try c.encode(p)
        }
    }

    var plainText: String {
        switch self {
        case .text(let s): return s
        case .parts(let parts): return parts.compactMap { if case .text(let t, _) = $0 { return t } else { return nil } }.joined(separator: "\n")
        }
    }
}

enum ContentPart: Codable, Hashable, Sendable {
    case text(String, cacheControl: Bool = false)
    case imageURL(String, detail: String? = nil)
    case file(filename: String, data: String)
    case inputAudio(data: String, format: String)

    enum CodingKeys: String, CodingKey {
        case type, text, file
        case imageURL = "image_url"
        case inputAudio = "input_audio"
        case cacheControl = "cache_control"
    }
    enum ImageKeys: String, CodingKey { case url, detail }
    enum FileKeys: String, CodingKey { case filename; case fileData = "file_data" }
    enum AudioKeys: String, CodingKey { case data, format }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "image_url":
            let i = try c.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
            self = .imageURL(try i.decode(String.self, forKey: .url), detail: try i.decodeIfPresent(String.self, forKey: .detail))
        case "file":
            let f = try c.nestedContainer(keyedBy: FileKeys.self, forKey: .file)
            self = .file(filename: try f.decodeIfPresent(String.self, forKey: .filename) ?? "file",
                         data: try f.decodeIfPresent(String.self, forKey: .fileData) ?? "")
        case "input_audio":
            let a = try c.nestedContainer(keyedBy: AudioKeys.self, forKey: .inputAudio)
            self = .inputAudio(data: try a.decode(String.self, forKey: .data), format: try a.decode(String.self, forKey: .format))
        default:
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "", cacheControl: false)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, cache):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            if cache { try c.encode(JSONValue.object(["type": "ephemeral"]), forKey: .cacheControl) }
        case let .imageURL(url, detail):
            try c.encode("image_url", forKey: .type)
            var i = c.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
            try i.encode(url, forKey: .url)
            try i.encodeIfPresent(detail, forKey: .detail)
        case let .file(filename, data):
            try c.encode("file", forKey: .type)
            var f = c.nestedContainer(keyedBy: FileKeys.self, forKey: .file)
            try f.encode(filename, forKey: .filename)
            try f.encode(data, forKey: .fileData)
        case let .inputAudio(data, format):
            try c.encode("input_audio", forKey: .type)
            var a = c.nestedContainer(keyedBy: AudioKeys.self, forKey: .inputAudio)
            try a.encode(data, forKey: .data)
            try a.encode(format, forKey: .format)
        }
    }
}

struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var type: String = "function"
    var function: FunctionCall

    struct FunctionCall: Codable, Hashable, Sendable {
        var name: String
        var arguments: String
    }

    var name: String { function.name }
    var argumentsJSON: JSONValue { JSONValue.parse(function.arguments) ?? .object([:]) }
}

// MARK: - Streaming response

struct ChatChunk: Decodable, Sendable {
    var id: String?
    var model: String?
    var provider: String?
    var choices: [Choice]?
    var usage: Usage?
    var error: APIErrorBody?

    struct Choice: Decodable, Sendable {
        var index: Int?
        var delta: Delta?
        var message: ResponseMessage?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta, message
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable, Sendable {
        var role: String?
        var content: String?
        var reasoning: String?
        var reasoningDetails: [JSONValue]?
        var toolCalls: [ToolCallDelta]?
        var annotations: [JSONValue]?
        var images: [JSONValue]?

        enum CodingKeys: String, CodingKey {
            case role, content, reasoning, annotations, images
            case reasoningDetails = "reasoning_details"
            case toolCalls = "tool_calls"
        }
    }
}

struct ToolCallDelta: Decodable, Sendable {
    var index: Int?
    var id: String?
    var type: String?
    var function: FunctionDelta?

    struct FunctionDelta: Decodable, Sendable {
        var name: String?
        var arguments: String?
    }
}

/// Non-streaming response (used by the background runner).
struct ChatCompletion: Decodable, Sendable {
    var id: String?
    var model: String?
    var provider: String?
    var choices: [Choice]?
    var usage: Usage?
    var error: APIErrorBody?

    struct Choice: Decodable, Sendable {
        var message: ResponseMessage?
        var finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
}

struct ResponseMessage: Decodable, Sendable {
    var role: String?
    var content: String?
    var reasoning: String?
    var reasoningDetails: [JSONValue]?
    var toolCalls: [ToolCall]?
    var annotations: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning, annotations
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls"
    }
}

struct APIErrorBody: Codable, Sendable, Hashable {
    var code: FlexibleString?
    var message: String?
    var metadata: JSONValue?
}

struct APIErrorEnvelope: Decodable, Sendable {
    var error: APIErrorBody
}

struct Usage: Codable, Hashable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var cost: Double?
    var isByok: Bool?
    var promptTokensDetails: PromptDetails?
    var completionTokensDetails: CompletionDetails?
    var serverToolUseDetails: ServerToolUse?
    var serverToolUse: ServerToolUse?

    struct PromptDetails: Codable, Hashable, Sendable {
        var cachedTokens: Int?
        var cacheWriteTokens: Int?
        var audioTokens: Int?
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case audioTokens = "audio_tokens"
        }
    }

    struct CompletionDetails: Codable, Hashable, Sendable {
        var reasoningTokens: Int?
        var imageTokens: Int?
        var audioTokens: Int?
        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
            case imageTokens = "image_tokens"
            case audioTokens = "audio_tokens"
        }
    }

    struct ServerToolUse: Codable, Hashable, Sendable {
        var webSearchRequests: Int?
        enum CodingKeys: String, CodingKey { case webSearchRequests = "web_search_requests" }
    }

    enum CodingKeys: String, CodingKey {
        case cost
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case isByok = "is_byok"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case serverToolUseDetails = "server_tool_use_details"
        case serverToolUse = "server_tool_use"
    }

    var cachedTokens: Int { promptTokensDetails?.cachedTokens ?? 0 }
    var reasoningTokens: Int { completionTokensDetails?.reasoningTokens ?? 0 }
    var webSearches: Int { serverToolUseDetails?.webSearchRequests ?? serverToolUse?.webSearchRequests ?? 0 }
}

// MARK: - Citations

struct Citation: Hashable, Sendable, Identifiable {
    var url: String
    var title: String
    var snippet: String?
    var id: String { url }

    var host: String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }

    /// Extracts url citations from OpenRouter annotations, tolerating unknown shapes.
    static func from(annotations: [JSONValue]) -> [Citation] {
        var seen = Set<String>()
        var result: [Citation] = []
        for a in annotations {
            let type = a["type"]?.stringValue ?? ""
            let body: JSONValue? = a["url_citation"] ?? a["web_search_citation"] ?? (type.contains("citation") ? a : nil)
            guard let body, let url = body["url"]?.stringValue, !seen.contains(url) else { continue }
            seen.insert(url)
            result.append(Citation(url: url,
                                   title: body["title"]?.stringValue ?? url,
                                   snippet: body["content"]?.stringValue ?? body["cited_text"]?.stringValue))
        }
        return result
    }
}
