import SwiftUI
import UserNotifications
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let idString = response.notification.request.content.userInfo["conversationID"] as? String,
              let id = UUID(uuidString: idString) else { return }
        await MainActor.run { AppModel.shared.openConversation(id: id) }
    }
}

@main
struct HaloApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
                .environment(AppModel.shared.settings)
                .environment(AppModel.shared.catalog)
                .environment(AppModel.shared.account)
                .environment(AppModel.shared.engine)
                .environment(AppModel.shared.lock)
                .modelContainer(AppModel.shared.container)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .toggleStyle(HaloSwitchStyle())
                .onOpenURL { url in
                    // "Open in Halo" from Files or the share sheet: an OpenRouter chat export or a backup.
                    if url.isFileURL { AppModel.shared.importFile(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            let engine = AppModel.shared.engine
            AppModel.shared.lock.scenePhaseChanged(phase)
            switch phase {
            case .active: engine.appDidBecomeActive()
            case .background: engine.appDidEnterBackground()
            default: break
            }
        }
    }
}
