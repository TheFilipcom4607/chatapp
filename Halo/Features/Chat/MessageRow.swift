import SwiftUI

struct MessageRow: View {
    let message: Message
    let conversation: Conversation
    let live: LiveTurn?
    let showFooter: Bool

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(message: message)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        case .assistant:
            AssistantMessageView(message: message, conversation: conversation, live: live, showFooter: showFooter)
        case .tool:
            ToolMessageView(message: message, conversation: conversation)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .system:
            EmptyView()
        }
    }
}

// MARK: - User

struct UserBubble: View {
    let message: Message
    @Environment(AppModel.self) private var app

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
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text; Haptics.success() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { app.requestComposer(prefill: message.text) } label: { Label("Edit as new message", systemImage: "pencil") }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
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
    let showFooter: Bool

    @Environment(ChatEngine.self) private var engine

    private var text: String { live?.displayed ?? message.text }
    private var reasoning: String { live?.reasoning ?? message.reasoning }
    private var isStreaming: Bool { live != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !reasoning.isEmpty {
                ReasoningDisclosure(text: reasoning, isActive: isStreaming && text.isEmpty,
                                    duration: message.latency)
            }
            if let live, text.isEmpty, reasoning.isEmpty || live.phase != .reasoning {
                LivePhaseIndicator(live: live)
            }
            if !text.isEmpty {
                MarkdownView(text: text, isStreaming: isStreaming)
                    .foregroundStyle(Theme.textPrimary)
            }
            if let live {
                ForEach(Array(live.toolDrafts.enumerated()), id: \.offset) { _, draft in
                    ToolDraftCard(name: draft.name, arguments: draft.arguments)
                }
            }
            let citations = message.citations
            if !citations.isEmpty {
                CitationsRow(citations: citations, searches: message.usage?.webSearches ?? 0)
            }
            switch message.status {
            case .failed:
                ErrorCard(text: message.errorText ?? "Something went wrong.") { engine.retry(conversation) }
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
            if showFooter, !isStreaming, message.status == .complete || message.status == .cancelled, !message.text.isEmpty {
                MessageFooter(message: message, conversation: conversation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if !message.text.isEmpty {
                Button { UIPasteboard.general.string = message.text; Haptics.success() } label: { Label("Copy", systemImage: "doc.on.doc") }
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
            switch live.phase {
            case .connecting: PulseDot()
            case .reasoning: ShimmerText(text: "Thinking")
            case .writing: PulseDot()
            case .tool(let name): ShimmerText(text: Self.label(for: name))
            case .runningTools: ShimmerText(text: "Working")
            case .waitingApproval: Text("Waiting for approval").font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }
        .transition(.opacity)
    }

    static func label(for tool: String) -> String {
        switch ToolName(rawValue: tool) {
        case .generateImage: return "Preparing image"
        case .generateVideo: return "Preparing video"
        case .generateSpeech: return "Generating audio"
        case .runCode: return "Writing code"
        case .createArtifact: return "Writing document"
        case .updateArtifact: return "Editing document"
        case .none: return "Working"
        }
    }
}

struct ReasoningDisclosure: View {
    let text: String
    let isActive: Bool
    let duration: Double?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.smooth) { expanded.toggle() }
                Haptics.selection()
            } label: {
                HStack(spacing: 8) {
                    if isActive {
                        ShimmerText(text: "Thinking", font: .subheadline.weight(.medium))
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

    private func lastLines(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(220))
    }
}

struct CitationsRow: View {
    let citations: [Citation]
    let searches: Int
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(citations.count) source\(citations.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(citations.enumerated()), id: \.element.id) { i, c in
                        Button {
                            if let url = URL(string: c.url) { openURL(url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 18, height: 18)
                                        .background(Theme.fillStrong, in: Circle())
                                    Text(c.host).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                                }
                                Text(c.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .frame(width: 170, alignment: .leading)
                            .padding(10)
                            .glassCard(cornerRadius: 16, interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

struct ErrorCard: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.negative)
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Button("Try again", action: retry)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MessageFooter: View {
    let message: Message
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @State private var copied = false

    var body: some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = message.text
                Haptics.success()
                withAnimation(Motion.snappy) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
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
            ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
            Button { app.sheet = .details(message.id) } label: { Image(systemName: "info.circle") }
            Spacer()
            if message.cost > 0 {
                Text(Money.format(message.cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(catalog.displayName(message.modelID ?? conversation.modelID))
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}
