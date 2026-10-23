import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AccountStore.self) private var account

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
        }
        .animation(Motion.smooth, value: app.hasAPIKey)
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
                    .clipShape(RoundedRectangle(cornerRadius: progress > 0 ? 34 * progress : 0, style: .continuous))
                    .overlay {
                        if progress > 0 {
                            Color.black.opacity(0.35 * progress)
                                .clipShape(RoundedRectangle(cornerRadius: 34 * progress, style: .continuous))
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
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.4 else { return }
                        if !app.sidebarOpen && value.startLocation.x > 44 && !isDragging { return }
                        isDragging = true
                        dragOffset = dx
                    }
                    .onEnded { value in
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
        .ignoresSafeArea(.keyboard)
        .sheet(item: $app.sheet) { route in
            SheetHost(route: route)
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
        }
    }
}
