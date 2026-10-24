import SwiftUI

enum Theme {
    // Canvas
    static let background = Color.black
    static let elevated = Color(white: 0.075)
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.1)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.36)

    // Monochrome accent: white. Fills are neutral grays.
    static let accent = Color(white: 0.96)
    static let onAccent = Color.black
    static let bubble = Color(white: 0.165)
    static let fill = Color.white.opacity(0.07)
    static let fillStrong = Color.white.opacity(0.16)
    /// A switch's on track: gray, so the white knob shows against it.
    static let switchOn = Color(white: 0.5)

    // The one color: the corona's warm light. Only for live things (a reply in progress,
    // the send button, the open chat). If it shows up in more than a few places, it's too many.
    static let corona = Color(red: 0.95, green: 0.90, blue: 0.79)

    // Functional colors only (diffs, errors).
    static let positive = Color(red: 0.38, green: 0.82, blue: 0.55)
    static let negative = Color(red: 1.0, green: 0.42, blue: 0.4)

    static let codeBackground = Color(white: 0.07)

    static let radius: CGFloat = 22
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8888FF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Font {
    /// New York, for names and titles: the greeting, chat and document titles.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif, weight: weight)
    }

    /// SF Mono, for readouts: costs, balances, tokens, model ids.
    static func readout(_ style: Font.TextStyle = .caption2, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

enum Motion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.88)
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
    static let gentle = Animation.easeOut(duration: 0.35)
}

extension View {
    /// Liquid Glass card with a rounded rectangle shape.
    func glassCard(cornerRadius: CGFloat = Theme.radius, interactive: Bool = false, tint: Color? = nil) -> some View {
        let glass: Glass = {
            var g = Glass.regular
            if let tint { g = g.tint(tint) }
            if interactive { g = g.interactive() }
            return g
        }()
        return self.glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    func glassCapsule(interactive: Bool = true, tint: Color? = nil) -> some View {
        let glass: Glass = {
            var g = Glass.regular
            if let tint { g = g.tint(tint) }
            if interactive { g = g.interactive() }
            return g
        }()
        return self.glassEffect(glass, in: .capsule)
    }
}

/// The system switch with a gray on track. The app tint is white, which would hide the white knob.
struct HaloSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(Theme.switchOn)
            .onChange(of: configuration.isOn) { _, _ in Haptics.selection() }
    }
}

/// Formats USD amounts compactly: $0.0042, $0.12, $12.30
enum Money {
    static func format(_ value: Double, compact: Bool = false) -> String {
        let v = abs(value)
        if v == 0 { return "$0.00" }
        if v < 0.0001 { return "<$0.0001" }
        if v < 0.01 { return String(format: "$%.4f", value) }
        if v < 1 { return String(format: compact ? "$%.2f" : "$%.3f", value) }
        if v < 1000 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
    }

    /// A price per million tokens: always two decimals ($0.10, $2.00, $15.00), and a third only
    /// when the price needs it ($0.075). Rounded to a tenth of a cent first, because a per-token
    /// price times a million lands a hair under the real figure (0.1 arrives as 0.0999999…).
    static func perMillion(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 0 { return "free" }
        let mills = Int((value * 1000).rounded())
        if mills == 0 { return "<$0.001" }
        return String(format: mills % 10 == 0 ? "$%.2f" : "$%.3f", Double(mills) / 1000)
    }
}

enum TokenFormat {
    static func short(_ n: Int?) -> String {
        guard let n else { return "–" }
        if n >= 1_000_000 { return String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: n % 1000 == 0 ? "%.0fK" : "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}
