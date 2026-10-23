import Foundation

/// A file stored in the app's media folder (attachment or generated output).
struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case image, audio, video, pdf, text }

    var id: String
    var kind: Kind
    var filename: String          // file name inside MediaStore
    var mimeType: String
    var originalName: String?
    var prompt: String?
    var model: String?
    var width: Double?
    var height: Double?
    var duration: Double?

    /// Short id the model can refer to (e.g. in edit_image).
    var refID: String { "img_" + id.prefix(6).lowercased() }
}

/// Tool execution status stored on tool messages.
enum ToolStatus: String, Codable, Sendable {
    case running, awaitingApproval, done, declined, failed
}

/// Extra state for tool-result messages (role == tool).
struct ToolState: Codable, Hashable, Sendable {
    var name: String
    var arguments: String
    var status: ToolStatus
    var summary: String?          // short human readable result line
    var output: String?           // console output / result text shown in UI
    var artifactID: UUID?
    var artifactVersion: Int?
    var videoJobID: String?
    var progressNote: String?
    var approval: ApprovalParams?
}

/// User-editable parameters on an approval card.
struct ApprovalParams: Codable, Hashable, Sendable {
    var prompt: String
    var model: String
    var aspectRatio: String?
    var resolution: String?
    var duration: Int?
    var count: Int?
    var generateAudio: Bool?
    var referenceIDs: [String]?
    var estimatedCost: Double?
}

enum MessageRole: String, Codable, Sendable { case system, user, assistant, tool }

enum MessageStatus: String, Codable, Sendable {
    case complete, streaming, failed, background, cancelled
}

enum UsageKind: String, Codable, Sendable, CaseIterable {
    case chat, image, video, speech, other

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .image: return "Images"
        case .video: return "Video"
        case .speech: return "Speech"
        case .other: return "Other"
        }
    }
}

enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case markdown, code, html, react, svg, mermaid

    var label: String {
        switch self {
        case .markdown: return "Document"
        case .code: return "Code"
        case .html: return "Web page"
        case .react: return "React app"
        case .svg: return "SVG"
        case .mermaid: return "Diagram"
        }
    }

    var icon: String {
        switch self {
        case .markdown: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .html: return "globe"
        case .react: return "atom"
        case .svg: return "scribble.variable"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        }
    }

    var isRenderable: Bool { self != .code }
}

struct ArtifactVersion: Codable, Hashable, Sendable, Identifiable {
    var number: Int
    var content: String
    var createdAt: Date
    var summary: String?
    var id: Int { number }
}

/// Known tool names offered to the model.
enum ToolName: String, CaseIterable, Sendable {
    case generateImage = "generate_image"
    case generateVideo = "generate_video"
    case generateSpeech = "generate_speech"
    case runCode = "run_code"
    case shell = "shell"
    case createArtifact = "create_artifact"
    case updateArtifact = "update_artifact"

    var needsApproval: Bool { self == .generateImage || self == .generateVideo }

    var displayName: String {
        switch self {
        case .generateImage: return "Image"
        case .generateVideo: return "Video"
        case .generateSpeech: return "Speech"
        case .runCode: return "Code"
        case .shell: return "Shell"
        case .createArtifact, .updateArtifact: return "Document"
        }
    }
}

/// Capability toggles a persona can switch on.
enum ToolCapability: String, Codable, CaseIterable, Sendable, Identifiable {
    case images, video, speech, code, artifacts, search

    var id: String { rawValue }
    var label: String {
        switch self {
        case .images: return "Image generation"
        case .video: return "Video generation"
        case .speech: return "Speech"
        case .code: return "Run code & shell"
        case .artifacts: return "Documents & previews"
        case .search: return "Web search"
        }
    }
    var icon: String {
        switch self {
        case .images: return "photo.on.rectangle.angled"
        case .video: return "film"
        case .speech: return "waveform"
        case .code: return "terminal"
        case .artifacts: return "doc.richtext"
        case .search: return "globe"
        }
    }
}

extension Array where Element: Codable {
    var encoded: Data? { try? JSONEncoder().encode(self) }
}

extension Data {
    func decoded<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: self) }
}
