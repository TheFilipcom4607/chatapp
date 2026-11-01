#if os(macOS)
import Foundation

/// The model's Chrome tools. Opening, reading and scrolling run at once; clicks, typing and keys
/// run only after the user approves the line `describe` writes for them.
@MainActor
enum BrowserTools {
    static func run(_ name: ToolName, args: JSONValue) async -> ToolOutcome {
        let chrome = ChromeSession.shared
        AppModel.shared.browserVisible = true
        do {
            switch name {
            case .browserOpen:
                let address = args["url"]?.stringValue ?? ""
                guard !address.isEmpty else { return .failure("No URL given.", summary: "No URL") }
                try await chrome.open(address)
                return ToolOutcome(text: try await chrome.read(), summary: "Opened \(host(chrome.url))")
            case .browserRead:
                return ToolOutcome(text: try await chrome.read(), summary: "Read \(host(chrome.url))")
            case .browserScroll:
                let up = args["direction"]?.stringValue == "up"
                let pages = max(0.25, min(10, args["pages"]?.doubleValue ?? 1))
                try await chrome.scroll(pages: up ? -pages : pages)
                return ToolOutcome(text: try await chrome.read(), summary: up ? "Scrolled up" : "Scrolled down")
            case .browserClick:
                guard let id = args["element_id"]?.intValue else { return .failure("No element_id given.", summary: "No element") }
                let target = label(of: id)
                try await chrome.click(element: id)
                return ToolOutcome(text: try await chrome.read(textLimit: 4000), summary: "Clicked \(target)")
            case .browserType:
                let text = args["text"]?.stringValue ?? ""
                let id = args["element_id"]?.intValue
                try await chrome.type(text, into: id, submit: args["submit"]?.boolValue == true)
                return ToolOutcome(text: try await chrome.read(textLimit: 4000), summary: id.map { "Typed into \(label(of: $0))" } ?? "Typed")
            case .browserPress:
                let key = args["key"]?.stringValue ?? "Enter"
                try await chrome.press(key)
                try? await Task.sleep(nanoseconds: 600_000_000)
                return ToolOutcome(text: try await chrome.read(textLimit: 4000), summary: "Pressed \(key)")
            default:
                return .failure("Not a Chrome tool.")
            }
        } catch {
            return .failure("Chrome: \(error.localizedDescription)", summary: "Chrome failed")
        }
    }

    /// What the user is asked to approve, e.g. Click button "Sign in" on github.com.
    static func describe(_ name: ToolName, args: JSONValue) -> String {
        let site = ChromeSession.shared.url.isEmpty ? "" : " on \(host(ChromeSession.shared.url))"
        switch name {
        case .browserClick:
            return "Click \(args["element_id"]?.intValue.map(label(of:)) ?? "an element")\(site)"
        case .browserType:
            let text = args["text"]?.stringValue ?? ""
            let into = args["element_id"]?.intValue.map { " into \(label(of: $0))" } ?? ""
            let submit = args["submit"]?.boolValue == true ? ", then press Enter" : ""
            return "Type \u{201C}\(text)\u{201D}\(into)\(site)\(submit)"
        case .browserPress:
            return "Press \(args["key"]?.stringValue ?? "Enter")\(site)"
        default:
            return name.displayName
        }
    }

    /// Outlines the element a waiting click or typing will use, so the user can see it in the panel.
    static func highlightTarget(args: JSONValue) {
        if let id = args["element_id"]?.intValue { ChromeSession.shared.highlight(element: id) }
    }

    /// An element as the user and model saw it: link "Sign in", or [7] when it wasn't in the last read.
    private static func label(of id: Int) -> String {
        guard let element = ChromeSession.shared.elements[id] else { return "[\(id)]" }
        return element.label.isEmpty ? element.role : "\(element.role) \u{201C}\(element.label)\u{201D}"
    }

    private static func host(_ address: String) -> String {
        URL(string: address)?.host() ?? (address.isEmpty ? "the page" : address)
    }
}
#endif
