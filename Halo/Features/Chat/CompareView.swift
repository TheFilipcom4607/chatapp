import SwiftUI

/// A compare's replies side by side, each under its model, with a way to carry on from any of them.
/// Shown while the compare ends the chat; once the chat moves on, the chosen reply reads as usual
/// and the others are its ‹ 1/3 › siblings.
struct CompareColumns: View {
    let replies: [Message]
    let conversation: Conversation

    @Environment(ChatEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog

    /// Narrower than this and a reply gets hard to read; past that the row scrolls sideways.
    private static let minColumnWidth: CGFloat = 240
    private static let spacing: CGFloat = 12

    var body: some View {
        let count = CGFloat(replies.count)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(replies) { reply in
                    column(reply)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            max(Self.minColumnWidth, (length - Self.spacing * (count - 1)) / count)
                        }
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private func column(_ reply: Message) -> some View {
        let isActive = reply.id == conversation.activeLeafID
        let live = engine.compareLive[reply.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(catalog.displayName(reply.modelID ?? conversation.modelID))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if live == nil, reply.cost > 0 {
                    Text(Money.format(reply.cost))
                        .font(.readout())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            AssistantMessageView(message: reply, conversation: conversation, live: live, sources: reply.citations)
            if !engine.isBusy(conversation) {
                if isActive {
                    Label("Continuing with this", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button { engine.choose(reply, in: conversation) } label: {
                        Text("Continue with this")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                    }
                    .buttonStyle(.haloGlass)
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isActive ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: isActive ? 1.5 : 1)
        }
        .animation(Motion.snappy, value: isActive)
    }
}

extension Conversation {
    /// The compare that ends the chat on screen: its replies, oldest first. Nil once the chat has
    /// moved on from it, or when the last message isn't a compare's reply.
    var trailingCompare: [Message]? {
        let path = orderedMessages
        guard let last = path.last, last.role == .assistant,
              let user = path.dropLast().last, user.isCompare == true else { return nil }
        let replies = messages.filter { $0.parentID == user.id && $0.role == .assistant }
            .sorted { $0.sortIndex < $1.sortIndex }
        return replies.count > 1 ? replies : nil
    }
}
