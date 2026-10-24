import XCTest
import SwiftData
@testable import Halo

@MainActor
final class IntentTests: XCTestCase {
    private func chat(_ build: (Conversation, ModelContext) -> Void) throws -> Conversation {
        let container = try ModelContainer(for: Conversation.self, Message.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let c = Conversation(modelID: "m")
        c.title = "Plans"
        container.mainContext.insert(c)
        build(c, container.mainContext)
        addTeardownBlock { _ = container }
        return c
    }

    private func add(_ role: MessageRole, _ text: String, to c: Conversation, in context: ModelContext,
                     status: MessageStatus = .complete, tool: ToolStatus? = nil) {
        let m = Message(role: role, text: text, status: status)
        if let tool { m.toolState = ToolState(name: "create_event", arguments: "{}", status: tool) }
        c.append(m)
        context.insert(m)
    }

    func testAnswerJoinsTheTurnsReplies() throws {
        let c = try chat { c, ctx in
            add(.user, "old", to: c, in: ctx)
            add(.assistant, "old answer", to: c, in: ctx)
            add(.user, "Weather?", to: c, in: ctx)
            add(.assistant, "Checking.", to: c, in: ctx)
            add(.tool, "12°", to: c, in: ctx, tool: .done)
            add(.assistant, "It's 12° and cloudy.", to: c, in: ctx)
        }
        XCTAssertEqual(AskHaloIntent.answer(in: c), "Checking.\n\nIt's 12° and cloudy.")
    }

    func testAnswerAsksToOpenHaloForApprovals() throws {
        let c = try chat { c, ctx in
            add(.user, "Add lunch", to: c, in: ctx)
            add(.assistant, "Here it is:", to: c, in: ctx)
            add(.tool, "", to: c, in: ctx, tool: .awaitingApproval)
        }
        XCTAssertEqual(AskHaloIntent.answer(in: c), "Open Halo to approve the request in \"Plans\".")
    }

    func testAnswerPassesOnAFailure() throws {
        let c = try chat { c, ctx in
            add(.user, "Hi", to: c, in: ctx)
            let failed = Message(role: .assistant, status: .failed)
            failed.errorText = "Your OpenRouter key was rejected."
            c.append(failed)
            ctx.insert(failed)
        }
        XCTAssertEqual(AskHaloIntent.answer(in: c), "Your OpenRouter key was rejected.")
    }
}
