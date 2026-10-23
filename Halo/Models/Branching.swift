import Foundation
import SwiftData

/// Messages form a tree: editing a message or regenerating a reply adds a sibling instead of
/// replacing it. `orderedMessages` is the branch on screen, from the first message to `activeLeafID`.
///
/// Chats from before branching have no parent links and no leaf; they read as one line ordered by
/// `sortIndex` until something changes them, when `threadIfNeeded()` links them up.
extension Conversation {
    var isThreaded: Bool { activeLeafID != nil }

    var orderedMessages: [Message] {
        let all = messages
        guard isThreaded else { return all.sorted { $0.sortIndex < $1.sortIndex } }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard var node = activeLeafID.flatMap({ byID[$0] }) ?? all.max(by: { $0.sortIndex < $1.sortIndex }) else { return [] }
        var path = [node]
        while let pid = node.parentID, let parent = byID[pid], path.count <= all.count {
            path.append(parent)
            node = parent
        }
        return path.reversed()
    }

    /// Links an older, linear chat into a single branch so new messages can hang off it.
    func threadIfNeeded() {
        guard !isThreaded else { return }
        let sorted = messages.sorted { $0.sortIndex < $1.sortIndex }
        for (previous, m) in zip(sorted, sorted.dropFirst()) where m.parentID == nil {
            m.parentID = previous.id
        }
        activeLeafID = sorted.last?.id
    }

    /// Adds `message` at the end of the branch on screen. The caller inserts it into the context.
    func append(_ message: Message) {
        threadIfNeeded()
        attach(message, under: orderedMessages.last?.id)
    }

    /// Adds `message` as a child of `parentID` (nil makes it a new first message) and shows its branch.
    func attach(_ message: Message, under parentID: UUID?) {
        threadIfNeeded()
        message.sortIndex = nextSortIndex
        message.parentID = parentID
        message.conversation = self
        activeLeafID = message.id
    }

    /// Shows the branch that goes through `message`, following its newest replies to the end.
    func showBranch(through message: Message) {
        threadIfNeeded()
        let children = Dictionary(grouping: messages.filter { $0.parentID != nil }, by: { $0.parentID! })
        var node = message
        var steps = 0
        while let next = children[node.id]?.max(by: { $0.sortIndex < $1.sortIndex }), steps < messages.count {
            node = next
            steps += 1
        }
        activeLeafID = node.id
    }

    /// Deletes `message` and everything that follows it on any branch, plus media no other message uses.
    func deleteBranch(from message: Message, in context: ModelContext) {
        threadIfNeeded()
        let all = messages
        let children = Dictionary(grouping: all.filter { $0.parentID != nil }, by: { $0.parentID! })
        var doomed: [Message] = []
        var seen = Set<UUID>()
        var queue = [message]
        while let m = queue.popLast() {
            guard seen.insert(m.id).inserted else { continue }
            doomed.append(m)
            queue += children[m.id] ?? []
        }
        let remaining = all.filter { !seen.contains($0.id) }
        if let leaf = activeLeafID, seen.contains(leaf) {
            activeLeafID = message.parentID ?? remaining.max(by: { $0.sortIndex < $1.sortIndex })?.id
        }
        let keptFiles = Set(remaining.flatMap { $0.media.map(\.filename) })
        for m in doomed {
            for item in m.media where !keptFiles.contains(item.filename) { MediaStore.delete(item) }
            context.delete(m)
        }
    }
}

/// Where a message sits among its alternatives, for the "‹ 2/3 ›" switcher.
struct BranchPosition: Equatable {
    let index: Int
    let count: Int
    let previous: Message?
    let next: Message?

    static func == (a: BranchPosition, b: BranchPosition) -> Bool {
        a.index == b.index && a.count == b.count && a.previous?.id == b.previous?.id && a.next?.id == b.next?.id
    }
}

/// Sibling lookups for one render of a conversation.
struct BranchIndex {
    private var siblings: [UUID?: [Message]] = [:]

    init(_ conversation: Conversation) {
        guard conversation.isThreaded else { return }
        siblings = Dictionary(grouping: conversation.messages, by: \.parentID)
            .mapValues { $0.sorted { $0.sortIndex < $1.sortIndex } }
    }

    /// Nil when `message` has no alternatives.
    func position(of message: Message) -> BranchPosition? {
        guard let group = siblings[message.parentID], group.count > 1,
              let i = group.firstIndex(where: { $0.id == message.id }) else { return nil }
        return BranchPosition(index: i, count: group.count,
                              previous: i > 0 ? group[i - 1] : nil,
                              next: i < group.count - 1 ? group[i + 1] : nil)
    }
}
