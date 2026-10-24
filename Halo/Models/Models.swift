import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var titleIsSet: Bool
    var createdAt: Date
    var updatedAt: Date
    var modelID: String
    var personaID: UUID?
    var isPinned: Bool
    /// Position among pinned chats, lowest first. Nil for chats pinned before ordering existed.
    var pinOrder: Int?
    /// When the chat was archived. Archived chats are hidden from the main list.
    var archivedAt: Date?
    /// Kept in step with `searchModeRaw` so older builds and backups still read sensibly.
    var webSearch: Bool
    /// A `SearchMode` raw value; nil for chats from before it existed (they follow `webSearch`).
    var searchModeRaw: String?
    var reasoningEffort: String?
    /// A `ServiceTier` raw value; nil follows the default in Settings.
    var serviceTier: String?
    var totalCost: Double
    /// Last message of the branch on screen (see Branching.swift). Nil for chats from before branching.
    var activeLeafID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation) var messages: [Message] = []

    init(modelID: String, personaID: UUID? = nil, searchMode: SearchMode? = nil, reasoningEffort: String? = nil) {
        self.id = UUID()
        self.title = "New chat"
        self.titleIsSet = false
        self.createdAt = .now
        self.updatedAt = .now
        self.modelID = modelID
        self.personaID = personaID
        self.isPinned = false
        self.webSearch = searchMode.map { $0 != .off } ?? false
        self.searchModeRaw = searchMode?.rawValue
        self.reasoningEffort = reasoningEffort
        self.totalCost = 0
    }

    var searchMode: SearchMode {
        get { searchModeRaw.flatMap(SearchMode.init(rawValue:)) ?? (webSearch ? .auto : .off) }
        set {
            searchModeRaw = newValue.rawValue
            webSearch = newValue != .off
        }
    }

    var nextSortIndex: Int { (messages.map(\.sortIndex).max() ?? -1) + 1 }

    var isArchived: Bool {
        get { archivedAt != nil }
        set { archivedAt = newValue ? (archivedAt ?? .now) : nil }
    }
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sortIndex: Int
    /// The message this one follows on its branch; nil for a first message or chats from before branching.
    var parentID: UUID?
    var roleRaw: String
    var text: String
    var reasoning: String
    var reasoningDetailsData: Data?
    var toolCallsData: Data?
    var toolCallID: String?
    var toolStateData: Data?
    var annotationsData: Data?
    var mediaData: Data?
    var modelID: String?
    var provider: String?
    /// The tier that served the reply, as the response reported it ("default", "flex", "priority").
    var serviceTier: String?
    var generationID: String?
    var usageData: Data?
    var cost: Double
    var latency: Double?          // seconds to first token
    var duration: Double?         // seconds total
    var statusRaw: String
    var errorText: String?
    /// The reply read aloud (encoded `[MediaItem]`, in order), kept so playing it again is free.
    var spokenAudioData: Data?
    var conversation: Conversation?

    init(role: MessageRole, text: String = "", sortIndex: Int = 0, modelID: String? = nil, status: MessageStatus = .complete) {
        self.id = UUID()
        self.createdAt = .now
        self.sortIndex = sortIndex
        self.roleRaw = role.rawValue
        self.text = text
        self.reasoning = ""
        self.modelID = modelID
        self.cost = 0
        self.statusRaw = status.rawValue
    }

    var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .user }
    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .complete }
        set { statusRaw = newValue.rawValue }
    }

    var toolCalls: [ToolCall] {
        get { toolCallsData?.decoded([ToolCall].self) ?? [] }
        set { toolCallsData = newValue.isEmpty ? nil : newValue.encoded }
    }
    var reasoningDetails: [JSONValue] {
        get { reasoningDetailsData?.decoded([JSONValue].self) ?? [] }
        set { reasoningDetailsData = newValue.isEmpty ? nil : newValue.encoded }
    }
    var annotations: [JSONValue] {
        get { annotationsData?.decoded([JSONValue].self) ?? [] }
        set { annotationsData = newValue.isEmpty ? nil : newValue.encoded }
    }
    var media: [MediaItem] {
        get { mediaData?.decoded([MediaItem].self) ?? [] }
        set { mediaData = newValue.isEmpty ? nil : newValue.encoded }
    }
    var toolState: ToolState? {
        get { toolStateData?.decoded(ToolState.self) }
        set { toolStateData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    var usage: Usage? {
        get { usageData?.decoded(Usage.self) }
        set { usageData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    var spokenAudio: [MediaItem] {
        get { spokenAudioData?.decoded([MediaItem].self) ?? [] }
        set { spokenAudioData = newValue.isEmpty ? nil : newValue.encoded }
    }
    var citations: [Citation] { Citation.from(annotations: annotations) }
}

@Model
final class Artifact {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID?
    var title: String
    var kindRaw: String
    var language: String?
    var createdAt: Date
    var updatedAt: Date
    var versionsData: Data?

    init(title: String, kind: ArtifactKind, language: String?, content: String, conversationID: UUID?) {
        self.id = UUID()
        self.conversationID = conversationID
        self.title = title
        self.kindRaw = kind.rawValue
        self.language = language
        self.createdAt = .now
        self.updatedAt = .now
        self.versionsData = [ArtifactVersion(number: 1, content: content, createdAt: .now, summary: "Created")].encoded
    }

    var kind: ArtifactKind { ArtifactKind(rawValue: kindRaw) ?? .markdown }
    var versions: [ArtifactVersion] {
        get { versionsData?.decoded([ArtifactVersion].self) ?? [] }
        set { versionsData = newValue.encoded }
    }
    var latest: ArtifactVersion? { versions.last }
    var latestContent: String { latest?.content ?? "" }

    func version(_ number: Int?) -> ArtifactVersion? {
        guard let number else { return latest }
        return versions.first { $0.number == number } ?? latest
    }

    @discardableResult
    func addVersion(content: String, summary: String?) -> Int {
        var v = versions
        let n = (v.last?.number ?? 0) + 1
        v.append(ArtifactVersion(number: n, content: content, createdAt: .now, summary: summary))
        versions = v
        updatedAt = .now
        return n
    }
}

@Model
final class Persona {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var systemPrompt: String
    var modelID: String?
    var reasoningEffort: String?
    var capabilitiesRaw: String
    /// Kept in step with `searchModeRaw`: true when new chats always search.
    var alwaysSearch: Bool
    /// A `SearchMode` raw value for new chats; nil for personas from before it existed.
    var searchModeRaw: String?
    var isBuiltin: Bool
    var sortIndex: Int

    init(name: String, icon: String, colorHex: String, systemPrompt: String, modelID: String?,
         reasoningEffort: String?, capabilities: [ToolCapability], alwaysSearch: Bool, isBuiltin: Bool, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.systemPrompt = systemPrompt
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.capabilitiesRaw = capabilities.map(\.rawValue).joined(separator: ",")
        self.alwaysSearch = alwaysSearch
        self.isBuiltin = isBuiltin
        self.sortIndex = sortIndex
    }

    var searchMode: SearchMode {
        get { searchModeRaw.flatMap(SearchMode.init(rawValue:)) ?? (alwaysSearch ? .always : .auto) }
        set {
            searchModeRaw = newValue.rawValue
            alwaysSearch = newValue == .always
        }
    }

    var capabilities: Set<ToolCapability> {
        get { Set(capabilitiesRaw.split(separator: ",").compactMap { ToolCapability(rawValue: String($0)) }) }
        set { capabilitiesRaw = ToolCapability.allCases.filter { newValue.contains($0) }.map(\.rawValue).joined(separator: ",") }
    }
}

@Model
final class UsageRecord {
    var id: UUID
    var date: Date
    var conversationID: UUID?
    var messageID: UUID?
    var kindRaw: String
    var modelID: String
    var cost: Double
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int
    var reasoningTokens: Int

    init(kind: UsageKind, modelID: String, cost: Double, conversationID: UUID?, messageID: UUID?,
         promptTokens: Int = 0, completionTokens: Int = 0, cachedTokens: Int = 0, reasoningTokens: Int = 0) {
        self.id = UUID()
        self.date = .now
        self.kindRaw = kind.rawValue
        self.modelID = modelID
        self.cost = cost
        self.conversationID = conversationID
        self.messageID = messageID
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }

    var kind: UsageKind { UsageKind(rawValue: kindRaw) ?? .other }
}
