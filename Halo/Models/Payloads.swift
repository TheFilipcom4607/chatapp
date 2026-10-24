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
    /// What a device or web tool found, for its card (a place list, a forecast, a page).
    var card: ToolCard?
}

/// A tool result laid out for the chat: a heading, a few rows and an optional button that opens a
/// link (Maps, Safari…) when the user taps it. Nothing opens on its own.
struct ToolCard: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Sendable {
        var title: String
        var detail: String?
        var trailing: String?
        var symbol: String?
        /// Tapping the row opens this (a place in Maps, an event's link).
        var url: String?
    }

    var symbol: String
    var title: String
    var subtitle: String?
    /// A large figure for the heading, like the temperature.
    var value: String?
    var rows: [Row] = []
    var buttonTitle: String?
    var buttonURL: String?
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
    /// Image models with a quality knob: "auto", "low" … "max".
    var quality: String?
    /// "transparent" for a cut-out image; nil leaves the background to the model.
    var background: String?
    /// Show partial renders while the image is made, for models that stream.
    var stream: Bool?
    var referenceIDs: [String]?
    var estimatedCost: Double?
    // Calendar and reminders: what's added once the user approves.
    var title: String?
    var start: Date?
    var end: Date?
    var allDay: Bool?
    var notes: String?
    var location: String?
    /// The calendar or reminder list, by title; nil uses the default one.
    var listName: String?
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
    case readWebPage = "read_web_page"
    case deviceInfo = "device_info"
    case openInApp = "open_in_app"
    case getLocation = "get_location"
    case getWeather = "get_weather"
    case searchPlaces = "search_places"
    case getDirections = "get_directions"
    case listEvents = "list_events"
    case listReminders = "list_reminders"
    case createEvent = "create_event"
    case createReminder = "create_reminder"

    var needsApproval: Bool {
        switch self {
        case .generateImage, .generateVideo, .createEvent, .createReminder: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .generateImage: return "Image"
        case .generateVideo: return "Video"
        case .generateSpeech: return "Speech"
        case .runCode: return "Code"
        case .shell: return "Shell"
        case .createArtifact, .updateArtifact: return "Document"
        case .readWebPage: return "Web page"
        case .deviceInfo: return "Device"
        case .openInApp: return "Link"
        case .getLocation: return "Location"
        case .getWeather: return "Weather"
        case .searchPlaces: return "Places"
        case .getDirections: return "Directions"
        case .listEvents, .createEvent: return "Calendar"
        case .listReminders, .createReminder: return "Reminders"
        }
    }
}

/// When a chat may search the web: never, when the model decides it needs to, or before every answer.
enum SearchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, auto, always

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .always: return "Always"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Uses only what the model knows"
        case .auto: return "Searches when it helps"
        case .always: return "Searches before every answer"
        }
    }
}

/// Capability toggles a persona can switch on (and Settings › Tools can switch off everywhere).
enum ToolCapability: String, Codable, CaseIterable, Sendable, Identifiable {
    case images, video, speech, code, artifacts, search
    case webPages, calendar, location, maps, appLinks, device

    /// The capabilities that existed before the device and web tools.
    static let original: Set<ToolCapability> = [.images, .video, .speech, .code, .artifacts, .search]

    /// What a chat can use: its persona's tools minus the ones switched off in Settings.
    static func effective(_ persona: Set<ToolCapability>?, disabled: [String]) -> Set<ToolCapability> {
        (persona ?? Set(allCases)).subtracting(disabled.compactMap(ToolCapability.init(rawValue:)))
    }

    var id: String { rawValue }
    var label: String {
        switch self {
        case .images: return "Image generation"
        case .video: return "Video generation"
        case .speech: return "Speech"
        case .code: return "Run code & shell"
        case .artifacts: return "Documents & previews"
        case .search: return "Web search"
        case .webPages: return "Read web pages"
        case .calendar: return "Calendar & Reminders"
        case .location: return "Location & weather"
        case .maps: return "Maps & places"
        case .appLinks: return "Open in apps"
        case .device: return "Device info"
        }
    }
    var detail: String {
        switch self {
        case .images: return "Make and edit pictures (you approve each one)"
        case .video: return "Short clips (you approve each one)"
        case .speech: return "Say things aloud with a voice model"
        case .code: return "Python, JavaScript and web requests"
        case .artifacts: return "Documents, code and apps in a canvas"
        case .search: return "Look things up on the web"
        case .webPages: return "Open a link and read the page"
        case .calendar: return "See your events and reminders; add them with your OK"
        case .location: return "Your city when asked, and the forecast"
        case .maps: return "Find places nearby and travel times"
        case .appLinks: return "Buttons that open Maps, Safari, Music or Shortcuts"
        case .device: return "Battery, storage, iOS version and local time"
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
        case .webPages: return "doc.text.magnifyingglass"
        case .calendar: return "calendar"
        case .location: return "location"
        case .maps: return "map"
        case .appLinks: return "arrow.up.forward.app"
        case .device: return "iphone"
        }
    }
}

extension Array where Element: Codable {
    var encoded: Data? { try? JSONEncoder().encode(self) }
}

extension Data {
    func decoded<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: self) }
}
