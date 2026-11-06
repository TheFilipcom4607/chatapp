import SwiftUI
import UserNotifications
import AVFoundation

final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Completion handlers rather than `async`: the async versions call iOS's handler from a background
    // thread, and UIKit asserts it's on the main one (tapping a notification crashed Halo).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .sound]) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            if let id { AppModel.shared.openConversation(id: id) }
            completionHandler()
        }
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        _ = AppModel.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundRunner.shared.systemCompletionHandler = completionHandler
        _ = AppModel.shared
        BackgroundRunner.shared.activate()
    }
}
#else
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One window; the tab bar items in the View menu would only open empty copies.
        NSWindow.allowsAutomaticWindowTabbing = false
        UNUserNotificationCenter.current().delegate = self
        _ = AppModel.shared
        #if DEBUG
        MacSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChromeSession.shared.quitIfLaunched()
    }

    /// Closing the only window quits, like most single-window Mac apps.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

@main
struct HaloApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Self.root
                .onOpenURL { url in
                    // "Open in Halo" from Files or the share sheet: an OpenRouter chat export or a backup.
                    if url.isFileURL { AppModel.shared.importFile(url) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 780)
        // A real toolbar, so the sidebar toggle and the chat's controls sit level with the traffic
        // lights as in any Mac app; the chat's title stays out of it (it names the window menu).
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { HaloCommands() }
        #endif
        .onChange(of: scenePhase) { old, phase in
            let engine = AppModel.shared.engine
            AppModel.shared.lock.scenePhaseChanged(phase)
            switch phase {
            case .active:
                engine.appDidBecomeActive()
                AppModel.shared.drainShareInbox()
            case .inactive:
                // Leaving the screen (locking, going home): still in the foreground for a moment.
                if old == .active { engine.appWillResignActive() }
            case .background: engine.appDidEnterBackground()
            default: break
            }
        }
    }

    /// The window's content with everything it reads from the environment.
    @MainActor static var root: some View {
        RootView()
            .environment(AppModel.shared)
            .environment(AppModel.shared.settings)
            .environment(AppModel.shared.catalog)
            .environment(AppModel.shared.rankings)
            .environment(AppModel.shared.account)
            .environment(AppModel.shared.engine)
            .environment(AppModel.shared.lock)
            .modelContainer(AppModel.shared.container)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .toggleStyle(HaloSwitchStyle())
            .platformDefaults()
            #if os(macOS)
            .frame(minWidth: 760, minHeight: 520)
            #endif
    }
}

#if os(macOS)
/// The menu bar's own items for things the iOS app reaches by tapping.
struct HaloCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { AppModel.shared.newChat() }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppModel.shared.sheet = .settings }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .textEditing) {
            Button("Search Chats") {
                let app = AppModel.shared
                withAnimation(Motion.smooth) { app.sidebarOpen = true }
                app.searchFocusTick += 1
            }
            .keyboardShortcut("f")
        }
        CommandGroup(before: .sidebar) {
            Button(AppModel.shared.sidebarOpen ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(Motion.smooth) { AppModel.shared.sidebarOpen.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Button(AppModel.shared.browserVisible ? "Hide Browser" : "Show Browser") {
                withAnimation(Motion.smooth) { AppModel.shared.browserVisible.toggle() }
            }
            .keyboardShortcut("b", modifiers: [.option, .command])
        }
    }
}
#endif
