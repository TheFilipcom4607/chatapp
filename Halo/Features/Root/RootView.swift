import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AccountStore.self) private var account
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if app.hasAPIKey {
                MainView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
            if let toast = app.toast {
                VStack {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .glassCapsule(interactive: false)
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
            if lock.isLocked {
                // Covers the first frames at launch, before the lock's own window is up.
                LockScreenView(lock: lock)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .animation(Motion.smooth, value: app.hasAPIKey)
        .alert("Saved chats couldn't be opened", isPresented: Binding(get: { app.storeProblem != nil }, set: { if !$0 { app.storeProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.storeProblem ?? "")
        }
        .task {
            PythonRuntime.shared.attachIfNeeded()
            await catalog.refreshIfNeeded()
            await account.refresh()
        }
    }
}

/// Chat area + swipe-in sidebar (ChatGPT style: the chat slides right to reveal the list).
struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// Whether the swipe that started at `start` belongs to a code block or scrubber, decided on its
    /// first move. Cleared when the swipe ends, and keyed by the start point in case it never does.
    @State private var swipeClaim: (start: CGPoint, claimed: Bool)?

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            let width = min(geo.size.width * 0.84, 360)
            let base: CGFloat = app.sidebarOpen ? width : 0
            let offset = min(max(base + dragOffset, 0), width)
            let progress = offset / width

            ZStack(alignment: .leading) {
                SidebarView()
                    .frame(width: width)
                    .offset(x: -width * 0.25 * (1 - progress))
                    .opacity(0.4 + 0.6 * progress)

                ChatContainer()
                    .frame(width: geo.size.width)
                    // Masks that reach into the safe areas: a clipShape stops at them and cut the
                    // chat off under the status bar and above the home indicator.
                    .mask {
                        RoundedRectangle(cornerRadius: 34 * progress, style: .continuous).ignoresSafeArea()
                    }
                    .overlay {
                        if progress > 0 {
                            RoundedRectangle(cornerRadius: 34 * progress, style: .continuous)
                                .fill(Color.black.opacity(0.35 * progress))
                                .ignoresSafeArea()
                                .onTapGesture { withAnimation(Motion.smooth) { app.sidebarOpen = false } }
                        }
                    }
                    .scaleEffect(1 - 0.04 * progress, anchor: .leading)
                    .offset(x: offset)
                    .allowsHitTesting(!app.sidebarOpen || isDragging)
                    .overlay(alignment: .leading) {
                        if app.sidebarOpen {
                            Color.clear.contentShape(Rectangle())
                                .frame(width: geo.size.width)
                                .offset(x: offset)
                                .onTapGesture { withAnimation(Motion.smooth) { app.sidebarOpen = false } }
                        }
                    }
            }
            .simultaneousGesture(
                // Global coordinates, so the start point can be hit-tested in the window.
                DragGesture(minimumDistance: 18, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.4 else { return }
                        if !isDragging {
                            // Open: swipe right anywhere on the chat. Close: drag the chat preview (not
                            // the list, so row swipe actions keep working).
                            if !app.sidebarOpen && dx <= 0 { return }
                            if app.sidebarOpen && value.startLocation.x < width - 8 { return }
                            // A code block scrolled sideways scrolls back, and a scrubber scrubs.
                            if !app.sidebarOpen {
                                if swipeClaim?.start != value.startLocation {
                                    swipeClaim = (value.startLocation, SidebarSwipe.isClaimed(at: value.startLocation))
                                }
                                if swipeClaim?.claimed == true { return }
                            }
                        }
                        // Before the chat stops taking touches: after that its field can't give up focus.
                        if !isDragging && !app.sidebarOpen { Keyboard.dismiss() }
                        isDragging = true
                        dragOffset = dx
                    }
                    .onEnded { value in
                        swipeClaim = nil
                        guard isDragging else { return }
                        let predicted = value.predictedEndTranslation.width
                        withAnimation(Motion.smooth) {
                            if app.sidebarOpen { app.sidebarOpen = !(predicted < -width * 0.3) }
                            else { app.sidebarOpen = predicted > width * 0.35 }
                            dragOffset = 0
                        }
                        isDragging = false
                        Haptics.selection()
                    }
            )
        }
        .sheet(item: $app.sheet) { route in
            // A sheet doesn't pick up the app's toggle style, only its tint.
            SheetHost(route: route).toggleStyle(HaloSwitchStyle())
        }
        .fullScreenCover(item: $app.fullScreenArtifact) { route in
            if case let .artifact(id, version) = route {
                ArtifactCanvasView(artifactID: id, initialVersion: version)
            }
        }
        .fullScreenCover(item: $app.viewingImage) { item in
            ImageViewer(item: item)
        }
    }
}

/// Lets content keep a rightward swipe that would otherwise open the sidebar.
@MainActor
enum SidebarSwipe {
    /// Set by a control that drags sideways itself (the audio scrubber) while its finger is down.
    static var isHeld = false

    /// True when the swipe belongs to something else: a held control, or a sideways scroller under
    /// `point` (window coordinates) that is away from its left edge. At the edge (or bouncing past
    /// it) the swipe opens the sidebar, as a back swipe would. Ask once per swipe: a scroller the
    /// swipe brings back to its edge shouldn't hand the rest of that swipe to the sidebar.
    static func isClaimed(at point: CGPoint) -> Bool {
        if isHeld { return true }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var view = window?.hitTest(point, with: nil)
        while let v = view {
            if let scroll = v as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                return scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1
            }
            view = v.superview
        }
        return false
    }
}

struct ChatContainer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ChatScreen(conversation: app.currentConversation)
                .id(app.currentConversationID)
        }
    }
}

struct SheetHost: View {
    let route: SheetRoute

    var body: some View {
        switch route {
        case .settings: SettingsView()
        case .modelPicker: ModelBrowserView()
        case .spend: SpendDashboardView()
        case .personaEditor(let id): PersonaEditorView(personaID: id)
        case .details(let id): MessageDetailsView(messageID: id)
        case .preview(let lang, let code): CodePreviewSheet(language: lang, code: code)
        case .run(let lang, let code): CodeRunSheet(language: lang, code: code)
        case .artifact(let id, let v): ArtifactCanvasView(artifactID: id, initialVersion: v)
        case .archived: ArchivedChatsView()
        case .selectText(let text): SelectTextSheet(text: text)
        case .sources(let list): SourcesSheet(citations: list)
        }
    }
}
