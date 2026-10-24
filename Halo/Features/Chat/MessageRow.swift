import SwiftUI

struct MessageRow: View {
    let message: Message
    let conversation: Conversation
    let live: LiveTurn?
    /// The whole turn's sources, on the reply they're shown under (empty on the turn's other replies).
    var sources: [Citation] = []
    /// For a user message, its edits; for the reply that ends a turn without a footer, the turn's other replies.
    var branch: BranchPosition? = nil

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(message: message, conversation: conversation, branch: branch)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        case .assistant:
            AssistantMessageView(message: message, conversation: conversation, live: live, sources: sources, branch: branch)
        case .tool:
            ToolMessageView(message: message, conversation: conversation)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .system:
            SummaryCard(message: message, conversation: conversation, live: live)
        }
    }
}

// MARK: - Summary

/// Marks where older messages were summarized; the summary is what the model sees from here on.
struct SummaryCard: View {
    let message: Message
    let conversation: Conversation
    let live: LiveTurn?
    @Environment(ChatEngine.self) private var engine
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.smooth) { expanded.toggle() }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.compress.vertical")
                    if live != nil {
                        ShimmerText(text: "Summarizing earlier messages", font: .subheadline.weight(.medium))
                    } else {
                        Text("Earlier messages summarized").font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(live != nil)

            if let live {
                if !live.displayed.isEmpty {
                    Text(String(live.displayed.suffix(280)))
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(4)
                }
            } else if expanded {
                MarkdownView(text: message.text, isStreaming: false)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("The model sees this summary instead of the messages above.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            if live == nil {
                Button { UIPasteboard.general.string = message.text; Haptics.success() } label: { Label("Copy summary", systemImage: "doc.on.doc") }
                Button(role: .destructive) { engine.removeSummary(message, in: conversation) } label: {
                    Label("Remove summary", systemImage: "arrow.uturn.backward")
                }
                .disabled(engine.isBusy(conversation))
            }
        }
    }
}

// MARK: - User

struct UserBubble: View {
    let message: Message
    let conversation: Conversation
    var branch: BranchPosition?
    @Environment(ChatEngine.self) private var engine
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            let media = message.media
            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(media) { item in AttachmentThumb(item: item, size: 88) }
                    }
                }
                .scrollClipDisabled()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .environment(\.layoutDirection, .rightToLeft)
            }
            if isEditing {
                editor
            } else if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text; Haptics.success() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { AppModel.shared.sheet = .selectText(message.text) } label: { Label("Select text", systemImage: "selection.pin.in.out") }
                        Button { startEditing() } label: { Label("Edit", systemImage: "pencil") }
                            .disabled(engine.isBusy(conversation))
                    }
            }
            if let branch, !isEditing {
                BranchSwitcher(position: branch, conversation: conversation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, isEditing ? 0 : 48)
    }

    private var canSend: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != message.text && (!trimmed.isEmpty || !message.media.isEmpty) && !engine.isBusy(conversation)
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...12)
                .font(.body)
                .focused($editorFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline))
            HStack(spacing: 10) {
                Text("Sends as a new branch")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel") { stopEditing() }
                    .buttonStyle(.glass)
                Button {
                    engine.edit(message, to: draft, in: conversation)
                    stopEditing()
                } label: {
                    Text("Send")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
            }
        }
        .transition(.opacity)
    }

    private func startEditing() {
        draft = message.text
        withAnimation(Motion.snappy) { isEditing = true }
        editorFocused = true
    }

    private func stopEditing() {
        editorFocused = false
        withAnimation(Motion.snappy) { isEditing = false }
    }
}

/// "‹ 2/3 ›": steps through a message's edits or a turn's replies.
struct BranchSwitcher: View {
    let position: BranchPosition
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine

    var body: some View {
        let busy = engine.isBusy(conversation)
        HStack(spacing: 2) {
            step(to: position.previous, systemImage: "chevron.left", label: "Previous version", busy: busy)
            Text("\(position.index + 1)/\(position.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
            step(to: position.next, systemImage: "chevron.right", label: "Next version", busy: busy)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version \(position.index + 1) of \(position.count)")
    }

    private func step(to target: Message?, systemImage: String, label: String, busy: Bool) -> some View {
        Button {
            if let target { withAnimation(Motion.snappy) { engine.showBranch(through: target, in: conversation) } }
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil || busy ? Theme.textTertiary.opacity(0.5) : Theme.textSecondary)
        .disabled(target == nil || busy)
        .accessibilityLabel(label)
    }
}

struct AttachmentThumb: View {
    let item: MediaItem
    var size: CGFloat = 64
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if item.kind == .image, let img = MediaStore.image(for: item) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture { app.viewingImage = item }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: item.kind == .pdf ? "doc.richtext.fill" : item.kind == .audio ? "waveform" : "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                    Text(item.originalName ?? item.kind.rawValue)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(8)
                .frame(width: size * 1.3, height: size)
                .glassCard(cornerRadius: 16)
            }
        }
    }
}

// MARK: - Assistant

struct AssistantMessageView: View {
    let message: Message
    let conversation: Conversation
    let live: LiveTurn?
    var sources: [Citation] = []
    var branch: BranchPosition?

    @Environment(ChatEngine.self) private var engine

    private var text: String { live?.displayed ?? message.text }
    private var reasoning: String { live?.reasoning ?? message.reasoning }
    private var isStreaming: Bool { live != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !reasoning.isEmpty {
                ReasoningDisclosure(text: reasoning, isActive: isStreaming && text.isEmpty,
                                    duration: message.latency ?? message.duration, startedAt: live?.startedAt)
            }
            if let live, text.isEmpty, reasoning.isEmpty || live.phase != .reasoning {
                LivePhaseIndicator(live: live)
            }
            if !text.isEmpty {
                MarkdownView(text: text, isStreaming: isStreaming)
                    .foregroundStyle(Theme.textPrimary)
            }
            if let live, !text.isEmpty, live.phase == .writing {
                EclipseMark(size: 14, orbiting: true)
                    .transition(.opacity)
            }
            if let live {
                ForEach(Array(live.toolDrafts.enumerated()), id: \.offset) { _, draft in
                    ToolDraftCard(name: draft.name, arguments: draft.arguments)
                }
            }
            if !sources.isEmpty {
                CitationsRow(citations: sources)
            }
            switch message.status {
            case .failed:
                if ContextBudget.isOverflowError(message.errorText) {
                    ErrorCard(text: message.errorText ?? "Something went wrong.", retry: { engine.retry(conversation) },
                              summarize: {
                                  if !engine.summarizeAndRetry(conversation) {
                                      AppModel.shared.showToast("Nothing earlier to summarize. Try a model with a longer context.")
                                  }
                              })
                } else {
                    ErrorCard(text: message.errorText ?? "Something went wrong.") { engine.retry(conversation) }
                }
            case .background:
                HStack(spacing: 10) {
                    Spinner(size: 14)
                    ShimmerText(text: "Finishing in the background", font: .subheadline.weight(.medium))
                }
            case .cancelled:
                Label("Stopped", systemImage: "stop.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            default:
                EmptyView()
            }
            if let branch, !isStreaming {
                BranchSwitcher(position: branch, conversation: conversation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !message.text.isEmpty {
                Button { UIPasteboard.general.string = message.text; Haptics.success() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { AppModel.shared.sheet = .selectText(message.text) } label: { Label("Select text", systemImage: "selection.pin.in.out") }
            }
            Button { AppModel.shared.sheet = .details(message.id) } label: { Label("Details", systemImage: "info.circle") }
            Button { engine.regenerate(message, in: conversation) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
        }
    }
}

struct LivePhaseIndicator: View {
    let live: LiveTurn

    var body: some View {
        HStack(spacing: 10) {
            EclipseMark(size: 18, orbiting: live.phase != .waitingApproval)
            switch live.phase {
            case .connecting, .writing: EmptyView()
            case .reasoning: ShimmerText(text: "Thinking")
            case .tool(let name): ShimmerText(text: Self.label(for: name))
            case .runningTools: ShimmerText(text: "Working")
            case .waitingApproval: Text("Waiting for approval").font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(height: 22)
        .transition(.opacity)
    }

    static func label(for tool: String) -> String {
        switch ToolName(rawValue: tool) {
        case .generateImage: return "Preparing image"
        case .generateVideo: return "Preparing video"
        case .generateSpeech: return "Generating audio"
        case .runCode: return "Writing code"
        case .shell: return "Running command"
        case .createArtifact: return "Writing document"
        case .updateArtifact: return "Editing document"
        case .readWebPage: return "Reading page"
        case .deviceInfo: return "Checking device"
        case .openInApp: return "Making a link"
        case .getLocation: return "Finding location"
        case .getWeather: return "Checking weather"
        case .searchPlaces: return "Searching Maps"
        case .getDirections: return "Getting directions"
        case .listEvents: return "Reading calendar"
        case .listReminders: return "Reading reminders"
        case .createEvent: return "Preparing event"
        case .createReminder: return "Preparing reminder"
        case .none: return "Working"
        }
    }
}

struct ReasoningDisclosure: View {
    let text: String
    let isActive: Bool
    /// Seconds until the answer began, for a finished reply.
    let duration: Double?
    /// When the live reply started, to count the thinking time up.
    var startedAt: Date?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.smooth) { expanded.toggle() }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    if isActive {
                        EclipseMark(size: 14, orbiting: true)
                            .padding(.trailing, 2)
                        if let startedAt {
                            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                ShimmerText(text: "Thinking · \(Self.seconds(context.date.timeIntervalSince(startedAt)))",
                                            font: .subheadline.weight(.medium))
                            }
                        } else {
                            ShimmerText(text: "Thinking", font: .subheadline.weight(.medium))
                        }
                    } else if let duration, duration >= 1 {
                        Text("Thought for \(Self.seconds(duration))").font(.subheadline.weight(.medium))
                    } else {
                        Text("Thoughts").font(.subheadline.weight(.medium))
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.hairline).frame(width: 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isActive {
                Text(lastLines(text))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
        }
    }

    /// "8s", "1m 5s".
    static func seconds(_ t: Double) -> String {
        let n = max(0, Int(t.rounded()))
        return n < 60 ? "\(n)s" : "\(n / 60)m \(n % 60)s"
    }

    private func lastLines(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(220))
    }
}

/// A compact pill under the answer (site initials and a count) that opens the full list in a sheet.
struct CitationsRow: View {
    let citations: [Citation]
    @State private var showList = false

    /// Up to three different sites, for the overlapping initials.
    private var sites: [String] {
        var seen = Set<String>()
        return citations.map(\.siteName).filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    var body: some View {
        Button { showList = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(sites, id: \.self) { SiteMark(site: $0, size: 22) }
                }
                Text("\(citations.count) source\(citations.count == 1 ? "" : "s")")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 34)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(citations.count) sources")
        .sheet(isPresented: $showList) { SourcesSheet(citations: citations) }
    }
}

/// A site's initial in a circle, standing in for its icon.
struct SiteMark: View {
    let site: String
    var size: CGFloat = 22

    var body: some View {
        Text(site.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .background(Color(white: 0.22), in: Circle())
            .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
    }
}

struct SourcesSheet: View {
    let citations: [Citation]
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(citations.enumerated()), id: \.element.id) { i, c in
                    Button {
                        if let url = URL(string: c.url) { openURL(url) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            SiteMark(site: c.siteName, size: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(i + 1) · \(c.host)")
                                    .font(.readout(.caption2))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(c.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(2)
                                if let snippet = c.snippet, !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.03))
                }
            }
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
    }
}

struct ErrorCard: View {
    let text: String
    let retry: () -> Void
    /// Offered when the chat no longer fits the model's context window.
    var summarize: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.negative)
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    if let summarize {
                        Button("Summarize and retry", action: summarize)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    Button("Try again", action: retry)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Under a finished turn: copy, read aloud, regenerate, share and more, then what the turn cost.
struct MessageFooter: View {
    let turn: TurnSummary
    let conversation: Conversation
    var branch: BranchPosition?
    @Environment(ChatEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var copied = false

    var body: some View {
        let text = turn.text
        HStack(spacing: 16) {
            if let branch {
                BranchSwitcher(position: branch, conversation: conversation)
                    .padding(.horizontal, -6)
            }
            if !text.isEmpty {
                Button {
                    UIPasteboard.general.string = text
                    Haptics.success()
                    withAnimation(Motion.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel("Copy")
                ReadAloudButton(turn: turn)
            }
            if let message = turn.last {
                Menu {
                    Button { engine.regenerate(message, in: conversation) } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    Section("Try another model") {
                        ForEach(settings.favoriteModelIDs.filter { $0 != conversation.modelID }, id: \.self) { id in
                            Button(catalog.displayName(id)) { engine.regenerate(message, in: conversation, modelID: id) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Regenerate")
            }
            if !text.isEmpty {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
            Menu {
                if !text.isEmpty {
                    Button { app.sheet = .selectText(text) } label: { Label("Select text", systemImage: "selection.pin.in.out") }
                }
                if let message = turn.last {
                    Button { app.sheet = .details(message.id) } label: { Label("Details", systemImage: "info.circle") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(height: 20)
            }
            .accessibilityLabel("More")
            Spacer()
            if turn.cost > 0 {
                Text(Money.format(turn.cost))
                    .font(.readout())
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText(value: turn.cost))
            }
            // A tortoise or hare marks a reply served by Flex or Priority (the same marks as the models list).
            if let symbol = ServiceTier(response: turn.last?.serviceTier).symbol {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(ServiceTier(response: turn.last?.serviceTier).title)
            }
            Text(catalog.displayName(turn.last?.modelID ?? conversation.modelID))
                .font(.readout())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

/// Speaks the turn's replies with the voice model. The first tap makes the audio (a spinner shows
/// meanwhile); it's kept, so later taps just play it. Tapping while it plays stops it.
struct ReadAloudButton: View {
    let turn: TurnSummary
    @Environment(ChatEngine.self) private var engine
    private var reader: ReadAloudPlayer { .shared }

    var body: some View {
        let id = turn.last?.id
        let playing = id != nil && reader.playingID == id
        // Between pieces of a long reply the spinner shows again until the next one is ready.
        let loading = id != nil && reader.loadingID == id && !playing
        Button {
            reader.toggle(turn.assistants, engine: engine)
        } label: {
            ZStack {
                if loading {
                    Spinner(size: 14)
                } else {
                    Image(systemName: playing ? "stop.fill" : "speaker.wave.2")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 22, height: 20)
        }
        .accessibilityLabel(playing ? "Stop reading" : loading ? "Preparing audio, tap to cancel" : "Read aloud")
    }
}
