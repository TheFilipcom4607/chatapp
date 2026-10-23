import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Face ID / passcode lock. Covers the app (sheets included) while locked, and whenever it isn't
/// active so the app switcher snapshot doesn't show chats.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false

    private let settings: AppSettings
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var promptedAtLaunch = false
    @ObservationIgnored private var coverWindow: UIWindow?

    init(settings: AppSettings) {
        self.settings = settings
        self.isLocked = settings.appLock
    }

    /// Whether the device can authenticate the user at all (biometrics or a passcode).
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var methodIcon: String {
        switch methodName {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock.fill"
        }
    }

    // MARK: Scene

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if settings.appLock, backgroundedAt == nil { backgroundedAt = .now }
        case .active:
            becameActive()
        default:
            break
        }
        updateCover(appActive: phase == .active)
    }

    private func becameActive() {
        guard settings.appLock else {
            isLocked = false
            return
        }
        let cameBack = backgroundedAt
        backgroundedAt = nil
        if let cameBack, Date().timeIntervalSince(cameBack) >= Double(settings.appLockDelay) {
            isLocked = true
        }
        // Prompt once per return. The Face ID sheet itself makes the app inactive and active again,
        // so prompting on every activation would loop after a cancel; the lock screen has a button.
        if isLocked, cameBack != nil || !promptedAtLaunch {
            promptedAtLaunch = true
            authenticate()
        }
    }

    // MARK: Authentication

    func authenticate() {
        guard isLocked, !isAuthenticating else { return }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            // The passcode was removed: there's nothing left to unlock with.
            unlock()
            return
        }
        isAuthenticating = true
        Task {
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your chats")) ?? false
            isAuthenticating = false
            if ok { unlock() }
        }
    }

    /// Turns the lock on after the user proves they can unlock, so they can't lock themselves out.
    func enable() {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return }
        Task {
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on the app lock")) ?? false
            if ok {
                settings.appLock = true
                Haptics.success()
            }
        }
    }

    func disable() {
        settings.appLock = false
        isLocked = false
        updateCover(appActive: true)
    }

    private func unlock() {
        withAnimation(Motion.gentle) { isLocked = false }
        Haptics.success()
        updateCover(appActive: UIApplication.shared.applicationState == .active)
    }

    // MARK: Cover

    /// A window above everything, sheets and full-screen covers included.
    private func updateCover(appActive: Bool) {
        let show = settings.appLock && (isLocked || !appActive)
        if show {
            if coverWindow == nil,
               let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                let host = UIHostingController(rootView: LockScreenView(lock: self))
                host.view.backgroundColor = .black
                window.rootViewController = host
                window.overrideUserInterfaceStyle = .dark
                coverWindow = window
            }
            coverWindow?.isHidden = false
        } else {
            coverWindow?.isHidden = true
            coverWindow = nil
        }
    }
}

struct LockScreenView: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Halo is locked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if lock.isLocked {
                    Button { lock.authenticate() } label: {
                        Label("Unlock with \(lock.methodName)", systemImage: lock.methodIcon)
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 44)
                    }
                    .buttonStyle(.glass)
                    .disabled(lock.isAuthenticating)
                    .padding(.top, 8)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
