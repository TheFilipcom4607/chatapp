import SwiftUI
import UserNotifications
import AVFoundation

final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let idString = response.notification.request.content.userInfo["conversationID"] as? String,
              let id = UUID(uuidString: idString) else { return }
        await MainActor.run { AppModel.shared.openConversation(id: id) }
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
        UNUserNotificationCenter.current().delegate = self
        _ = AppModel.shared
        #if DEBUG
        MacSnapshot.scheduleIfRequested()
        #endif
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
        #endif
        .onChange(of: scenePhase) { _, phase in
            let engine = AppModel.shared.engine
            AppModel.shared.lock.scenePhaseChanged(phase)
            switch phase {
            case .active:
                engine.appDidBecomeActive()
                AppModel.shared.drainShareInbox()
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
