#if os(macOS)
import AppKit
import SwiftUI

/// Chrome's tab, live beside the chat. The model drives it through its tools; the user can click,
/// scroll and type in it directly (to sign in somewhere, say).
struct BrowserPanel: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    private let chrome = ChromeSession.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ZStack {
                Theme.background
                if let frame = chrome.frame, chrome.status == .ready {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay { BrowserInputLayer(viewport: chrome.viewport) }
                } else {
                    placeholder
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { chrome.fit(to: $0) }
        }
        .background(Theme.background)
        .onAppear { address = chrome.url }
        .onChange(of: chrome.url) { _, url in address = url }
        .task { if chrome.status == .stopped { try? await chrome.start() } }
        .task(id: chrome.status) {
            // Waiting for the user to start Chrome: connect as soon as it's up.
            while chrome.status == .needsLaunch, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try? await chrome.start()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            button("chevron.left", label: "Back") { chrome.goBack() }
            button("chevron.right", label: "Forward") { chrome.goForward() }
            button("arrow.clockwise", label: "Reload") { chrome.reload() }
            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                .font(.footnote)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.fill, in: Capsule())
                .onSubmit { Task { try? await chrome.open(address) } }
            Menu {
                Button("Quit Chrome") { chrome.quit() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            button("xmark", label: "Hide browser") {
                withAnimation(Motion.smooth) { app.browserVisible = false }
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(chrome.status != .ready && symbol != "xmark")
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 12) {
            switch chrome.status {
            case .starting, .ready:
                Spinner(size: 18)
                Text("Starting Chrome…").font(.subheadline).foregroundStyle(Theme.textSecondary)
            case .needsLaunch:
                Image(systemName: "terminal").font(.title2).foregroundStyle(Theme.textSecondary)
                Text("Start Halo's Chrome")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Run this in Terminal once. It opens Chrome without a window, under its own profile, and this panel connects by itself.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Text(ChromeSession.launchCommand)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Copy command") {
                    Clipboard.copy(ChromeSession.launchCommand)
                    app.showToast("Copied")
                }
                .buttonStyle(.haloGlass)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(Theme.textSecondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { try? await chrome.start() } }
                    .buttonStyle(.haloGlass)
            case .stopped:
                Image(systemName: "macwindow").font(.title2).foregroundStyle(Theme.textSecondary)
                Text("Chrome isn't running").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Button("Start Chrome") { Task { try? await chrome.start() } }
                    .buttonStyle(.haloGlass)
            }
        }
        .padding(24)
    }
}

/// Passes the user's mouse and keys over the frame through to the page, in its CSS pixels.
private struct BrowserInputLayer: NSViewRepresentable {
    let viewport: CGSize

    func makeNSView(context: Context) -> BrowserInputView { BrowserInputView() }

    func updateNSView(_ view: BrowserInputView, context: Context) { view.viewport = viewport }
}

final class BrowserInputView: NSView {
    var viewport: CGSize = .zero
    private var chrome: ChromeSession { ChromeSession.shared }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: p.x / bounds.width * viewport.width, y: p.y / bounds.height * viewport.height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        chrome.userMouse("mousePressed", at: pagePoint(event), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        chrome.userMouse("mouseMoved", at: pagePoint(event), pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        chrome.userMouse("mouseReleased", at: pagePoint(event), clickCount: event.clickCount)
    }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report points; a mouse wheel reports lines, about 40 px each in Chrome.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
        chrome.userScroll(at: pagePoint(event), dx: -event.scrollingDeltaX * scale, dy: -event.scrollingDeltaY * scale)
    }

    override func keyDown(with event: NSEvent) {
        chrome.userKey(event)
    }

    /// ⌘V and ⌘A go to the page rather than the app's menus while the page has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
              ["v", "a"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else {
            return super.performKeyEquivalent(with: event)
        }
        chrome.userKey(event)
        return true
    }
}

/// Asks before the model clicks, types or presses a key in Chrome; the target is outlined in the panel.
struct BrowserApprovalPopup: View {
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine

    private static let gated = Set([ToolName.browserClick, .browserType, .browserPress].map(\.rawValue))

    private var pending: [Message] {
        conversation.orderedMessages.filter {
            guard let state = $0.toolState else { return false }
            return Self.gated.contains(state.name) && state.status == .awaitingApproval
        }
    }

    var body: some View {
        let waiting = pending
        Group {
            if let message = waiting.first, let params = message.toolState?.approval {
                card(message, params: params, more: waiting.count - 1)
                    .id(message.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: waiting.map(\.id))
    }

    private func card(_ message: Message, params: ApprovalParams, more: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: ToolMessageView.icon(for: message.toolState?.name ?? ""))
                    .foregroundStyle(Theme.textSecondary)
                Text("Let the model do this in Chrome?").font(.subheadline.weight(.semibold))
                Spacer()
                if more > 0 {
                    Text("+\(more) more").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Text(params.prompt)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 8) {
                Button {
                    ChromeSession.shared.clearHighlight()
                    engine.resolveApproval(message, approve: false, params: params, in: conversation)
                } label: {
                    // Drawn like Allow, so the pair reads as one choice (the glass style drew a small square).
                    Text("Deny")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Theme.fillStrong, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button {
                    engine.resolveApproval(message, approve: true, params: params, in: conversation)
                } label: {
                    Text("Allow")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 12)
    }
}
#endif
