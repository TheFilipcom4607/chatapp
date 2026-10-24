import Foundation
import SwiftData
import SwiftUI
import UIKit
import WebKit

/// Export / import of chats and artifacts.
@MainActor
enum ExportService {
    // MARK: Markdown

    static func markdown(for conversation: Conversation) -> String {
        var out = "# \(conversation.title)\n\n"
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        out += "_\(df.string(from: conversation.createdAt)) · \(conversation.modelID)_\n\n"
        for m in conversation.orderedMessages {
            switch m.role {
            case .user:
                out += "**You:**\n\n\(m.text)\n\n"
                for item in m.media { out += "_[attachment: \(item.originalName ?? item.kind.rawValue)]_\n\n" }
            case .assistant:
                guard !m.text.isEmpty else { continue }
                out += "**Halo:**\n\n\(m.text)\n\n"
            case .tool:
                if let s = m.toolState { out += "> 🛠 \(s.name): \(s.summary ?? "")\n\n" }
            case .system:
                guard !m.text.isEmpty else { continue }
                out += "---\n\n_Summary of the messages above:_\n\n\(m.text)\n\n---\n\n"
            }
        }
        return out
    }

    // MARK: JSON backup

    /// Fields added after version 1 are optional, so older backups still import.
    struct Backup: Codable {
        var version = 2
        var exportedAt = Date()
        var conversations: [ConversationDTO]
        var artifacts: [ArtifactDTO]
        var personas: [PersonaDTO]?
        var usage: [UsageDTO]?
    }

    struct ConversationDTO: Codable {
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var modelID: String
        var isPinned: Bool
        var totalCost: Double
        var messages: [MessageDTO]
        var pinOrder: Int?
        var archivedAt: Date?
        var activeLeafID: UUID?
        var personaID: UUID?
        var webSearch: Bool?
        var reasoningEffort: String?
        var serviceTier: String?
        var searchMode: String?
    }

    struct MessageDTO: Codable {
        var id: UUID
        var createdAt: Date
        var sortIndex: Int
        var parentID: UUID?
        var role: String
        var text: String
        var reasoning: String
        var toolCalls: [ToolCall]?
        var toolCallID: String?
        var toolState: ToolState?
        var annotations: [JSONValue]?
        var modelID: String?
        var cost: Double
        var media: [MediaItem]?
        var mediaData: [String: Data]?
        var status: String?
        var errorText: String?
        var usage: Usage?
        var reasoningDetails: [JSONValue]?
        var provider: String?
        var serviceTier: String?
        var generationID: String?
        var latency: Double?
        var duration: Double?
    }

    struct PersonaDTO: Codable {
        var id: UUID
        var name: String
        var icon: String
        var colorHex: String
        var systemPrompt: String
        var modelID: String?
        var reasoningEffort: String?
        var capabilities: String
        var alwaysSearch: Bool
        var isBuiltin: Bool
        var sortIndex: Int
        var searchMode: String?
    }

    struct UsageDTO: Codable {
        var id: UUID
        var date: Date
        var conversationID: UUID?
        var messageID: UUID?
        var kind: String
        var modelID: String
        var cost: Double
        var promptTokens: Int
        var completionTokens: Int
        var cachedTokens: Int
        var reasoningTokens: Int
    }

    struct ArtifactDTO: Codable {
        var id: UUID
        var conversationID: UUID?
        var title: String
        var kind: String
        var language: String?
        var createdAt: Date
        var versions: [ArtifactVersion]
    }

    /// Writes a JSON backup (media embedded) and returns its URL.
    static func exportAll(context: ModelContext, includeMedia: Bool = true) throws -> URL {
        let conversations = try context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.createdAt)]))
        let artifacts = try context.fetch(FetchDescriptor<Artifact>())
        let personas = try context.fetch(FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.sortIndex)]))
        let usage = try context.fetch(FetchDescriptor<UsageRecord>(sortBy: [SortDescriptor(\.date)]))
        let backup = Backup(
            conversations: conversations.map { c in
                ConversationDTO(id: c.id, title: c.title, createdAt: c.createdAt, updatedAt: c.updatedAt, modelID: c.modelID,
                                isPinned: c.isPinned, totalCost: c.totalCost,
                                messages: c.messages.sorted { $0.sortIndex < $1.sortIndex }.map { m in
                                    var data: [String: Data]? = nil
                                    if includeMedia, !m.media.isEmpty {
                                        data = Dictionary(uniqueKeysWithValues: m.media.compactMap { item in MediaStore.data(for: item).map { (item.filename, $0) } })
                                    }
                                    return MessageDTO(id: m.id, createdAt: m.createdAt, sortIndex: m.sortIndex, parentID: m.parentID, role: m.roleRaw, text: m.text,
                                                      reasoning: m.reasoning, toolCalls: m.toolCalls.isEmpty ? nil : m.toolCalls,
                                                      toolCallID: m.toolCallID, toolState: m.toolState,
                                                      annotations: m.annotations.isEmpty ? nil : m.annotations, modelID: m.modelID,
                                                      cost: m.cost, media: m.media.isEmpty ? nil : m.media, mediaData: data,
                                                      status: m.statusRaw, errorText: m.errorText, usage: m.usage,
                                                      reasoningDetails: m.reasoningDetails.isEmpty ? nil : m.reasoningDetails,
                                                      provider: m.provider, serviceTier: m.serviceTier, generationID: m.generationID,
                                                      latency: m.latency, duration: m.duration)
                                },
                                pinOrder: c.pinOrder, archivedAt: c.archivedAt, activeLeafID: c.activeLeafID,
                                personaID: c.personaID, webSearch: c.webSearch, reasoningEffort: c.reasoningEffort,
                                serviceTier: c.serviceTier, searchMode: c.searchModeRaw)
            },
            artifacts: artifacts.map { a in
                ArtifactDTO(id: a.id, conversationID: a.conversationID, title: a.title, kind: a.kindRaw, language: a.language,
                            createdAt: a.createdAt, versions: a.versions)
            },
            personas: personas.map { p in
                PersonaDTO(id: p.id, name: p.name, icon: p.icon, colorHex: p.colorHex, systemPrompt: p.systemPrompt,
                           modelID: p.modelID, reasoningEffort: p.reasoningEffort, capabilities: p.capabilitiesRaw,
                           alwaysSearch: p.alwaysSearch, isBuiltin: p.isBuiltin, sortIndex: p.sortIndex,
                           searchMode: p.searchModeRaw)
            },
            usage: usage.map { u in
                UsageDTO(id: u.id, date: u.date, conversationID: u.conversationID, messageID: u.messageID, kind: u.kindRaw,
                         modelID: u.modelID, cost: u.cost, promptTokens: u.promptTokens, completionTokens: u.completionTokens,
                         cachedTokens: u.cachedTokens, reasoningTokens: u.reasoningTokens)
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Halo Backup \(df.string(from: .now)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Imports a backup, skipping conversations that already exist. Returns the number imported.
    @discardableResult
    static func importBackup(from url: URL, context: ModelContext) throws -> Int {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)
        let existing = Set(try context.fetch(FetchDescriptor<Conversation>()).map(\.id))
        var imported = 0
        for dto in backup.conversations where !existing.contains(dto.id) {
            let c = Conversation(modelID: dto.modelID)
            c.id = dto.id
            c.title = dto.title
            c.titleIsSet = true
            c.createdAt = dto.createdAt
            c.updatedAt = dto.updatedAt
            c.isPinned = dto.isPinned
            c.pinOrder = dto.pinOrder
            c.archivedAt = dto.archivedAt
            c.activeLeafID = dto.activeLeafID
            c.totalCost = dto.totalCost
            c.personaID = dto.personaID
            if let webSearch = dto.webSearch { c.webSearch = webSearch }
            c.searchModeRaw = dto.searchMode
            c.reasoningEffort = dto.reasoningEffort
            c.serviceTier = dto.serviceTier
            context.insert(c)
            for md in dto.messages {
                let m = Message(role: MessageRole(rawValue: md.role) ?? .user, text: md.text, sortIndex: md.sortIndex, modelID: md.modelID)
                m.id = md.id
                m.parentID = md.parentID
                m.createdAt = md.createdAt
                m.reasoning = md.reasoning
                m.toolCalls = md.toolCalls ?? []
                m.toolCallID = md.toolCallID
                m.toolState = md.toolState
                m.annotations = md.annotations ?? []
                m.cost = md.cost
                // A reply that was still streaming when the backup was made can't finish now.
                if let status = md.status { m.statusRaw = status == MessageStatus.streaming.rawValue ? MessageStatus.cancelled.rawValue : status }
                m.errorText = md.errorText
                m.usage = md.usage
                m.reasoningDetails = md.reasoningDetails ?? []
                m.provider = md.provider
                m.serviceTier = md.serviceTier
                m.generationID = md.generationID
                m.latency = md.latency
                m.duration = md.duration
                if let media = md.media {
                    // Keep file names inside the media folder, whatever the backup file says.
                    let safe = media.map { item -> MediaItem in
                        var item = item
                        item.filename = (item.filename as NSString).lastPathComponent
                        return item
                    }
                    for (item, original) in zip(safe, media) {
                        if let d = md.mediaData?[original.filename] { try? d.write(to: MediaStore.url(for: item)) }
                    }
                    m.media = safe
                }
                m.conversation = c
                context.insert(m)
            }
            imported += 1
        }
        let existingArtifacts = Set(try context.fetch(FetchDescriptor<Artifact>()).map(\.id))
        for a in backup.artifacts where !existingArtifacts.contains(a.id) {
            let art = Artifact(title: a.title, kind: ArtifactKind(rawValue: a.kind) ?? .markdown, language: a.language, content: "", conversationID: a.conversationID)
            art.id = a.id
            art.createdAt = a.createdAt
            art.versions = a.versions
            context.insert(art)
        }
        let existingPersonas = Set(try context.fetch(FetchDescriptor<Persona>()).map(\.id))
        for p in backup.personas ?? [] where !existingPersonas.contains(p.id) {
            let persona = Persona(name: p.name, icon: p.icon, colorHex: p.colorHex, systemPrompt: p.systemPrompt, modelID: p.modelID,
                                  reasoningEffort: p.reasoningEffort, capabilities: [], alwaysSearch: p.alwaysSearch,
                                  isBuiltin: p.isBuiltin, sortIndex: p.sortIndex)
            persona.id = p.id
            persona.capabilitiesRaw = p.capabilities
            persona.searchModeRaw = p.searchMode
            context.insert(persona)
        }
        let existingUsage = Set(try context.fetch(FetchDescriptor<UsageRecord>()).map(\.id))
        for u in backup.usage ?? [] where !existingUsage.contains(u.id) {
            let record = UsageRecord(kind: UsageKind(rawValue: u.kind) ?? .other, modelID: u.modelID, cost: u.cost,
                                     conversationID: u.conversationID, messageID: u.messageID, promptTokens: u.promptTokens,
                                     completionTokens: u.completionTokens, cachedTokens: u.cachedTokens, reasoningTokens: u.reasoningTokens)
            record.id = u.id
            record.date = u.date
            context.insert(record)
        }
        try context.save()
        return imported
    }

    // MARK: Artifacts

    static func fileURL(for artifact: Artifact, version: ArtifactVersion, format: String) throws -> URL {
        let safe = artifact.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).\(format)")
        let content: String
        switch format {
        case "html": content = artifact.kind == .markdown ? markdownHTML(version.content, title: artifact.title) : HTMLTemplates.page(kind: artifact.kind, content: version.content)
        default: content = version.content
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func defaultExtension(for artifact: Artifact) -> String {
        switch artifact.kind {
        case .markdown: return "md"
        case .html, .react: return artifact.kind == .html ? "html" : "jsx"
        case .svg: return "svg"
        case .mermaid: return "mmd"
        case .code:
            let map = ["python": "py", "javascript": "js", "typescript": "ts", "swift": "swift", "rust": "rs", "go": "go",
                       "java": "java", "kotlin": "kt", "c": "c", "cpp": "cpp", "ruby": "rb", "bash": "sh", "html": "html", "css": "css", "json": "json", "sql": "sql"]
            return map[SyntaxTokenizer.normalize(artifact.language ?? "")] ?? "txt"
        }
    }

    /// Simple standalone HTML for markdown documents (uses marked.js from a CDN).
    static func markdownHTML(_ markdown: String, title: String) -> String {
        let json = (try? String(data: JSONEncoder().encode(markdown), encoding: .utf8)) ?? "\"\""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLTemplates.escape(title))</title>
        <script src="https://cdn.jsdelivr.net/npm/marked@15.0.4/marked.min.js"></script>
        <style>body{font:16px/1.6 -apple-system,system-ui;max-width:760px;margin:40px auto;padding:0 20px;color:#111}
        pre{background:#f4f4f6;padding:12px;border-radius:10px;overflow:auto}code{font-family:ui-monospace,monospace}
        table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:6px 10px}blockquote{border-left:3px solid #8b7cf6;margin:0;padding-left:14px;color:#555}</style>
        </head><body><div id="c"></div><script>document.getElementById('c').innerHTML = marked.parse(\(json));</script></body></html>
        """
    }

    /// Renders HTML into a PDF using an offscreen web view.
    static func pdf(html: String, name: String) async throws -> URL {
        let renderer = PDFRenderer()
        let data = try await renderer.render(html: html)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
private final class PDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    func render(html: String) async throws -> Data {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1100))
        web.navigationDelegate = self
        webView = web
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            web.loadHTMLString(html, baseURL: URL(string: "https://halo.local/"))
        }
        // Let scripts (marked / mermaid / React) render.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let config = WKPDFConfiguration()
        return try await web.pdf(configuration: config)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
