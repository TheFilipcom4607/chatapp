import XCTest
import SwiftData
@testable import Halo

@MainActor
final class ChatImportTests: XCTestCase {
    private let sample = """
    # do i remember correctly that there is a

    **User - --**

    do i remember correctly that there is a ds cart that has an rp2350 in it?

    **Assistant - --**

    Yes! You are thinking of the **DSpico**.

    ---

    ### 1. Is it more powerful?

    ```c
    // a header-looking line inside code stays in the reply
    **User - --**
    ```

    **User - --**

    so what is a middle ground chip?

    **Assistant - anthropic/claude-sonnet-5.5**

    The **ESP32-P4**.
    """

    func testParsesOpenRouterExport() throws {
        let chat = try XCTUnwrap(OpenRouterChatImport.parse(sample))
        XCTAssertEqual(chat.title, "do i remember correctly that there is a")
        XCTAssertEqual(chat.turns.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(chat.turns[0].text, "do i remember correctly that there is a ds cart that has an rp2350 in it?")
        XCTAssertTrue(chat.turns[1].text.hasPrefix("Yes! You are thinking of the **DSpico**."))
        XCTAssertTrue(chat.turns[1].text.contains("**User - --**\n```"))
        XCTAssertTrue(chat.turns[1].text.contains("### 1. Is it more powerful?"))
        XCTAssertNil(chat.turns[1].model)
        XCTAssertEqual(chat.turns[3].model, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(chat.turns[3].text, "The **ESP32-P4**.")
    }

    func testRejectsOtherMarkdown() {
        XCTAssertNil(OpenRouterChatImport.parse("# Notes\n\nJust a document, **bold** text."))
    }

    func testHandlesWindowsLineEndings() throws {
        let chat = try XCTUnwrap(OpenRouterChatImport.parse("**User - --**\r\n\r\nhi\r\n\r\n**Assistant - --**\r\n\r\nhello\r\n"))
        XCTAssertEqual(chat.turns.map(\.text), ["hi", "hello"])
    }
}
