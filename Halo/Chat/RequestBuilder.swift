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
        // Only what follows the latest summary is sent; the summary goes in the system prompt.
        let (summary, history) = ContextBudget.liveHistory(conversation.orderedMessages.filter { $0.id != excludedID })
        var messages: [ChatMessage] = [.system(systemPrompt(toolsSupported: toolsSupported, summary: summary?.text))]
        var hasPDF = false

        let ordered = Array(history)
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
                let replaysReasoning = msg.modelID.map { Self.sameModel($0, modelID) } == true && !msg.reasoningDetails.isEmpty
                if !calls.isEmpty, !replaysReasoning, Self.needsThoughtSignatures(modelID) {
                    // Gemini rejects a tool call without its own thought signature (one made by another
                    // model, or whose signature can't be sent), so describe the calls in text instead.
                    var results: [String: String] = [:]
                    i += 1
                    while i < ordered.count, ordered[i].role == .tool {
                        if let id = ordered[i].toolCallID { results[id] = toolContent(ordered[i]) }
                        i += 1
                    }
                    messages.append(.assistant(Self.describe(text: msg.text, calls: calls, results: results), toolCalls: nil))
                    continue
                }
                var cm = ChatMessage.assistant(msg.text.isEmpty ? nil : msg.text, toolCalls: calls.isEmpty ? nil : calls)
                if replaysReasoning { cm.reasoningDetails = msg.reasoningDetails }
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
        // Asking for a tier the model doesn't offer is harmless: OpenRouter routes it as Standard.
        request.serviceTier = settings.serviceTier(conversation.serviceTier).requestValue
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
        if settings.longChatMode == LongChatMode.trim.rawValue {
            request.transforms = ["middle-out"]
        }
        request.sessionID = conversation.id.uuidString
        return request
    }

    /// A request asking the model to summarize the chat, built from the same history as a normal turn.
    func buildSummaryRequest(excluding excludedID: UUID? = nil) -> ChatRequest {
        var request = build(excluding: excludedID)
        request.messages.append(.user(ContextBudget.summaryInstruction))
        // Tool definitions stay (some providers require them when the history has tool calls), but none may run.
        if request.tools != nil { request.toolChoice = "none" }
        request.maxToolCalls = nil
        request.plugins = request.plugins?.filter { $0["id"]?.stringValue != "web" }
        if request.plugins?.isEmpty == true { request.plugins = nil }
        request.reasoning = nil
        // If the chat already overflows, let OpenRouter trim the middle rather than fail.
        request.transforms = ["middle-out"]
        return request
    }

    private func closestEffort(_ wanted: String, in available: [String]) -> String? {
        let scale = ["minimal", "low", "medium", "high", "xhigh", "max"]
        guard let w = scale.firstIndex(of: wanted) else { return available.first }
        return available.min { a, b in
            abs((scale.firstIndex(of: a) ?? 2) - w) < abs((scale.firstIndex(of: b) ?? 2) - w)
        }
    }

    /// Models that require each tool call in the history to carry their own thought signature.
    nonisolated static func needsThoughtSignatures(_ modelID: String) -> Bool {
        modelID.hasPrefix("google/gemini")
    }

    /// The same model, allowing for the dated id a response may report ("…-20261013") or a variant suffix.
    nonisolated static func sameModel(_ a: String, _ b: String) -> Bool {
        func base(_ id: String) -> String { String(id.split(separator: ":").first ?? Substring(id)) }
        let x = base(a), y = base(b)
        return x == y || x.hasPrefix(y + "-") || y.hasPrefix(x + "-")
    }

    /// An assistant turn's tool calls and their results, written out as plain text.
    nonisolated static func describe(text: String, calls: [ToolCall], results: [String: String]) -> String {
        var parts = text.isEmpty ? [] : [text]
        for call in calls {
            parts.append("[Called \(call.name) with \(call.function.arguments)]\n\(results[call.id] ?? "No result (the tool did not run).")")
        }
        return parts.joined(separator: "\n\n")
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

    func systemPrompt(toolsSupported: Bool, summary: String? = nil) -> String {
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
        if let summary {
            lines.append("\nEarlier messages in this chat were removed to save space. Summary of them:\n<summary>\n\(summary)\n</summary>")
        }
        if includeTitleInstruction {
            lines.append("\nIMPORTANT: Start your reply with a concise 2–6 word title for this chat wrapped in <title></title> on the first line (for example <title>Paris weekend itinerary</title>), then continue with your normal answer. Do not mention the title otherwise.")
        }
        return lines.joined(separator: "\n")
    }
}
