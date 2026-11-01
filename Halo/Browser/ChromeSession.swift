#if os(macOS)
import AppKit
import Observation

/// Real Chrome, run without a window of its own under a separate Halo profile and driven over the
/// DevTools protocol. Its tab streams into Halo's browser panel, where the user can use it too.
@MainActor
@Observable
final class ChromeSession {
    static let shared = ChromeSession()

    enum Status: Equatable {
        case stopped, starting, ready
        /// Halo is sandboxed and can't start Chrome with the flags it needs; the user runs `launchCommand`.
        case needsLaunch
        case failed(String)
    }

    /// One of the page's interactive elements, numbered for the model in the latest read.
    struct Element {
        let id: Int
        let role: String
        let label: String
    }

    private(set) var status: Status = .stopped
    /// The latest frame of the tab, as Chrome streams it.
    private(set) var frame: NSImage?
    /// The page's size in CSS pixels; mouse coordinates are in these.
    private(set) var viewport = CGSize(width: 1280, height: 860)
    private(set) var url = ""
    private(set) var title = ""
    /// Elements from the latest read, by id, so approvals can say what a click will hit.
    private(set) var elements: [Int: Element] = [:]

    private static let port = 9333
    private static let size = CGSize(width: 1280, height: 860)

    /// The page size the panel wants, in CSS pixels.
    @ObservationIgnored private var pageSize = ChromeSession.size
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var launched: NSRunningApplication?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// The user's clicks and keys from the panel, sent one after another in order.
    @ObservationIgnored private var inputChain: Task<Void, Never>?

    enum ChromeError: LocalizedError {
        case notInstalled, noResponse, notRunning, needsLaunch, timedOut(String), protocolError(String), noElement(Int)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Google Chrome isn't installed."
            case .noResponse: return "Chrome started but didn't answer. Quit any Chrome started with --remote-debugging-port=\(ChromeSession.port) and try again."
            case .notRunning: return "Chrome isn't running."
            case .needsLaunch: return "Halo's Chrome isn't running. Ask the user to start it from the browser panel (it shows a command to run), then try again."
            case .timedOut(let method): return "Chrome didn't answer \(method) in time."
            case .protocolError(let message): return message
            case .noElement(let id): return "There's no element [\(id)] on the page any more. Read the page again for fresh ids."
            }
        }
    }

    // MARK: - Starting and stopping

    /// Starts Chrome (or reconnects to the one Halo started before) and begins streaming its tab.
    func start() async throws {
        if status == .ready, socket != nil { return }
        status = .starting
        do {
            if await Self.fetchJSON("/json/version") == nil {
                guard !Self.isSandboxed else {
                    status = .needsLaunch
                    throw ChromeError.needsLaunch
                }
                try await launchChrome()
            }
            var page: URL?
            for _ in 0..<60 {
                page = await pageSocketURL()
                if page != nil { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let page else { throw ChromeError.noResponse }
            connect(page)
            try await send("Page.enable")
            try await applySize()
            status = .ready
            await refreshLocation()
        } catch ChromeError.needsLaunch {
            throw ChromeError.needsLaunch
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Closes Halo's Chrome.
    func quit() {
        if let launched {
            // Headless Chrome doesn't answer the usual quit request; SIGTERM shuts it down cleanly.
            kill(launched.processIdentifier, SIGTERM)
        } else {
            // Started by the user with `launchCommand`: ask it to close over the browser's own socket.
            Task {
                guard let version = await Self.fetchJSON("/json/version") as? [String: Any],
                      let address = (version["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { return }
                let browser = URLSession.shared.webSocketTask(with: address)
                browser.resume()
                try? await browser.send(.string(#"{"id":1,"method":"Browser.close"}"#))
                try? await Task.sleep(nanoseconds: 500_000_000)
                browser.cancel(with: .goingAway, reason: nil)
            }
        }
        launched = nil
        disconnect()
        status = .stopped
        frame = nil
    }

    /// Closes Chrome only if Halo started it (Halo is quitting; one the user started is theirs).
    func quitIfLaunched() {
        guard launched != nil else { return }
        quit()
    }

    /// macOS drops the arguments of apps a sandboxed app opens, so a sandboxed Halo can't start Chrome itself.
    private static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// What starts Halo's Chrome from Terminal: headless, with its own profile and the DevTools port.
    static var launchCommand: String {
        "open -na \"Google Chrome\" --args " + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    private static var arguments: [String] {
        ["--remote-debugging-port=\(port)", "--user-data-dir=\(profilePath)", "--headless=new",
         "--window-size=\(Int(size.width)),\(Int(size.height))", "--no-first-run", "--no-default-browser-check", "about:blank"]
    }

    private func launchChrome() async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { throw ChromeError.notInstalled }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = Self.arguments
        // A second Chrome next to the user's own, with its own profile.
        config.createsNewApplicationInstance = true
        config.activates = false
        config.addsToRecentItems = false
        launched = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
    }

    /// Outside Halo's sandbox container: Chrome isn't sandboxed, and macOS asks before one app
    /// touches another's container.
    private static var profilePath: String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Application Support/Halo/Chrome"
    }

    private static func fetchJSON(_ path: String, method: String = "GET") async -> Any? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = method
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The first tab's DevTools socket, opening a tab when there is none.
    private func pageSocketURL() async -> URL? {
        guard let targets = await Self.fetchJSON("/json/list") as? [[String: Any]] else { return nil }
        var page = targets.first { $0["type"] as? String == "page" }
        if page == nil { page = await Self.fetchJSON("/json/new?about:blank", method: "PUT") as? [String: Any] }
        return (page?["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:))
    }

    // MARK: - Protocol

    private func connect(_ url: URL) {
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        socket = task
        task.resume()
        receive(task)
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: ChromeError.notRunning) }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(.string(let text)):
                    if let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(object)
                    }
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    // Chrome quit or crashed.
                    self.disconnect()
                    self.status = .stopped
                }
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int, let waiter = pending.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                waiter.resume(throwing: ChromeError.protocolError(error["message"] as? String ?? "Chrome reported an error."))
            } else {
                waiter.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { return }
        switch method {
        case "Page.screencastFrame":
            if let session = params["sessionId"] as? Int {
                Task { try? await send("Page.screencastFrameAck", ["sessionId": session]) }
            }
            if let encoded = params["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                frame = image
            }
            if let meta = params["metadata"] as? [String: Any],
               let width = meta["deviceWidth"] as? Double, let height = meta["deviceHeight"] as? Double, width > 0, height > 0 {
                viewport = CGSize(width: width, height: height)
            }
        case "Page.frameNavigated":
            if let info = params["frame"] as? [String: Any], info["parentId"] == nil, let address = info["url"] as? String {
                url = address
            }
        case "Page.loadEventFired", "Page.navigatedWithinDocument":
            Task { await refreshLocation() }
        default:
            break
        }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let socket else { throw ChromeError.notRunning }
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        // A hung page shouldn't hang the chat with it.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.pending.removeValue(forKey: id)?.resume(throwing: ChromeError.timedOut(method))
        }
        return try await withCheckedThrowingContinuation { waiter in
            pending[id] = waiter
            socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
    }

    private func evaluate(_ expression: String) async throws -> Any? {
        let result = try await send("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let text = (details["exception"] as? [String: Any])?["description"] as? String ?? details["text"] as? String
            throw ChromeError.protocolError(text ?? "The page's script failed.")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func refreshLocation() async {
        if let info = try? await evaluate("JSON.stringify([location.href, document.title])") as? String,
           let pair = try? JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String], pair.count == 2 {
            url = pair[0]
            title = pair[1]
        }
    }

    /// Waits until the page has loaded (or 15 s pass), then a moment more for scripts to draw.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<60 {
            if (try? await evaluate("document.readyState")) as? String == "complete" { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        await refreshLocation()
    }

    /// Fits the page to the panel: its size in points, never narrower than 600 CSS px (narrower,
    /// and sites switch to their phone layouts), drawn at 2× so text stays sharp.
    func fit(to panel: CGSize) {
        guard panel.width > 50, panel.height > 50 else { return }
        let scale = max(1, 600 / panel.width)
        let size = CGSize(width: (panel.width * scale).rounded(), height: (panel.height * scale).rounded())
        guard size != pageSize else { return }
        pageSize = size
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, status == .ready else { return }
            try? await applySize()
        }
    }

    private func applySize() async throws {
        let width = Int(pageSize.width), height = Int(pageSize.height)
        try await send("Emulation.setDeviceMetricsOverride", ["width": width, "height": height, "deviceScaleFactor": 2, "mobile": false])
        try? await send("Page.stopScreencast")
        try await send("Page.startScreencast", ["format": "jpeg", "quality": 80, "maxWidth": width * 2, "maxHeight": height * 2])
    }

    // MARK: - What the model does

    func open(_ address: String) async throws {
        try await start()
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.contains("://") || trimmed.hasPrefix("about:") ? trimmed : "https://" + trimmed
        try await send("Page.navigate", ["url": target])
        await settle()
    }

    /// The page as the model sees it: where it is, its interactive elements numbered for
    /// clicking and typing, and its text.
    func read(textLimit: Int = 8000) async throws -> String {
        try await start()
        guard let json = try await evaluate(Self.readScript) as? String,
              let page = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ChromeError.protocolError("Couldn't read the page.")
        }
        let found = (page["elements"] as? [[String: Any]] ?? []).compactMap { e -> (Element, Bool)? in
            guard let id = e["id"] as? Int else { return nil }
            return (Element(id: id, role: e["role"] as? String ?? "element", label: e["label"] as? String ?? ""), e["onScreen"] as? Bool ?? true)
        }
        elements = Dictionary(found.map { ($0.0.id, $0.0) }, uniquingKeysWith: { a, _ in a })
        url = page["url"] as? String ?? url
        title = page["title"] as? String ?? title
        var lines = ["Page: \(title)", "URL: \(url)"]
        if let y = page["scrollY"] as? Int, let height = page["height"] as? Int, let view = page["viewport"] as? Int, height > view {
            lines.append("Scrolled to \(y) of \(height - view) px")
        }
        if found.isEmpty {
            lines.append("No interactive elements in view.")
        } else {
            lines.append("Interactive elements (ids for browser_click / browser_type; they change after every read):")
            for (element, onScreen) in found {
                let label = element.label.isEmpty ? "" : " \"\(element.label)\""
                lines.append("[\(element.id)] \(element.role)\(label)\(onScreen ? "" : " (off screen)")")
            }
        }
        let text = String((page["text"] as? String ?? "").prefix(textLimit))
        lines.append("Page text:\n\(text)")
        return lines.joined(separator: "\n")
    }

    /// Numbers the visible interactive elements (`data-halo-id`) and reports them with the page text.
    /// Password fields never report what's in them.
    private static let readScript = """
    (() => {
      document.querySelectorAll('[data-halo-id]').forEach(e => e.removeAttribute('data-halo-id'));
      const sel = 'a[href], button, input:not([type=hidden]), textarea, select, summary, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=radio], [role=switch], [role=textbox], [role=combobox], [contenteditable=""], [contenteditable=true]';
      const out = [];
      let n = 0;
      for (const e of document.querySelectorAll(sel)) {
        const r = e.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) continue;
        const st = getComputedStyle(e);
        if (st.visibility === 'hidden' || st.display === 'none' || st.opacity === '0') continue;
        if (r.bottom < -innerHeight || r.top > innerHeight * 2) continue;
        n += 1;
        e.setAttribute('data-halo-id', n);
        const tag = e.tagName.toLowerCase();
        const type = (e.getAttribute('type') || 'text').toLowerCase();
        const role = e.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? type + ' field' : tag === 'textarea' ? 'text area' : tag);
        const value = type === 'password' ? '' : (e.value || '');
        const label = (e.getAttribute('aria-label') || e.innerText || value || e.placeholder || e.title || e.name || e.alt || '')
          .trim().replace(/\\s+/g, ' ').slice(0, 80);
        out.push({ id: n, role, label, onScreen: r.top < innerHeight && r.bottom > 0 });
        if (n >= 150) break;
      }
      const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
      return JSON.stringify({ url: location.href, title: document.title, text, elements: out,
        scrollY: Math.round(scrollY), height: document.documentElement.scrollHeight, viewport: innerHeight });
    })()
    """

    /// The middle of element `id`, scrolled into view first.
    private func center(of id: Int) async throws -> CGPoint {
        let script = """
        (() => {
          const e = document.querySelector('[data-halo-id="\(id)"]');
          if (!e) return null;
          e.scrollIntoView({ block: 'center', inline: 'center' });
          const r = e.getBoundingClientRect();
          return JSON.stringify([r.left + r.width / 2, r.top + r.height / 2]);
        })()
        """
        guard let json = try await evaluate(script) as? String,
              let point = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Double], point.count == 2 else {
            throw ChromeError.noElement(id)
        }
        return CGPoint(x: point[0], y: point[1])
    }

    func click(element id: Int) async throws {
        try await start()
        clearHighlight()
        try await click(at: try await center(of: id))
        await settle()
    }

    private func click(at point: CGPoint, count: Int = 1) async throws {
        try await send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y])
        try await send("Input.dispatchMouseEvent", ["type": "mousePressed", "x": point.x, "y": point.y, "button": "left", "clickCount": count])
        try await send("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": point.x, "y": point.y, "button": "left", "clickCount": count])
    }

    /// Types into element `id` (clicked first, its current text replaced), or wherever focus is.
    func type(_ text: String, into id: Int?, submit: Bool) async throws {
        try await start()
        clearHighlight()
        if let id {
            try await click(at: try await center(of: id))
            _ = try? await evaluate("(e => { if (e && e.select) e.select(); })(document.querySelector('[data-halo-id=\"\(id)\"]'))")
        }
        try await send("Input.insertText", ["text": text])
        if submit { try await press("Enter") }
        await settle()
    }

    static let keys: [String: (code: Int, text: String?)] = [
        "Enter": (13, "\r"), "Tab": (9, nil), "Escape": (27, nil), "Backspace": (8, nil), "Delete": (46, nil),
        "ArrowUp": (38, nil), "ArrowDown": (40, nil), "ArrowLeft": (37, nil), "ArrowRight": (39, nil),
        "PageUp": (33, nil), "PageDown": (34, nil), "Home": (36, nil), "End": (35, nil), "Space": (32, " "),
    ]

    func press(_ key: String, modifiers: Int = 0, commands: [String] = []) async throws {
        try await start()
        guard let info = Self.keys[key] else { throw ChromeError.protocolError("Unknown key \(key).") }
        let name = key == "Space" ? " " : key
        var down: [String: Any] = ["type": info.text == nil ? "rawKeyDown" : "keyDown", "key": name, "code": key,
                                   "windowsVirtualKeyCode": info.code, "modifiers": modifiers]
        if let text = info.text, modifiers == 0 { down["text"] = text }
        if !commands.isEmpty { down["commands"] = commands }
        try await send("Input.dispatchKeyEvent", down)
        try await send("Input.dispatchKeyEvent", ["type": "keyUp", "key": name, "code": key, "windowsVirtualKeyCode": info.code, "modifiers": modifiers])
    }

    func scroll(pages: Double) async throws {
        try await start()
        try await send("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": viewport.width / 2, "y": viewport.height / 2,
                                                    "deltaX": 0, "deltaY": pages * viewport.height * 0.85])
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Outlines element `id` while a click or typing on it waits for the user's OK.
    func highlight(element id: Int) {
        Task { _ = try? await evaluate("""
            (e => { document.querySelectorAll('[data-halo-mark]').forEach(m => { m.style.outline = m.dataset.haloMark; m.removeAttribute('data-halo-mark'); });
              if (!e) return; e.dataset.haloMark = e.style.outline; e.scrollIntoView({ block: 'center' });
              e.style.outline = '3px solid #f5a524'; e.style.outlineOffset = '2px'; })(document.querySelector('[data-halo-id="\(id)"]'))
            """) }
    }

    func clearHighlight() {
        Task { _ = try? await evaluate("document.querySelectorAll('[data-halo-mark]').forEach(m => { m.style.outline = m.dataset.haloMark; m.removeAttribute('data-halo-mark'); })") }
    }

    // MARK: - The user, in the panel

    func goBack() { navigateHistory(by: -1) }
    func goForward() { navigateHistory(by: 1) }
    func reload() { enqueue { try await self.send("Page.reload") } }

    private func navigateHistory(by step: Int) {
        enqueue {
            let history = try await self.send("Page.getNavigationHistory")
            guard let index = history["currentIndex"] as? Int, let entries = history["entries"] as? [[String: Any]],
                  entries.indices.contains(index + step), let id = entries[index + step]["id"] as? Int else { return }
            try await self.send("Page.navigateToHistoryEntry", ["entryId": id])
        }
    }

    func userMouse(_ type: String, at point: CGPoint, clickCount: Int = 1, pressed: Bool = false) {
        var params: [String: Any] = ["type": type, "x": point.x, "y": point.y]
        if type != "mouseMoved" { params["button"] = "left"; params["clickCount"] = clickCount }
        else if pressed { params["button"] = "left"; params["buttons"] = 1 }
        enqueue { try await self.send("Input.dispatchMouseEvent", params) }
    }

    func userScroll(at point: CGPoint, dx: Double, dy: Double) {
        enqueue { try await self.send("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": dx, "deltaY": dy]) }
    }

    /// Keys typed in the panel: text goes in as text, editing keys as keys, and ⌘V / ⌘A as paste and select all.
    func userKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) { enqueue { try await self.send("Input.insertText", ["text": text]) } }
            case "a":
                enqueue { try await self.press("Home", modifiers: 4, commands: ["selectAll"]) }
            default:
                break
            }
            return
        }
        let special: [UInt16: String] = [36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Escape",
                                         123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
                                         116: "PageUp", 121: "PageDown", 115: "Home", 119: "End"]
        if let key = special[event.keyCode] {
            let modifiers = flags.contains(.shift) ? 8 : 0
            enqueue { try await self.press(key, modifiers: modifiers) }
        } else if let text = event.characters, !text.isEmpty {
            enqueue { try await self.send("Input.insertText", ["text": text]) }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) {
        let previous = inputChain
        inputChain = Task {
            await previous?.value
            try? await work()
        }
    }
}
#endif
