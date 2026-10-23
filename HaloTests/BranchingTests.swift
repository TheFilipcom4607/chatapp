import XCTest
import SwiftData
@testable import Halo

@MainActor
final class BranchingTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try ModelContainer(for: Conversation.self, Message.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    private func newConversation() -> Conversation {
        let c = Conversation(modelID: "test/model")
        context.insert(c)
        return c
    }

    @discardableResult
    private func append(_ role: MessageRole, _ text: String, to c: Conversation) -> Message {
        let m = Message(role: role, text: text)
        c.append(m)
        context.insert(m)
        try? context.save()
        return m
    }

    private func texts(_ c: Conversation) -> [String] { c.orderedMessages.map(\.text) }

    func testLegacyChatReadsInOrderAndThreadsOnAppend() throws {
        let c = newConversation()
        for (i, text) in ["u1", "a1", "u2", "a2"].enumerated() {
            let m = Message(role: i % 2 == 0 ? .user : .assistant, text: text, sortIndex: i)
            m.conversation = c
            context.insert(m)
        }
        try context.save()
        XCTAssertFalse(c.isThreaded)
        XCTAssertEqual(texts(c), ["u1", "a1", "u2", "a2"])

        append(.user, "u3", to: c)
        XCTAssertTrue(c.isThreaded)
        XCTAssertEqual(texts(c), ["u1", "a1", "u2", "a2", "u3"])
    }

    func testRegeneratedReplyIsASiblingAndCanBeSwitched() throws {
        let c = newConversation()
        let u1 = append(.user, "u1", to: c)
        let a1 = append(.assistant, "a1", to: c)

        // Regenerate: back up to the user message and reply again.
        c.activeLeafID = u1.id
        let a1b = append(.assistant, "a1b", to: c)
        XCTAssertEqual(a1b.parentID, u1.id)
        XCTAssertEqual(texts(c), ["u1", "a1b"])

        let index = BranchIndex(c)
        XCTAssertEqual(index.position(of: a1b)?.index, 1)
        XCTAssertEqual(index.position(of: a1b)?.count, 2)
        XCTAssertEqual(index.position(of: a1b)?.previous?.id, a1.id)
        XCTAssertNil(index.position(of: u1))

        c.showBranch(through: a1)
        XCTAssertEqual(texts(c), ["u1", "a1"])
    }

    func testEditedMessageKeepsBothBranchesAndFollowsNewestLeaf() throws {
        let c = newConversation()
        let u1 = append(.user, "u1", to: c)
        append(.assistant, "a1", to: c)
        let u2 = append(.user, "u2", to: c)
        append(.assistant, "a2", to: c)

        let edited = Message(role: .user, text: "u2 edited")
        c.attach(edited, under: u2.parentID)
        context.insert(edited)
        append(.assistant, "a2 edited", to: c)
        XCTAssertEqual(texts(c), ["u1", "a1", "u2 edited", "a2 edited"])

        c.showBranch(through: u2)
        XCTAssertEqual(texts(c), ["u1", "a1", "u2", "a2"])

        // Switching at the top follows each branch's newest replies to the end.
        c.showBranch(through: u1)
        XCTAssertEqual(texts(c), ["u1", "a1", "u2 edited", "a2 edited"])
    }

    func testDeleteBranchRemovesDescendantsAndMovesLeaf() throws {
        let c = newConversation()
        let u1 = append(.user, "u1", to: c)
        let a1 = append(.assistant, "a1", to: c)
        append(.user, "u2", to: c)
        append(.assistant, "a2", to: c)

        c.deleteBranch(from: a1, in: context)
        try context.save()
        XCTAssertEqual(c.activeLeafID, u1.id)
        XCTAssertEqual(texts(c), ["u1"])
        XCTAssertEqual(c.messages.count, 1)
    }

    func testSnippetCentersOnMatch() {
        let text = String(repeating: "lorem ", count: 20) + "the Schwarzschild radius\nis tiny " + String(repeating: "ipsum ", count: 30)
        let s = ChatSearch.snippet(of: text, around: "schwarzschild")
        XCTAssertTrue(s.hasPrefix("…"))
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertTrue(s.localizedCaseInsensitiveContains("Schwarzschild radius is tiny"))
        XCTAssertFalse(s.contains("\n"))
    }

    func testPinOrderPutsOrderedPinsFirst() {
        let old = Conversation(modelID: "m"); old.isPinned = true; old.updatedAt = .now
        let first = Conversation(modelID: "m"); first.isPinned = true; first.pinOrder = 0
        let second = Conversation(modelID: "m"); second.isPinned = true; second.pinOrder = 1
        let sorted = AppModel.pinOrdered([old, second, first])
        XCTAssertEqual(sorted.map(\.id), [first.id, second.id, old.id])
    }
}
