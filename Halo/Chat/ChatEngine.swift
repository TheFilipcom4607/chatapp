import Foundation
import Observation
import SwiftData
import UIKit

/// Orchestrates chat turns: streaming, tool loops, approvals, cost tracking and background handoff.
@MainActor
@Observable
final class ChatEngine {
    private(set) var live: [UUID: LiveTurn] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var currentRequests: [UUID: ChatRequest] = [:]
    /// Approvals the user gave while the conversation was still busy; they run when it frees up.
    private var queuedApprovals: [UUID: [(messageID: UUID, params: ApprovalParams)]] = [:]
    /// Conversations whose tool batch became fully resolved (e.g. a decline) while busy.
    private var continueWhenIdle = Set<UUID>()
    /// Conversations the user stopped; they are not resumed automatically until the user acts again.
    private var userStopped = Set<UUID>()
    private(set) var isAppActive = true
    var openConversationID: UUID?

    let client: OpenRouterClient
    let catalog: ModelCatalog
    let settings: AppSettings
    let account: AccountStore
    let context: ModelContext
    @ObservationIgnored lazy var tools = ToolExecutor(engine: self)

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var handoffTimer: Task<Void, Never>?
    private let maxRounds = 10

    init(client: OpenRouterClient, catalog: ModelCatalog, settings: AppSettings, account: AccountStore, context: ModelContext) {
        self.client = client
        self.catalog = catalog
        self.settings = settings
        self.account = account
        self.context = context
    }

    func isBusy(_ conversation: Conversation) -> Bool { tasks[conversation.id] != nil }
    func liveTurn(for conversation: Conversation) -> LiveTurn? { live[conversation.id] }

    // MARK: - Lookups

    func persona(for conversation: Conversation) -> Persona? {
        guard let pid = conversation.personaID else { return nil }
        let descriptor = FetchDescriptor<Persona>(predicate: #Predicate { $0.id == pid })
        return try? context.fetch(descriptor).first
    }

    func artifacts(in conversation: Conversation) -> [Artifact] {
        let cid: UUID? = conversation.id
        let descriptor = FetchDescriptor<Artifact>(predicate: #Predicate { $0.conversationID == cid }, sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func artifact(id: UUID) -> Artifact? {
        let descriptor = FetchDescriptor<Artifact>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func conversation(id: UUID) -> Conversation? {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func message(id: UUID) -> Message? {
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func save() {
        do { try context.save() } catch { print("Save failed: \(error)") }
    }

    // MARK: - Public actions

    func send(text: String, media: [MediaItem], in conversation: Conversation) {
        guard !isBusy(conversation) else { return }
        userStopped.remove(conversation.id)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !media.isEmpty else { return }
        let message = Message(role: .user, text: trimmed)
        message.media = media
        conversation.append(message)
        context.insert(message)
        conversation.updatedAt = .now
        conversation.isArchived = false
        if !conversation.titleIsSet, conversation.title == "New chat" {
            conversation.title = TitleExtractor.fallback(from: trimmed.isEmpty ? (media.first?.originalName ?? "Attachment") : trimmed)
        }
        save()
        Haptics.send()
        if settings.notifyWhenDone { NotificationService.requestAuthorization() }
        if settings.longChatMode == LongChatMode.summarize.rawValue,
           let usage = contextUsage(for: conversation), usage.fraction >= ContextBudget.autoSummarizeAt,
           canSummarize(conversation, before: message) {
            summarize(conversation, before: message, thenReply: true)
        } else {
            startTurn(conversation)
        }
    }

    func stop(_ conversation: Conversation) {
        userStopped.insert(conversation.id)
        tasks[conversation.id]?.cancel()
        Haptics.tap()
    }

    /// Cancels the conversation's running turn and waits until it has fully wound down
    /// (so the conversation can be deleted without the turn touching deleted models).
    func stopAndWait(_ conversation: Conversation) async {
        let id = conversation.id
        userStopped.insert(id)
        if let task = tasks[id] {
            task.cancel()
            await task.value
        }
        queuedApprovals[id] = nil
        continueWhenIdle.remove(id)
    }

    /// Re-runs the reply to the user message preceding `message`, optionally with another model.
    /// The old reply stays as another branch unless `replacing` is set or it only holds a failure.
    func regenerate(_ message: Message, in conversation: Conversation, modelID: String? = nil, replacing: Bool = false) {
        guard !isBusy(conversation) else { return }
        conversation.threadIfNeeded()
        let ordered = conversation.orderedMessages
        guard let idx = ordered.firstIndex(where: { $0.id == message.id }) else { return }
        guard let userIdx = ordered[..<idx].lastIndex(where: { $0.role == .user }) else { return }
        userStopped.remove(conversation.id)
        let reply = ordered[(userIdx + 1)...]
        let onlyFailures = reply.allSatisfy { $0.role == .assistant && ($0.status == .failed || ($0.text.isEmpty && $0.toolCalls.isEmpty)) }
        if let first = reply.first, replacing || onlyFailures {
            conversation.deleteBranch(from: first, in: context)
        }
        conversation.activeLeafID = ordered[userIdx].id
        if let modelID { conversation.modelID = modelID }
        save()
        Haptics.tap()
        startTurn(conversation)
    }

    /// Retries after a failure at the end of the conversation.
    func retry(_ conversation: Conversation) {
        guard let last = conversation.orderedMessages.last else { return }
        userStopped.remove(conversation.id)
        if last.role == .user { startTurn(conversation) } else { regenerate(last, in: conversation, replacing: true) }
    }

    /// Sends an edited copy of a user message on a new branch. The original and its replies stay one tap away.
    func edit(_ message: Message, to text: String, in conversation: Conversation) {
        guard !isBusy(conversation), message.role == .user else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != message.text, !trimmed.isEmpty || !message.media.isEmpty else { return }
        userStopped.remove(conversation.id)
        conversation.threadIfNeeded()
        let edited = Message(role: .user, text: trimmed)
        edited.media = message.media
        conversation.attach(edited, under: message.parentID)
        context.insert(edited)
        conversation.updatedAt = .now
        conversation.isArchived = false
        save()
        Haptics.send()
        startTurn(conversation)
    }

    /// Switches to the branch that goes through `message` (an edit or an earlier reply).
    func showBranch(through message: Message, in conversation: Conversation) {
        guard !isBusy(conversation) else { return }
        conversation.showBranch(through: message)
        save()
        Haptics.selection()
    }

    /// Called from an approval card.
    func resolveApproval(_ toolMessage: Message, approve: Bool, params: ApprovalParams, in conversation: Conversation) {
        guard var state = toolMessage.toolState, state.status == .awaitingApproval else { return }
        userStopped.remove(conversation.id)
        if !approve {
            let isShell = state.name == ToolName.shell.rawValue
            state.status = .declined
            state.summary = isShell ? "Denied" : "Skipped"
            toolMessage.toolState = state
            toolMessage.text = isShell
                ? "The user denied this command, so it did not run. Don't retry it; ask what they'd like instead."
                : "The user declined this request. Ask if they want something different."
            save()
            Haptics.tap()
            if isBusy(conversation) { continueWhenIdle.insert(conversation.id) } else { continueIfReady(conversation) }
            return
        }
        state.approval = params
        state.status = .running
        toolMessage.toolState = state
        save()
        Haptics.send()
        if isBusy(conversation) {
            // Another tool (or approval) is still running in this chat: run this one right after it.
            queuedApprovals[conversation.id, default: []].append((toolMessage.id, params))
            return
        }
        launchApproved([(toolMessage.id, params)], in: conversation)
    }

    private func launchApproved(_ items: [(messageID: UUID, params: ApprovalParams)], in conversation: Conversation) {
        launch(conversation) { [weak self] live in
            guard let self else { return }
            live.phase = .runningTools
            var pending = items
            while !pending.isEmpty {
                let item = pending.removeFirst()
                if let msg = self.message(id: item.messageID) {
                    if Task.isCancelled { self.tools.markStopped(msg) }
                    else { await self.tools.runApproved(msg, params: item.params, in: conversation) }
                }
                pending += self.queuedApprovals.removeValue(forKey: conversation.id) ?? []
            }
            if self.allToolCallsResolved(conversation) {
                await self.runLoop(conversation, live: live)
            }
        }
    }

    // MARK: - Long chats

    func contextUsage(for conversation: Conversation) -> ContextUsage? {
        ContextBudget.usage(path: conversation.orderedMessages, limit: catalog.model(conversation.modelID)?.contextLength)
    }

    /// Whether there's a finished exchange to summarize before `anchor` (or the end of the branch).
    func canSummarize(_ conversation: Conversation, before anchor: Message? = nil) -> Bool {
        var path = conversation.orderedMessages
        if let anchor {
            guard let i = path.firstIndex(where: { $0.id == anchor.id }) else { return false }
            path = Array(path[..<i])
        }
        // Not in the middle of a tool round: its results would end up on the wrong side of the summary.
        if let last = path.last, last.role == .tool || !last.toolCalls.isEmpty { return false }
        return ContextBudget.liveHistory(path).messages.filter { $0.role == .user || $0.role == .assistant }.count >= 2
    }

    /// Replaces the messages before `anchor` (or the whole branch) with a summary the model writes,
    /// so the chat fits the context window again. With `thenReply`, the turn continues afterwards.
    func summarize(_ conversation: Conversation, before anchor: Message? = nil, thenReply: Bool = false) {
        guard !isBusy(conversation), canSummarize(conversation, before: anchor) else { return }
        userStopped.remove(conversation.id)
        launch(conversation) { [weak self] live in
            guard let self else { return }
            let ok = await self.writeSummary(conversation, before: anchor, live: live, thenReply: thenReply)
            if ok, thenReply, !Task.isCancelled { await self.runLoop(conversation, live: live) }
        }
    }

    /// After a reply failed because the chat no longer fits: summarize, then send the last message again.
    /// Returns false when there's nothing before that message to summarize.
    @discardableResult
    func summarizeAndRetry(_ conversation: Conversation) -> Bool {
        guard !isBusy(conversation) else { return true }
        conversation.threadIfNeeded()
        let path = conversation.orderedMessages
        guard let userIdx = path.lastIndex(where: { $0.role == .user }) else { return false }
        let user = path[userIdx]
        guard canSummarize(conversation, before: user) else { return false }
        if userIdx + 1 < path.count { conversation.deleteBranch(from: path[userIdx + 1], in: context) }
        conversation.activeLeafID = user.id
        save()
        summarize(conversation, before: user, thenReply: true)
        return true
    }

    /// Takes a summary out again; the full history is sent from then on.
    func removeSummary(_ summary: Message, in conversation: Conversation) {
        guard !isBusy(conversation), summary.role == .system else { return }
        conversation.unlink(summary, in: context)
        save()
        Haptics.tap()
    }

    private struct EmptySummary: LocalizedError {
        var errorDescription: String? { "The model returned an empty summary." }
    }

    private func writeSummary(_ conversation: Conversation, before anchor: Message?, live: LiveTurn, thenReply: Bool) async -> Bool {
        let builder = RequestBuilder(conversation: conversation, persona: persona(for: conversation), settings: settings,
                                     catalog: catalog, artifacts: artifacts(in: conversation), includeTitleInstruction: false)
        let request = builder.buildSummaryRequest(excluding: anchor?.id)
        let summary = Message(role: .system, modelID: conversation.modelID, status: .streaming)
        if let anchor { conversation.insert(summary, before: anchor) } else { conversation.append(summary) }
        context.insert(summary)
        save()
        live.beginMessage(summary.id)
        do {
            let outcome = try await stream(request, live: live, titleEnabled: false)
            await live.drain()
            let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw EmptySummary() }
            summary.text = text
            summary.generationID = outcome.generationID
            summary.provider = outcome.provider
            if let m = outcome.model { summary.modelID = m }
            summary.usage = outcome.usage
            summary.latency = outcome.latency
            summary.duration = outcome.duration
            summary.status = .complete
            if let usage = outcome.usage {
                record(cost: usage.cost ?? 0, kind: .chat, model: summary.modelID ?? conversation.modelID,
                       conversation: conversation, message: summary, usage: usage)
            }
            conversation.updatedAt = .now
            save()
            Haptics.success()
            return true
        } catch {
            await live.drain()
            conversation.unlink(summary, in: context)
            let stoppedByUser = userStopped.contains(conversation.id)
            if thenReply && !stoppedByUser {
                // Leave an error under the message so it can be retried.
                let failed = Message(role: .assistant, modelID: conversation.modelID, status: .failed)
                failed.errorText = live.handingOff
                    ? "Halo was closed while it summarized this chat. Try again."
                    : "Couldn't summarize the chat: \(error.localizedDescription)"
                conversation.append(failed)
                context.insert(failed)
                Haptics.error()
            } else if !stoppedByUser && !isCancellation(error) {
                Haptics.error()
                AppModel.shared.showToast("Couldn't summarize: \(error.localizedDescription)")
            }
            save()
            return false
        }
    }

    // MARK: - Turn management

    private func startTurn(_ conversation: Conversation) {
        launch(conversation) { [weak self] live in
            await self?.runLoop(conversation, live: live)
        }
    }

    private func launch(_ conversation: Conversation, _ body: @escaping (LiveTurn) async -> Void) {
        guard tasks[conversation.id] == nil else { return }
        let turn = LiveTurn(conversationID: conversation.id)
        turn.smooth = settings.smoothStreaming
        live[conversation.id] = turn
        tasks[conversation.id] = Task { [weak self] in
            await body(turn)
            guard let self else { return }
            turn.stop()
            self.tasks[conversation.id] = nil
            self.live[conversation.id] = nil
            self.currentRequests[conversation.id] = nil
            self.save()
            self.endBackgroundTaskIfIdle()
            self.turnDidEnd(conversation)
            Task { await self.account.refresh() }
        }
    }

    /// Picks up approvals or continuations that arrived while the turn was running.
    private func turnDidEnd(_ conversation: Conversation) {
        let id = conversation.id
        let queued = queuedApprovals.removeValue(forKey: id) ?? []
        if userStopped.contains(id) {
            continueWhenIdle.remove(id)
            for item in queued {
                if let msg = message(id: item.messageID) { tools.markStopped(msg) }
            }
            if !queued.isEmpty { save() }
            return
        }
        if !queued.isEmpty {
            continueWhenIdle.remove(id)
            launchApproved(queued, in: conversation)
        } else if continueWhenIdle.remove(id) != nil {
            continueIfReady(conversation)
        }
    }

    private func continueIfReady(_ conversation: Conversation) {
        guard allToolCallsResolved(conversation), !isBusy(conversation) else { return }
        startTurn(conversation)
    }

    /// True when the last assistant tool-call batch has no pending/running tools.
    func allToolCallsResolved(_ conversation: Conversation) -> Bool {
        let ordered = conversation.orderedMessages
        guard let lastAssistant = ordered.last(where: { $0.role == .assistant }), !lastAssistant.toolCalls.isEmpty else { return false }
        let toolMsgs = ordered.filter { $0.role == .tool && $0.sortIndex > lastAssistant.sortIndex }
        let ids = Set(toolMsgs.compactMap(\.toolCallID))
        guard lastAssistant.toolCalls.allSatisfy({ ids.contains($0.id) }) else { return false }
        return toolMsgs.allSatisfy { m in
            guard let s = m.toolState?.status else { return true }
            return s != .awaitingApproval && s != .running
        }
    }

    private func runLoop(_ conversation: Conversation, live: LiveTurn) async {
        continueWhenIdle.remove(conversation.id)
        var round = 0
        while round < maxRounds {
            round += 1
            if Task.isCancelled { break }
            let needsTitle = !conversation.titleIsSet
            let assistant = Message(role: .assistant, modelID: conversation.modelID, status: .streaming)
            conversation.append(assistant)
            context.insert(assistant)
            live.beginMessage(assistant.id)

            let builder = RequestBuilder(conversation: conversation, persona: persona(for: conversation), settings: settings,
                                         catalog: catalog, artifacts: artifacts(in: conversation), includeTitleInstruction: needsTitle)
            let request = builder.build(excluding: assistant.id)
            currentRequests[conversation.id] = request

            do {
                let outcome = try await stream(request, live: live, titleEnabled: needsTitle)
                await live.drain()
                live.toolDrafts = []
                apply(outcome, to: assistant, in: conversation)
                if needsTitle {
                    if let t = outcome.title, !t.isEmpty { conversation.title = t }
                    conversation.titleIsSet = true
                }
                save()
                if outcome.toolCalls.isEmpty {
                    if outcome.finishReason == "length" && outcome.text.isEmpty {
                        assistant.status = .failed
                        assistant.errorText = "The model used its whole budget thinking. Try a lower reasoning effort."
                    }
                    finishedReply(assistant, in: conversation)
                    break
                }
                live.phase = .runningTools
                let needsUser = await tools.execute(outcome.toolCalls, after: assistant, in: conversation)
                save()
                if needsUser {
                    live.phase = .waitingApproval
                    Haptics.warning()
                    if !isAppActive {
                        NotificationService.post(title: "Halo needs your OK", body: "Approve the generation request in \"\(conversation.title)\".", conversationID: conversation.id)
                    }
                    break
                }
            } catch {
                await live.drain()
                let partial = live.displayed
                if live.handingOff, let req = currentRequests[conversation.id] {
                    assistant.text = partial
                    assistant.reasoning = live.reasoning
                    assistant.status = .background
                    save()
                    handOff(request: req, assistant: assistant, conversation: conversation)
                    break
                }
                if isCancellation(error) {
                    assistant.text = partial
                    assistant.reasoning = live.reasoning
                    assistant.status = .cancelled
                    if partial.isEmpty && live.reasoning.isEmpty { conversation.deleteBranch(from: assistant, in: context) }
                } else {
                    assistant.text = partial
                    assistant.reasoning = live.reasoning
                    assistant.status = .failed
                    assistant.errorText = error.localizedDescription
                    Haptics.error()
                }
                if needsTitle { conversation.titleIsSet = !partial.isEmpty }
                save()
                break
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return Task.isCancelled
    }

    private func finishedReply(_ assistant: Message, in conversation: Conversation) {
        Haptics.success()
        conversation.updatedAt = .now
        if !isAppActive, settings.notifyWhenDone {
            NotificationService.post(title: conversation.title, body: assistant.text.isEmpty ? "Reply ready" : assistant.text, conversationID: conversation.id)
        }
    }

    // MARK: - Streaming

    struct Outcome {
        var text = ""
        var reasoning = ""
        var reasoningDetails: [JSONValue] = []
        var toolCalls: [ToolCall] = []
        var annotations: [JSONValue] = []
        var usage: Usage?
        var finishReason: String?
        var generationID: String?
        var provider: String?
        var serviceTier: String?
        var model: String?
        var title: String?
        var latency: Double?
        var duration: Double?
    }

    private func stream(_ request: ChatRequest, live: LiveTurn, titleEnabled: Bool) async throws -> Outcome {
        var outcome = Outcome()
        var accumulator = ToolCallAccumulator()
        var titleExtractor = TitleExtractor(enabled: titleEnabled)
        let start = Date()

        for try await event in client.streamChat(request) {
            switch event {
            case .generationID(let id):
                outcome.generationID = id
            case .keepAlive:
                break
            case .chunk(let chunk):
                if outcome.generationID == nil { outcome.generationID = chunk.id }
                if let p = chunk.provider { outcome.provider = p }
                if let t = chunk.serviceTier { outcome.serviceTier = t }
                if let m = chunk.model { outcome.model = m }
                if let u = chunk.usage { outcome.usage = u }
                for choice in chunk.choices ?? [] {
                    if let d = choice.delta {
                        if let r = d.reasoning, !r.isEmpty {
                            outcome.reasoning += r
                            live.reasoning = outcome.reasoning
                            if live.phase == .connecting { live.phase = .reasoning }
                        }
                        if let rd = d.reasoningDetails, !rd.isEmpty {
                            ReasoningDetailsMerger.merge(&outcome.reasoningDetails, rd)
                            if outcome.reasoning.isEmpty {
                                let summary = rd.compactMap { $0["summary"]?.stringValue ?? ($0["type"]?.stringValue == "reasoning.text" ? $0["text"]?.stringValue : nil) }.joined()
                                if !summary.isEmpty { live.reasoning += summary }
                            }
                        }
                        if let content = d.content, !content.isEmpty {
                            if outcome.latency == nil { outcome.latency = Date().timeIntervalSince(start) }
                            let shown = titleExtractor.feed(content)
                            outcome.text += shown
                            live.append(shown)
                        }
                        if let calls = d.toolCalls, !calls.isEmpty {
                            calls.forEach { accumulator.add($0) }
                            live.toolDrafts = accumulator.drafts.map { ($0.name, $0.arguments) }
                            if let name = accumulator.drafts.last?.name { live.phase = .tool(name) }
                        }
                        if let ann = d.annotations { outcome.annotations.append(contentsOf: ann) }
                    }
                    if let m = choice.message {
                        if let ann = m.annotations { outcome.annotations.append(contentsOf: ann) }
                    }
                    if let f = choice.finishReason { outcome.finishReason = f }
                }
            }
        }
        // Cancelling the task ends the stream quietly; surface it as an error so
        // stop / background handoff are handled instead of committing a "complete" reply.
        try Task.checkCancellation()
        let tail = titleExtractor.finish()
        if !tail.isEmpty {
            outcome.text += tail
            live.append(tail)
        }
        if live.reasoning.count > outcome.reasoning.count { outcome.reasoning = live.reasoning }
        outcome.title = titleExtractor.title
        outcome.toolCalls = accumulator.finalized()
        outcome.duration = Date().timeIntervalSince(start)
        return outcome
    }

    private func apply(_ outcome: Outcome, to message: Message, in conversation: Conversation) {
        message.text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        message.reasoning = outcome.reasoning
        message.reasoningDetails = outcome.reasoningDetails
        message.toolCalls = outcome.toolCalls
        message.annotations = outcome.annotations
        message.generationID = outcome.generationID
        message.provider = outcome.provider
        message.serviceTier = outcome.serviceTier
        if let m = outcome.model { message.modelID = m }
        message.usage = outcome.usage
        message.latency = outcome.latency
        message.duration = outcome.duration
        message.status = .complete
        if let usage = outcome.usage {
            record(cost: usage.cost ?? 0, kind: .chat, model: message.modelID ?? conversation.modelID, conversation: conversation, message: message, usage: usage)
        }
    }

    // MARK: - Costs

    func record(cost: Double, kind: UsageKind, model: String, conversation: Conversation?, message: Message?, usage: Usage? = nil) {
        let record = UsageRecord(kind: kind, modelID: model, cost: cost, conversationID: conversation?.id, messageID: message?.id,
                                 promptTokens: usage?.promptTokens ?? 0, completionTokens: usage?.completionTokens ?? 0,
                                 cachedTokens: usage?.cachedTokens ?? 0, reasoningTokens: usage?.reasoningTokens ?? 0)
        context.insert(record)
        message?.cost += cost
        conversation?.totalCost += cost
    }

    // MARK: - App lifecycle & background handoff

    func appDidBecomeActive() {
        isAppActive = true
        handoffTimer?.cancel()
        handoffTimer = nil
        BackgroundRunner.shared.drainPendingResults()
        tools.resumeVideoJobs()
        resumePendingToolCalls()
        // Background time is only needed while suspended; give it back now.
        endBackgroundTaskIfIdle(force: true)
        Task { await account.refresh() }
    }

    func appDidEnterBackground() {
        isAppActive = false
        guard !tasks.isEmpty else { return }
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "halo.reply") { [weak self] in
                // Called on the main thread; the task must be ended before this returns.
                MainActor.assumeIsolated {
                    self?.handOffAll()
                    self?.endBackgroundTaskIfIdle(force: true)
                }
            }
        }
        handoffTimer?.cancel()
        handoffTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 24_000_000_000)
            guard !Task.isCancelled else { return }
            self?.handOffAll()
        }
    }

    private func handOffAll() {
        for (id, turn) in live where tasks[id] != nil {
            switch turn.phase {
            case .connecting, .reasoning, .writing, .tool:
                turn.handingOff = true
                tasks[id]?.cancel()
            case .runningTools, .waitingApproval:
                tasks[id]?.cancel()   // tools (e.g. video polling) resume when the app returns
            }
        }
        // Give the loops a moment to enqueue their background requests.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.endBackgroundTaskIfIdle(force: true)
        }
    }

    private func endBackgroundTaskIfIdle(force: Bool = false) {
        guard backgroundTaskID != .invalid, force || tasks.isEmpty else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func handOff(request: ChatRequest, assistant: Message, conversation: Conversation) {
        do {
            let (urlRequest, body) = try client.backgroundChatRequest(request)
            try BackgroundRunner.shared.enqueue(urlRequest, body: body,
                                                job: .init(conversationID: conversation.id, messageID: assistant.id))
        } catch {
            assistant.status = .failed
            assistant.errorText = "Couldn't continue in the background: \(error.localizedDescription)"
            save()
        }
    }

    /// Applies a completed background (non-streaming) response.
    func applyBackgroundResult(_ job: BackgroundRunner.Job, data: Data?, status: Int, error: String?) {
        guard let message = message(id: job.messageID), let conversation = message.conversation else { return }
        if let error {
            message.status = .failed
            message.errorText = error
            save()
            return
        }
        guard let data, (200..<300).contains(status) else {
            message.status = .failed
            message.errorText = OpenRouterClient.errorFrom(status: status, data: data ?? Data()).localizedDescription
            save()
            return
        }
        guard let completion = try? JSONDecoder().decode(ChatCompletion.self, from: data),
              let choice = completion.choices?.first, let reply = choice.message else {
            message.status = .failed
            message.errorText = errorText(from: data)
            save()
            return
        }
        var text = reply.content ?? ""
        var extractor = TitleExtractor(enabled: !conversation.titleIsSet || text.hasPrefix("<title>"))
        text = extractor.feed(text) + extractor.finish()
        if let t = extractor.title, !t.isEmpty { conversation.title = t; conversation.titleIsSet = true }
        var outcome = Outcome()
        outcome.text = text
        outcome.reasoning = reply.reasoning ?? message.reasoning
        outcome.reasoningDetails = reply.reasoningDetails ?? []
        outcome.toolCalls = reply.toolCalls ?? []
        outcome.annotations = reply.annotations ?? []
        outcome.usage = completion.usage
        outcome.finishReason = choice.finishReason
        outcome.generationID = completion.id
        outcome.provider = completion.provider
        outcome.serviceTier = completion.serviceTier
        outcome.model = completion.model
        apply(outcome, to: message, in: conversation)
        save()
        if outcome.toolCalls.isEmpty {
            if settings.notifyWhenDone {
                NotificationService.post(title: conversation.title, body: text.isEmpty ? "Reply ready" : text, conversationID: conversation.id)
            }
        } else if settings.notifyWhenDone {
            NotificationService.post(title: conversation.title, body: "Halo is ready to continue — open the app to run \(outcome.toolCalls.map(\.name).joined(separator: ", ")).", conversationID: conversation.id)
        }
        if isAppActive { resumePendingToolCalls() }
    }

    private func errorText(from data: Data) -> String {
        if let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) { return env.error.message ?? "Request failed" }
        return "The background request returned an unexpected response."
    }

    /// Runs tool calls left unexecuted (e.g. a reply that finished in the background).
    func resumePendingToolCalls() {
        let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        guard let conversations = try? context.fetch(descriptor) else { return }
        for conversation in conversations.prefix(20) where !isBusy(conversation) && !userStopped.contains(conversation.id) {
            let ordered = conversation.orderedMessages
            guard let last = ordered.last else { continue }
            if last.role == .assistant, last.status == .complete, !last.toolCalls.isEmpty {
                let calls = last.toolCalls
                launch(conversation) { [weak self] live in
                    guard let self else { return }
                    live.phase = .runningTools
                    let needsUser = await self.tools.execute(calls, after: last, in: conversation)
                    self.save()
                    if !needsUser { await self.runLoop(conversation, live: live) }
                }
            } else if last.role == .tool, allToolCallsResolved(conversation) {
                startTurn(conversation)
            }
        }
    }
}
