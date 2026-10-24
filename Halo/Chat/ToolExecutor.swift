import Foundation
import SwiftData
import UIKit

/// Executes model tool calls and stores their results as `tool` messages.
@MainActor
final class ToolExecutor {
    unowned let engine: ChatEngine
    private var resumingJobs = Set<String>()

    init(engine: ChatEngine) { self.engine = engine }

    private var client: OpenRouterClient { engine.client }
    private var settings: AppSettings { engine.settings }
    private var catalog: ModelCatalog { engine.catalog }

    /// Runs auto tools and creates approval cards for gated ones. Returns true if user input is needed.
    func execute(_ calls: [ToolCall], after assistant: Message, in conversation: Conversation) async -> Bool {
        var needsUser = false
        // Only this reply's results count: other branches may reuse the same call ids.
        let existing = Set(conversation.orderedMessages.filter { $0.sortIndex > assistant.sortIndex }.compactMap(\.toolCallID))
        for call in calls where !existing.contains(call.id) {
            let msg = Message(role: .tool)
            msg.toolCallID = call.id
            conversation.append(msg)
            msg.toolState = ToolState(name: call.name, arguments: call.function.arguments, status: .running)
            engine.context.insert(msg)
            engine.save()
            if Task.isCancelled {
                // The turn was stopped: don't start more tools, but record why they have no result.
                finish(msg, status: .failed, text: "This tool call was cancelled before it ran.", summary: "Cancelled")
                engine.save()
                continue
            }

            let args = call.argumentsJSON
            switch ToolName(rawValue: call.name) {
            case .generateImage:
                prepareApproval(msg, kind: .generateImage, args: args, conversation: conversation)
                needsUser = true
            case .generateVideo:
                prepareApproval(msg, kind: .generateVideo, args: args, conversation: conversation)
                needsUser = true
            case .generateSpeech:
                await runSpeech(msg, args: args, conversation: conversation)
            case .runCode:
                await runCode(msg, args: args, conversation: conversation)
            case .shell:
                let command = args["command"]?.stringValue ?? ""
                // Only network requests need a look first; everything else just reshapes text.
                if settings.askBeforeShell && MiniShell.reachesNetwork(command) {
                    prepareShellApproval(msg, command: command)
                    needsUser = true
                } else {
                    await runShell(msg, command: command)
                }
            case .createArtifact:
                createArtifact(msg, args: args, conversation: conversation)
            case .updateArtifact:
                updateArtifact(msg, args: args, conversation: conversation)
            case .readWebPage:
                apply(await DeviceTools.readWebPage(args), to: msg)
            case .deviceInfo:
                apply(DeviceTools.deviceInfo(), to: msg)
            case .openInApp:
                apply(DeviceTools.openInApp(args), to: msg)
            case .getLocation:
                apply(await DeviceTools.getLocation(args), to: msg)
            case .getWeather:
                apply(await DeviceTools.getWeather(args), to: msg)
            case .searchPlaces:
                apply(await DeviceTools.searchPlaces(args), to: msg)
            case .getDirections:
                apply(await DeviceTools.getDirections(args), to: msg)
            case .listEvents:
                apply(await DeviceTools.listEvents(args), to: msg)
            case .listReminders:
                apply(await DeviceTools.listReminders(), to: msg)
            case .createEvent, .createReminder:
                prepareApproval(msg, kind: ToolName(rawValue: call.name)!, args: args, conversation: conversation)
                needsUser = true
            case .none:
                finish(msg, status: .failed, text: "Unknown tool \(call.name).", summary: "Unknown tool")
            }
            engine.save()
        }
        return needsUser
    }

    /// Marks a tool the user approved but then stopped before it could start.
    func markStopped(_ msg: Message) {
        guard msg.toolState?.status == .running else { return }
        finish(msg, status: .failed, text: "The user stopped the chat before this ran.", summary: "Stopped")
    }

    /// True once the message (or its chat) has been deleted.
    private func isGone(_ msg: Message) -> Bool {
        msg.isDeleted || msg.modelContext == nil
    }

    /// Stores a device or web tool's result and card.
    private func apply(_ outcome: ToolOutcome, to msg: Message) {
        guard !isGone(msg) else { return }
        if var state = msg.toolState {
            state.card = outcome.card
            msg.toolState = state
        }
        finish(msg, status: outcome.ok ? .done : .failed, text: outcome.text, summary: outcome.summary,
               output: outcome.ok ? nil : outcome.text)
        if outcome.ok { Haptics.selection() }
    }

    private func finish(_ msg: Message, status: ToolStatus, text: String, summary: String?, output: String? = nil) {
        guard var state = msg.toolState else { return }
        state.status = status
        state.summary = summary
        if let output { state.output = output }
        msg.toolState = state
        msg.text = text
    }

    // MARK: - Approval-gated tools

    private func prepareApproval(_ msg: Message, kind: ToolName, args: JSONValue, conversation: Conversation) {
        guard var state = msg.toolState else { return }
        if kind == .createEvent || kind == .createReminder {
            state.approval = DeviceTools.eventParams(args, reminder: kind == .createReminder)
        } else if kind == .generateImage {
            let model = settings.imageModelID
            var refs = args["reference_image_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            refs = refs.filter { findImage(ref: $0, in: conversation) != nil }
            let info = catalog.imageModel(model)
            state.approval = ApprovalParams(prompt: args["prompt"]?.stringValue ?? "",
                                            model: model,
                                            aspectRatio: args["aspect_ratio"]?.stringValue ?? "1:1",
                                            resolution: nil,
                                            count: min(4, max(1, args["count"]?.intValue ?? 1)),
                                            quality: info.flatMap { ImageQuality.defaultValue(for: $0) },
                                            background: args["transparent_background"]?.boolValue == true && info?.supportsTransparency == true ? "transparent" : nil,
                                            stream: info?.streams == true ? true : nil,
                                            referenceIDs: refs.isEmpty ? nil : refs)
        } else {
            let model = settings.videoModelID
            let info = catalog.videoModel(model)
            var duration = args["duration_seconds"]?.intValue ?? 6
            if let durations = info?.supportedDurations, !durations.isEmpty, !durations.contains(duration) {
                duration = durations.min(by: { abs($0 - duration) < abs($1 - duration) }) ?? durations[0]
            }
            let frame = args["first_frame_image_id"]?.stringValue
            state.approval = ApprovalParams(prompt: args["prompt"]?.stringValue ?? "",
                                            model: model,
                                            aspectRatio: args["aspect_ratio"]?.stringValue ?? "16:9",
                                            resolution: info?.supportedResolutions?.contains("720p") == true ? "720p" : info?.supportedResolutions?.first,
                                            duration: duration,
                                            generateAudio: info?.generateAudio == true ? true : nil,
                                            referenceIDs: frame.map { [$0] })
        }
        state.status = .awaitingApproval
        msg.toolState = state
        msg.text = "Waiting for the user's approval."
    }

    /// Called after the user approves (possibly with edited parameters).
    func runApproved(_ msg: Message, params: ApprovalParams, in conversation: Conversation) async {
        guard let name = msg.toolState.flatMap({ ToolName(rawValue: $0.name) }) else { return }
        switch name {
        case .generateImage: await runImage(msg, params: params, conversation: conversation)
        case .generateVideo: await runVideo(msg, params: params, conversation: conversation)
        case .shell: await runShell(msg, command: params.prompt)
        case .createEvent: apply(await DeviceTools.saveEvent(params), to: msg)
        case .createReminder: apply(await DeviceTools.saveReminder(params), to: msg)
        default: break
        }
        engine.save()
    }

    func findImage(ref: String, in conversation: Conversation) -> MediaItem? {
        let needle = ref.lowercased().replacingOccurrences(of: "img_", with: "")
        for m in conversation.orderedMessages.reversed() {
            if let item = m.media.first(where: { $0.kind == .image && ($0.refID == ref.lowercased() || $0.id.lowercased().hasPrefix(needle)) }) {
                return item
            }
        }
        return nil
    }

    private func runImage(_ msg: Message, params: ApprovalParams, conversation: Conversation) async {
        let refs: [JSONValue] = (params.referenceIDs ?? []).compactMap { findImage(ref: $0, in: conversation) }
            .compactMap { MediaStore.dataURL(for: $0) }
            .map { ["type": "image_url", "image_url": ["url": .string($0)]] }
        let info = catalog.imageModel(params.model)
        var aspect = params.aspectRatio
        if let ratios = info?.aspectRatios, !ratios.isEmpty, let a = aspect, !ratios.contains(a) { aspect = ratios.contains("1:1") ? "1:1" : ratios.first }
        let maxN = Int(info?.supportedParameters?["n"]?.max ?? 1)
        // A stream carries one image, so streamed requests ask for one each and repeat below.
        let streaming = params.stream != false && info?.streams == true
        let request = ImageGenerationRequest(model: params.model, prompt: params.prompt, aspectRatio: aspect,
                                             resolution: params.resolution, n: maxN > 1 && !streaming ? min(params.count ?? 1, maxN) : nil,
                                             inputReferences: refs.isEmpty ? nil : refs,
                                             quality: info?.qualities.contains(params.quality ?? "") == true ? params.quality : nil,
                                             background: info?.supportsTransparency == true ? params.background : nil)
        let messageID = msg.id
        defer { engine.imagePreviews[messageID] = nil }
        func generate() async throws -> ImageGenerationResponse {
            guard streaming else { return try await client.generateImage(request) }
            return try await client.streamImage(request) { [engine] data in
                if let image = UIImage(data: data) { engine.imagePreviews[messageID] = image }
            }
        }
        do {
            var items: [MediaItem] = []
            var totalCost = 0.0
            let wanted = params.count ?? 1
            var response = try await generate()
            totalCost += response.usage?.cost ?? 0
            items += try saveImages(response, params: params)
            // Models that only make one image per call: repeat to honour the requested count.
            var extra = wanted - items.count
            while extra > 0, !Task.isCancelled {
                engine.imagePreviews[messageID] = nil
                response = try await generate()
                totalCost += response.usage?.cost ?? 0
                items += try saveImages(response, params: params)
                extra -= 1
            }
            msg.media = items
            catalog.recordImageCost(params.model, total: totalCost, count: items.count)
            engine.record(cost: totalCost, kind: .image, model: params.model, conversation: conversation, message: msg)
            let ids = items.map(\.refID).joined(separator: ", ")
            finish(msg, status: .done,
                   text: "Generated \(items.count) image(s) with \(params.model) (ids: \(ids)). They are displayed to the user. Prompt used: \(params.prompt)",
                   summary: "\(items.count) image\(items.count == 1 ? "" : "s") · \(Money.format(totalCost))")
            Haptics.success()
        } catch {
            let text = Task.isCancelled ? "Image generation was interrupted." : "Image generation failed: \(error.localizedDescription)"
            finish(msg, status: .failed, text: text, summary: "Failed", output: error.localizedDescription)
        }
    }

    private func saveImages(_ response: ImageGenerationResponse, params: ApprovalParams) throws -> [MediaItem] {
        var items: [MediaItem] = []
        for d in response.data {
            if let b64 = d.b64JSON, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                let mime = d.mediaType ?? "image/png"
                items.append(try MediaStore.save(data, kind: .image, mimeType: mime, ext: MediaStore.ext(forMime: mime), prompt: params.prompt, model: params.model))
            }
        }
        return items
    }

    private func runVideo(_ msg: Message, params: ApprovalParams, conversation: Conversation) async {
        var frames: [JSONValue]? = nil
        if let ref = params.referenceIDs?.first, let img = findImage(ref: ref, in: conversation), let url = MediaStore.dataURL(for: img) {
            frames = [["type": "image_url", "image_url": ["url": .string(url)], "frame_type": "first_frame"]]
        }
        let request = VideoGenerationRequest(model: params.model, prompt: params.prompt, duration: params.duration,
                                             resolution: params.resolution, aspectRatio: params.aspectRatio,
                                             generateAudio: params.generateAudio, frameImages: frames)
        do {
            let job = try await client.submitVideo(request)
            if var state = msg.toolState {
                state.videoJobID = job.id
                state.progressNote = "Queued"
                msg.toolState = state
            }
            engine.save()
            await pollVideo(msg, jobID: job.id, model: params.model, conversation: conversation)
        } catch {
            finish(msg, status: .failed, text: "Video generation failed: \(error.localizedDescription)", summary: "Failed", output: error.localizedDescription)
        }
    }

    private func pollVideo(_ msg: Message, jobID: String, model: String, conversation: Conversation) async {
        let started = Date()
        var delay: UInt64 = 5_000_000_000
        while !Task.isCancelled, !isGone(msg) {
            do {
                let job = try await client.pollVideo(jobID: jobID)
                if isGone(msg) { return }
                if var state = msg.toolState {
                    let elapsed = Int(Date().timeIntervalSince(started))
                    state.progressNote = job.status == "in_progress" ? "Rendering… \(elapsed)s" : job.status.capitalized
                    msg.toolState = state
                }
                if job.isTerminal {
                    if job.status == "completed" {
                        let data: Data
                        if let signed = job.urls?.first, let url = URL(string: signed) {
                            data = try await client.download(url: url)
                        } else {
                            data = try await client.downloadVideo(jobID: jobID)
                        }
                        if isGone(msg) { return }
                        let item = try MediaStore.save(data, kind: .video, mimeType: "video/mp4", ext: "mp4", prompt: msg.toolState?.approval?.prompt, model: model)
                        msg.media = [item]
                        let cost = job.usage?.cost ?? 0
                        engine.record(cost: cost, kind: .video, model: model, conversation: conversation, message: msg)
                        finish(msg, status: .done, text: "The video was generated with \(model) and is displayed to the user.",
                               summary: "Video · \(Money.format(cost))")
                        Haptics.success()
                    } else {
                        finish(msg, status: .failed, text: "Video generation \(job.status): \(job.error ?? "unknown error")",
                               summary: job.status.capitalized, output: job.error)
                    }
                    engine.save()
                    return
                }
            } catch {
                if Task.isCancelled || isGone(msg) { return }
                // Transient poll errors: keep trying a few times.
                if Date().timeIntervalSince(started) > 60 * 20 {
                    finish(msg, status: .failed, text: "Video polling failed: \(error.localizedDescription)", summary: "Failed")
                    return
                }
            }
            try? await Task.sleep(nanoseconds: delay)
            if Date().timeIntervalSince(started) > 30 { delay = 10_000_000_000 }
        }
    }

    /// Resumes polling for videos that were rendering when the app was suspended.
    func resumeVideoJobs() {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.roleRaw == "tool" && $0.toolStateData != nil },
                                                  sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let messages = try? engine.context.fetch(descriptor) else { return }
        for msg in messages.prefix(50) {
            guard let state = msg.toolState, state.status == .running, let jobID = state.videoJobID,
                  let conversation = msg.conversation, !resumingJobs.contains(jobID), !engine.isBusy(conversation) else { continue }
            resumingJobs.insert(jobID)
            let model = state.approval?.model ?? settings.videoModelID
            Task {
                await pollVideo(msg, jobID: jobID, model: model, conversation: conversation)
                resumingJobs.remove(jobID)
                guard !isGone(msg), !conversation.isDeleted, conversation.modelContext != nil else { return }
                engine.save()
                if engine.allToolCallsResolved(conversation) { engine.resumePendingToolCalls() }
            }
        }
        // Tools interrupted mid-run (not video) can't resume: mark them failed so the chat can continue.
        for msg in messages.prefix(50) {
            guard let state = msg.toolState, state.status == .running, state.videoJobID == nil,
                  let conversation = msg.conversation, !engine.isBusy(conversation) else { continue }
            finish(msg, status: .failed, text: "The tool was interrupted before finishing.", summary: "Interrupted")
        }
    }

    // MARK: - Auto tools

    private func runSpeech(_ msg: Message, args: JSONValue, conversation: Conversation) async {
        let text = args["text"]?.stringValue ?? ""
        guard !text.isEmpty else {
            finish(msg, status: .failed, text: "No text was provided.", summary: "Failed")
            return
        }
        let model = settings.speechModelID
        let voice = speechVoice(args["voice"]?.stringValue, model: model)
        do {
            let result = try await synthesize(text, voice: voice, instructions: args["style_instructions"]?.stringValue, model: model)
            msg.media = [result.item]
            let voiceLabel = voice.isEmpty ? "the model's own" : voice
            finish(msg, status: .done, text: "Speech generated (voice: \(voiceLabel)) and shown to the user as an audio player.",
                   summary: voice.isEmpty ? "Voice" : "Voice · \(voice)")
            if let generationID = result.generationID { recordSpeechCost(generationID: generationID, model: model, messageID: msg.id) }
        } catch {
            finish(msg, status: .failed, text: "Speech generation failed: \(error.localizedDescription)", summary: "Failed", output: error.localizedDescription)
        }
    }

    /// The voice to send: the one asked for when the model has it (in its own spelling), else the
    /// default from Settings. A model with no named voices (Fish Audio, Seed Audio) gets none:
    /// another model's voice name, like Gemini's "Kore", means nothing to it.
    func speechVoice(_ requested: String?, model: String) -> String {
        let info = catalog.speechModel(model)
        let voices = info?.supportedVoices ?? []
        if info != nil && voices.isEmpty { return "" }
        let voice = requested ?? ""
        if let exact = voices.first(where: { $0.caseInsensitiveCompare(voice) == .orderedSame }) { return exact }
        if voice.isEmpty || !voices.isEmpty { return settings.speechVoice }
        return voice
    }

    /// Speaks `text` with the voice model and saves the audio. A provider that takes only one
    /// format (Gemini: raw PCM) says so in its error; the format is remembered and asked for again.
    func synthesize(_ text: String, voice: String, instructions: String?, model: String) async throws -> (item: MediaItem, generationID: String?) {
        var request = SpeechRequest(model: model, input: text, voice: voice.isEmpty ? nil : voice,
                                    instructions: instructions, responseFormat: Self.speechFormat(for: model))
        let result: (data: Data, generationID: String?, contentType: String?)
        do {
            result = try await client.speech(request)
        } catch {
            guard let format = SpeechRequest.requiredFormat(in: error.localizedDescription),
                  format != request.responseFormat else { throw error }
            Self.rememberSpeechFormat(format, for: model)
            request.responseFormat = format
            result = try await client.speech(request)
        }
        let item: MediaItem
        switch request.responseFormat {
        case "pcm":
            let wav = WAV.wrap(pcm: result.data, sampleRate: WAV.sampleRate(contentType: result.contentType))
            item = try MediaStore.save(wav, kind: .audio, mimeType: "audio/wav", ext: "wav", prompt: text, model: model)
        case "wav":
            item = try MediaStore.save(result.data, kind: .audio, mimeType: "audio/wav", ext: "wav", prompt: text, model: model)
        default:
            item = try MediaStore.save(result.data, kind: .audio, mimeType: "audio/mpeg", ext: "mp3", prompt: text, model: model)
        }
        return (item, result.generationID)
    }

    /// Speech is billed after the fact: look the cost up once OpenRouter has it and add it to the message.
    func recordSpeechCost(generationID: String, model: String, messageID: UUID) {
        Task { [weak self] in
            guard let self, let stats = try? await self.client.generation(id: generationID), let cost = stats.totalCost else { return }
            guard let m = self.engine.message(id: messageID) else { return }
            self.engine.record(cost: cost, kind: .speech, model: model, conversation: m.conversation, message: m)
            self.engine.save()
        }
    }

    /// The format to ask a voice model for: one it has refused others for before, else mp3. Gemini's
    /// voices only send raw PCM, so they start there and skip a failed first request.
    static func speechFormat(for model: String) -> String {
        if let known = UserDefaults.standard.dictionary(forKey: "speechFormats")?[model] as? String { return known }
        return model.hasPrefix("google/gemini") ? "pcm" : "mp3"
    }

    static func rememberSpeechFormat(_ format: String, for model: String) {
        var known = UserDefaults.standard.dictionary(forKey: "speechFormats") ?? [:]
        known[model] = format
        UserDefaults.standard.set(known, forKey: "speechFormats")
    }

    private func runCode(_ msg: Message, args: JSONValue, conversation: Conversation) async {
        let language = args["language"]?.stringValue ?? "python"
        let code = args["code"]?.stringValue ?? ""
        let result = await CodeRunner.run(language: language, code: code)
        var items: [MediaItem] = []
        for img in result.images {
            if let item = try? MediaStore.save(img, kind: .image, mimeType: "image/png", ext: "png", prompt: "Figure", model: "python") {
                items.append(item)
            }
        }
        msg.media = items
        let ok = result.error == nil
        finish(msg, status: ok ? .done : .failed, text: result.modelSummary,
               summary: String(format: "%@ · %.1fs", ok ? "Ran" : "Error", result.duration), output: result.consoleText)
    }

    /// The command waits in the approval popup above the composer.
    private func prepareShellApproval(_ msg: Message, command: String) {
        guard var state = msg.toolState else { return }
        state.approval = ApprovalParams(prompt: command, model: "")
        state.status = .awaitingApproval
        msg.toolState = state
        msg.text = "Waiting for the user's approval."
    }

    private func runShell(_ msg: Message, command: String) async {
        let result = await MiniShell.run(command)
        let ok = result.exitCode == 0
        let label = result.httpStatus.map { "HTTP \($0)" } ?? (ok ? "Ran" : "Exit \(result.exitCode)")
        finish(msg, status: ok ? .done : .failed, text: result.modelSummary,
               summary: String(format: "%@ · %.1fs", label, result.duration), output: result.consoleText)
    }

    func createArtifact(_ msg: Message, args: JSONValue, conversation: Conversation) {
        let kind = ArtifactKind(rawValue: args["type"]?.stringValue ?? "markdown") ?? .markdown
        let title = args["title"]?.stringValue ?? "Untitled"
        let content = args["content"]?.stringValue ?? ""
        let artifact = Artifact(title: title, kind: kind, language: args["language"]?.stringValue, content: content, conversationID: conversation.id)
        engine.context.insert(artifact)
        if var state = msg.toolState {
            state.artifactID = artifact.id
            state.artifactVersion = 1
            msg.toolState = state
        }
        finish(msg, status: .done, text: "Created artifact \(artifact.id.uuidString) (\(kind.rawValue), version 1). It is displayed to the user in a canvas.",
               summary: title)
        Haptics.success()
    }

    func updateArtifact(_ msg: Message, args: JSONValue, conversation: Conversation) {
        let idString = args["artifact_id"]?.stringValue ?? ""
        let all = engine.artifacts(in: conversation)
        // A wrong id falls back to the only artifact, never a guess among several.
        let artifact = UUID(uuidString: idString).flatMap { engine.artifact(id: $0) }
            ?? all.first(where: { $0.title.caseInsensitiveCompare(idString) == .orderedSame })
            ?? (all.count == 1 ? all.first : nil)
        guard let artifact else {
            let known = all.map { "\($0.id.uuidString) (\"\($0.title)\")" }.joined(separator: ", ")
            finish(msg, status: .failed, text: all.isEmpty
                   ? "No artifact found with id \(idString). Use create_artifact instead."
                   : "No artifact found with id \(idString). Artifacts in this chat: \(known).", summary: "Not found")
            return
        }
        var content = artifact.latestContent
        if let full = args["content"]?.stringValue, !full.isEmpty {
            content = full
        } else if let edits = args["edits"]?.arrayValue, !edits.isEmpty {
            var failures: [String] = []
            for edit in edits {
                guard let find = edit["find"]?.stringValue, let replace = edit["replace"]?.stringValue else { continue }
                let matches = find.isEmpty ? 0 : content.components(separatedBy: find).count - 1
                if matches == 1, let range = content.range(of: find) {
                    content.replaceSubrange(range, with: replace)
                } else {
                    // Several matches would mean guessing which one was meant.
                    failures.append("\(String(find.prefix(80))) (\(matches == 0 ? "no match" : "\(matches) matches; add surrounding text"))")
                }
            }
            if !failures.isEmpty && content == artifact.latestContent {
                // There's no tool to read an artifact, so hand back its text to retry against.
                finish(msg, status: .failed, text: "None of the edits applied: \(failures.joined(separator: " | ")). Current text of version \(artifact.latest?.number ?? 1):\n\(artifact.latestContent.prefix(30_000))\nRetry with finds that match exactly once, or send the full content.", summary: "Edit failed")
                return
            }
            if !failures.isEmpty {
                msg.text = "Some edits didn't match: \(failures.joined(separator: " | "))"
            }
        } else {
            finish(msg, status: .failed, text: "Provide either content or edits.", summary: "No changes")
            return
        }
        let version = artifact.addVersion(content: content, summary: args["summary"]?.stringValue)
        if var state = msg.toolState {
            state.artifactID = artifact.id
            state.artifactVersion = version
            msg.toolState = state
        }
        let note = msg.text.hasPrefix("Some edits") ? " " + msg.text : ""
        finish(msg, status: .done, text: "Updated artifact \(artifact.id.uuidString) to version \(version).\(note)",
               summary: "\(artifact.title) · v\(version)")
        Haptics.success()
    }
}
