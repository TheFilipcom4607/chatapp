import UIKit

/// Centralized haptics. Streaming ticks are rate-limited so they feel like texture, not buzzing.
@MainActor
enum Haptics {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }

    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()
    private static let select = UISelectionFeedbackGenerator()
    private static var lastTick = Date.distantPast

    static func tap() { guard enabled else { return }; light.impactOccurred() }
    static func send() { guard enabled else { return }; rigid.impactOccurred(intensity: 0.8) }
    static func selection() { guard enabled else { return }; select.selectionChanged() }
    static func success() { guard enabled else { return }; notify.notificationOccurred(.success) }
    static func warning() { guard enabled else { return }; notify.notificationOccurred(.warning) }
    static func error() { guard enabled else { return }; notify.notificationOccurred(.error) }

    static func streamTick() {
        guard enabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.09 else { return }
        lastTick = now
        soft.impactOccurred(intensity: 0.35)
    }
}
