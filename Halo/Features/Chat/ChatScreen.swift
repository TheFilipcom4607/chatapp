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
            Composer(conversation: conversation)
        }
        .environment(\.codeActions, codeActions)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(Motion.smooth) { app.sidebarOpen.toggle() }
                    Haptics.selection()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Chats")
            }
            ToolbarItem(placement: .principal) {
                ModelPickerButton(conversation: conversation)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let conversation, conversation.totalCost > 0 {
                    CostPill(conversation: conversation)
                }
                Button { app.newChat() } label: {
                    Image(systemName: "square.and.pencil").font(.body.weight(.semibold))
                }
                .accessibilityLabel("New chat")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }

    private var codeActions: CodeActions {
        CodeActions(
            run: { language, code in
                app.sheet = .run(language, code)
            },
            preview: { language, code in
                app.sheet = .preview(language, code)
            }
        )
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
                .font(.caption.weight(.semibold).monospacedDigit())
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
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var nearBottom = true

    var body: some View {
        let messages = conversation.orderedMessages
        let live = engine.liveTurn(for: conversation)
        let lastAssistantIDs = turnEndingAssistantIDs(messages)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(messages) { message in
                    MessageRow(message: message,
                               conversation: conversation,
                               live: live?.messageID == message.id ? live : nil,
                               showFooter: lastAssistantIDs.contains(message.id) && live == nil)
                        .id(message.id)
                }
                Color.clear.frame(height: 12).id("bottom")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
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
            withAnimation(Motion.smooth) { position.scrollTo(edge: .bottom) }
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

    /// Assistant messages that end a turn (followed by a user message or the end).
    private func turnEndingAssistantIDs(_ messages: [Message]) -> Set<UUID> {
        var result = Set<UUID>()
        var lastAssistant: UUID?
        for m in messages {
            switch m.role {
            case .assistant: lastAssistant = m.id
            case .user:
                if let a = lastAssistant { result.insert(a) }
                lastAssistant = nil
            default: break
            }
        }
        if let a = lastAssistant { result.insert(a) }
        return result
    }
}
