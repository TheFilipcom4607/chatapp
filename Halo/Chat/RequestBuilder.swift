import Foundation

/// Turns a stored conversation into an OpenRouter chat request.
@MainActor
struct RequestBuilder {
    let conversation: Conversation
    let persona: Persona?
    let settings: AppSettings
    let catalog: ModelCatalog
    let artifacts: [Artifact]
    var includeTitleInstruction: Bool

    var capabilities: Set<ToolCapability> { persona?.capabilities ?? Set(ToolCapability.allCases) }

    func build(excluding excludedID: UUID? = nil) -> ChatRequest {
        let modelID = conversation.modelID
        let model = catalog.model(modelID)
        let toolsSupported = model?.supportsTools ?? true
        var messages: [ChatMessage] = [.system(systemPrompt(toolsSupported: toolsSupported))]
        var hasPDF = false

        let ordered = conversation.orderedMessages.filter { $0.id != excludedID }
        var i = 0
        while i < ordered.count {
            let msg = ordered[i]
            switch msg.role {
            case .user:
                let (cm, pdf) = userMessage(msg, model: model)
                hasPDF = hasPDF || pdf
                messages.append(cm)
                i += 1
            case .assistant:
                let calls = msg.toolCalls
                if msg.text.isEmpty && calls.isEmpty { i += 1; continue }
                if msg.status == .failed && calls.isEmpty { i += 1; continue }
                var cm = ChatMessage.assistant(msg.text.isEmpty ? nil : msg.text, toolCalls: calls.isEmpty ? nil : calls)
                if msg.modelID == modelID, !msg.reasoningDetails.isEmpty { cm.reasoningDetails = msg.reasoningDetails }
                let fileAnnotations = msg.annotations.filter { $0["type"]?.stringValue == "file" }
                if !fileAnnotations.isEmpty { cm.annotations = fileAnnotations }
                messages.append(cm)
                i += 1
                // Gather tool results that answer these calls; synthesize any missing ones.
                if !calls.isEmpty {
                    var results: [String: String] = [:]
                    while i < ordered.count, ordered[i].role == .tool {
                        if let id = ordered[i].toolCallID { results[id] = toolContent(ordered[i]) }
                        i += 1
                    }
                    for call in calls {
                        messages.append(.tool(callID: call.id, content: results[call.id] ?? "No result (the tool did not run)."))
                    }
                }
            case .tool:
                i += 1   // orphaned tool message; skip
            case .system:
                i += 1
            }
        }

        var request = ChatRequest(model: modelID, messages: messages)
        if toolsSupported {
            let search = conversation.webSearch && capabilities.contains(.search)
            let tools = ToolDefinitions.tools(for: capabilities, webSearch: search)
            if !tools.isEmpty {
                request.tools = tools
                if search { request.maxToolCalls = 8 }
            }
        } else if conversation.webSearch && capabilities.contains(.search) {
            // Models without tool support can still search via the (legacy) web plugin.
            request.plugins = [["id": "web", "max_results": 5]]
        }
        if let effort = conversation.reasoningEffort ?? persona?.reasoningEffort, let model, model.supportsReasoning {
            if effort == "none" {
                if model.reasoning?.mandatory != true { request.reasoning = ReasoningConfig(effort: "none") }
            } else if model.reasoningEfforts.contains(effort) || model.reasoning?.supportedEfforts == nil {
                request.reasoning = ReasoningConfig(effort: effort)
            } else if let fallback = closestEffort(effort, in: model.reasoningEfforts) {
                request.reasoning = ReasoningConfig(effort: fallback)
            }
        }
        if hasPDF {
            var engine = settings.pdfEngine
            if engine == "auto" { engine = (model?.supportsFiles ?? false) ? "native" : "cloudflare-ai" }
            var plugins = request.plugins ?? []
            plugins.append(["id": "file-parser", "pdf": ["engine": .string(engine)]])
            request.plugins = plugins
        }
        if settings.promptCaching, modelID.hasPrefix("anthropic/") {
            request.cacheControl = ["type": "ephemeral"]
        }
        request.sessionID = conversation.id.uuidString
        return request
    }

    private func closestEffort(_ wanted: String, in available: [String]) -> String? {
        let scale = ["minimal", "low", "medium", "high", "xhigh", "max"]
        guard let w = scale.firstIndex(of: wanted) else { return available.first }
        return available.min { a, b in
            abs((scale.firstIndex(of: a) ?? 2) - w) < abs((scale.firstIndex(of: b) ?? 2) - w)
        }
    }

    private func toolContent(_ msg: Message) -> String {
        guard let state = msg.toolState else { return msg.text }
        switch state.status {
        case .awaitingApproval: return "Waiting for the user's approval."
        case .running: return "Still running."
        default: return msg.text.isEmpty ? (state.summary ?? "Done.") : msg.text
        }
    }

    private func userMessage(_ msg: Message, model: ORModel?) -> (ChatMessage, Bool) {
        let media = msg.media
        guard !media.isEmpty else { return (.user(msg.text), false) }
        var parts: [ContentPart] = []
        var notes: [String] = []
        var hasPDF = false
        var extra: [ContentPart] = []
        for item in media {
            switch item.kind {
            case .image:
                notes.append("[Attached image id: \(item.refID)]")
                if (model?.supportsVision ?? true), let url = MediaStore.dataURL(for: item) {
                    extra.append(.imageURL(url, detail: "auto"))
                }
            case .pdf:
                hasPDF = true
                if let url = MediaStore.dataURL(for: item) {
                    extra.append(.file(filename: item.originalName ?? "document.pdf", data: url))
                }
            case .text:
                if let data = MediaStore.data(for: item), let text = String(data: data, encoding: .utf8) {
                    let name = item.originalName ?? "file.txt"
                    notes.append("File \(name):\n```\n\(text.prefix(200_000))\n```")
                }
            case .audio:
                if (model?.supportsAudioInput ?? false), let data = MediaStore.data(for: item) {
                    extra.append(.inputAudio(data: data.base64EncodedString(), format: MediaStore.ext(forMime: item.mimeType)))
                }
            case .video:
                notes.append("[Attached video: \(item.originalName ?? "video")]")
            }
        }
        let text = ([msg.text] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
        parts.append(.text(text.isEmpty ? "(attachment)" : text))
        parts.append(contentsOf: extra)
        return (.user(parts: parts), hasPDF)
    }

    private var userNameNote: String {
        let name = settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : " The user's name is \(name)."
    }

    func systemPrompt(toolsSupported: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        var lines: [String] = []
        lines.append(persona?.systemPrompt ?? DefaultPersonas.seeds[0].prompt)
        lines.append("""

        Context: You are running inside Halo, a native iPhone chat app.\(userNameNote) Current date and time: \(formatter.string(from: .now)) (\(TimeZone.current.identifier)). You are the model "\(conversation.modelID)" via OpenRouter.
        Formatting: The app renders GitHub-flavored Markdown (headings, lists, tables, task lists), fenced code blocks with a language tag (with copy/run/preview buttons), and LaTeX math with $…$ inline and $$…$$ display. Keep paragraphs short for a phone screen.
        """)
        if toolsSupported {
            let caps = capabilities
            var toolNotes: [String] = []
            if caps.contains(.images) { toolNotes.append("- generate_image: create or edit images. Images the user attached or you generated have ids like img_ab12cd you can pass as references.") }
            if caps.contains(.video) { toolNotes.append("- generate_video: short video clips; slow and costly, only when asked.") }
            if caps.contains(.speech) { toolNotes.append("- generate_speech: speak text aloud with a natural voice.") }
            if caps.contains(.code) { toolNotes.append("- run_code: execute Python or JavaScript for exact computation, data work and charts.") }
            if caps.contains(.artifacts) { toolNotes.append("- create_artifact / update_artifact: substantial documents, programs, web pages, React apps, SVGs and diagrams open in a canvas with live preview and versions.") }
            if conversation.webSearch && caps.contains(.search) { toolNotes.append("- Web search is available: search for current or factual information and cite sources inline as markdown links.") }
            if !toolNotes.isEmpty {
                lines.append("\nTools you can use (call them whenever they help; never fake their output):\n" + toolNotes.joined(separator: "\n"))
            }
            if !artifacts.isEmpty, caps.contains(.artifacts) {
                let list = artifacts.map { "- \($0.id.uuidString): \"\($0.title)\" (\($0.kind.rawValue), v\($0.latest?.number ?? 1))" }
                lines.append("\nArtifacts in this chat (use these ids with update_artifact):\n" + list.joined(separator: "\n"))
            }
        }
        if includeTitleInstruction {
            lines.append("\nIMPORTANT: Start your reply with a concise 2–6 word title for this chat wrapped in <title></title> on the first line (for example <title>Paris weekend itinerary</title>), then continue with your normal answer. Do not mention the title otherwise.")
        }
        return lines.joined(separator: "\n")
    }
}
