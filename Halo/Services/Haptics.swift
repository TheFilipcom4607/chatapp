import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Centralized haptics. Streaming ticks are rate-limited so they feel like texture, not buzzing.
#if os(iOS)
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
    /// A soft beat for progress you can't see yet: a partial render landing, a video changing state.
    static func pulse() { guard enabled else { return }; soft.impactOccurred(intensity: 0.6) }

    static func streamTick() {
        guard enabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.09 else { return }
        lastTick = now
        soft.impactOccurred(intensity: 0.35)
    }
}
#else
/// The Mac's Force Touch trackpad: felt only while a finger is on it, and it has three patterns
/// rather than the iPhone's range. So only what the user just did with the trackpad plays:
/// choices and toggles as a level change, taps and sends as a generic tick. Outcomes that land
/// later (success, warning, error, pulses, the stream) stay silent, and so does anything set off
/// from the keyboard (Return to send, ⌘N), which a resting finger would otherwise feel.
@MainActor
enum Haptics {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }

    static func tap() { play(.generic) }
    static func send() { play(.generic) }
    static func selection() { play(.levelChange) }
    static func success() {}
    static func warning() {}
    static func error() {}
    static func pulse() {}
    static func streamTick() {}

    /// Events that mean a finger is on the trackpad right now.
    private static let pointerEvents: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .pressure, .gesture, .magnify, .swipe,
    ]

    private static func play(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enabled, let event = NSApp.currentEvent, pointerEvents.contains(event.type),
              // A call after an await can see the click that started it long ago; only fresh ones.
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
#endif
