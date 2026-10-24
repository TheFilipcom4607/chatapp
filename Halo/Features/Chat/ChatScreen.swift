import SwiftUI

struct ChatScreen: View {
    let conversation: Conversation?
    @Environment(AppModel.self) private var app
    @Environment(ChatEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let conversation, !conversation.messages.isEmpty {
                MessageList(conversation: conversation)
            } else {
                HomeView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let conversation, !conversation.messages.isEmpty {
                    ShellApprovalPopup(conversation: conversation)
                    ContextBanner(conversation: conversation)
                }
                Composer(conversation: conversation)
            }
        }
        // A bar of our own: the system one centers the title between its side items, so a wide
        // trailing group pushed the model name off center.
        // Run / Preview on code blocks (lost once when the top bar was rebuilt).
        .environment(\.codeActions, codeActions)
        .safeAreaBar(edge: .top) { topBar }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var codeActions: CodeActions {
        CodeActions(
            run: { language, code in app.sheet = .run(language, code) },
            preview: { language, code in app.sheet = .preview(language, code) }
        )
    }

    private var topBar: some View {
        GlassEffectContainer {
            CenteredBarLayout {
                Button {
                    // First: once the sidebar is open the chat ignores touches and its field keeps focus.
                    Keyboard.dismiss()
                    withAnimation(Motion.smooth) { app.sidebarOpen.toggle() }
                    Haptics.selection()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Chats")

                ModelPickerButton(conversation: conversation)
                    .frame(height: 44)

                HStack(spacing: 0) {
                    if let conversation, conversation.totalCost > 0 {
                        CostPill(conversation: conversation)
                            .padding(.leading, 14)
                            .padding(.trailing, 2)
                            .frame(height: 44)
                    }
                    Button { app.newChat() } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New chat")
                }
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// Shown above the composer when a chat nears the model's context limit (in "Warn me" mode).
struct ContextBanner: View {
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    /// Percent full when the banner was closed; it comes back 10 points later.
    @State private var dismissedAt: Int?

    var body: some View {
        Group {
            if settings.longChatMode == LongChatMode.ask.rawValue, !engine.isBusy(conversation),
               let usage = engine.contextUsage(for: conversation), usage.fraction >= ContextBudget.warnAt,
               dismissedAt.map({ usage.percent >= $0 + 10 }) ?? true,
               engine.canSummarize(conversation) {
                banner(usage)
            }
        }
        .animation(Motion.snappy, value: dismissedAt)
    }

    private func banner(_ usage: ContextUsage) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.fillStrong, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(usage.fraction, 1))
                    .stroke(usage.fraction >= 0.95 ? Theme.negative : Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.fraction >= 1 ? "Too long for \(catalog.displayName(conversation.modelID))" : "This chat is \(usage.percent)% full")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Summarize older messages to keep going.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            Button { engine.summarize(conversation) } label: {
                Text("Summarize")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button { dismissedAt = usage.percent } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Three controls in a row: the first and last at the edges, the middle one centered on the bar
/// and truncated, rather than pushed aside, when the sides leave it too little room.
struct CenteredBarLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailing))
        let side = max(leading.width, trailing.width) + spacing
        let room = max(bounds.width - 2 * side, 0)
        let middle = subviews[1].sizeThatFits(ProposedViewSize(width: room, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: min(middle.width, room), height: bounds.height))
    }
}

struct CostPill: View {
    let conversation: Conversation
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.sheet = .spend
        } label: {
            Text(Money.format(conversation.totalCost, compact: true))
                .font(.readout(.caption, weight: .medium))
                .contentTransition(.numericText(value: conversation.totalCost))
                .animation(Motion.snappy, value: conversation.totalCost)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityLabel("Chat cost \(Money.format(conversation.totalCost))")
    }
}

/// Scrollable list of messages that follows the stream while you're at the bottom.
struct MessageList: View {
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var nearBottom = true

    var body: some View {
        let messages = conversation.orderedMessages
        let live = engine.liveTurn(for: conversation)
        let turns = TurnSummary.byLastMessage(messages)
        let branches = BranchIndex(conversation)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(messages) { message in
                    let turn = turns[message.id]
                    // The running reply's turn has no footer yet; earlier turns keep theirs.
                    let footer = turn.flatMap { $0.hasFooter && (live == nil || message.id != messages.last?.id) ? $0 : nil }
                    let turnBranch = turn.flatMap { branches.position(of: $0.head) }
                    let isLive = live?.messageID == message.id
                    if isLive || !message.isBlankReply {
                        MessageRow(message: message,
                                   conversation: conversation,
                                   live: isLive ? live : nil,
                                   branch: message.role == .user ? branches.position(of: message)
                                       : footer == nil && turn?.assistants.last?.id == message.id ? turnBranch : nil)
                            .id(message.id)
                    }
                    if let footer {
                        MessageFooter(turn: footer, conversation: conversation, branch: turnBranch)
                            .padding(.top, -8)
                    }
                }
                Color.clear.frame(height: 12).id("bottom")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollPosition($position)
        // A hard edge: with the soft one, text scrolling under the bar shows through as a smear.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // Any scroll by hand puts the keyboard away (interactive only did when dragging into it).
        .scrollDismissesKeyboard(.immediately)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 120
        } action: { _, isNear in
            nearBottom = isNear
        }
        .onChange(of: live?.displayed.count ?? 0) { _, _ in
            if nearBottom { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: messages.count) { _, _ in
            guard app.scrollTarget == nil else { return }
            withAnimation(Motion.smooth) { position.scrollTo(edge: .bottom) }
        }
        .task(id: app.scrollTarget) {
            // A search hit: wait for the list to lay out, then bring the message into view.
            guard let target = app.scrollTarget else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            if conversation.orderedMessages.contains(where: { $0.id == target }) {
                withAnimation(Motion.smooth) { position.scrollTo(id: target, anchor: .top) }
            }
            app.scrollTarget = nil
        }
        .overlay(alignment: .bottom) {
            if !nearBottom {
                Button {
                    withAnimation(Motion.smooth) { position.scrollTo(edge: .bottom) }
                    Haptics.tap()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.bottom, 10)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: nearBottom)
    }
}

extension Message {
    /// A finished reply with nothing to show (it only called tools, or ended a turn without
    /// words). Left out of the list, so it doesn't add an empty gap.
    var isBlankReply: Bool {
        role == .assistant && status == .complete && text.isEmpty && reasoning.isEmpty && annotations.isEmpty
    }
}

/// One reply to a user message: everything from just after it to the next user message.
struct TurnSummary {
    /// The turn's first message, whose siblings are the turn's other replies.
    let head: Message
    let assistants: [Message]
    /// What the whole turn cost: replies, images, speech and other tool work.
    let cost: Double
    /// A tool still waits for approval or is running, so the turn isn't over.
    let isPending: Bool

    var last: Message? { assistants.last }

    /// The footer sits under a finished turn, even one that ended on tools with no closing text.
    var hasFooter: Bool {
        guard let last, !isPending else { return false }
        return last.status == .complete || last.status == .cancelled
    }

    /// Every reply's text in the turn, for copying and sharing.
    var text: String {
        assistants.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Turns that have a reply, keyed by their last message of any role (where the footer goes).
    /// A summary card ends a turn too, so the footer stays with the replies above it.
    static func byLastMessage(_ messages: [Message]) -> [UUID: TurnSummary] {
        var result: [UUID: TurnSummary] = [:]
        var current: [Message] = []
        func close() {
            let assistants = current.filter { $0.role == .assistant }
            if let head = current.first, let end = current.last, !assistants.isEmpty {
                let pending = current.contains { $0.role == .tool && ($0.toolState?.status == .awaitingApproval || $0.toolState?.status == .running) }
                result[end.id] = TurnSummary(head: head, assistants: assistants, cost: current.reduce(0) { $0 + $1.cost }, isPending: pending)
            }
            current = []
        }
        for m in messages {
            if m.role == .user || m.role == .system { close() } else { current.append(m) }
        }
        close()
        return result
    }
}
