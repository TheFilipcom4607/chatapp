import SwiftUI

enum Theme {
    // Canvas
    static let background = Color(red: 0.0, green: 0.0, blue: 0.0)
    static let elevated = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.09)

    // Text
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    // Aurora
    static let indigo = Color(red: 0.39, green: 0.40, blue: 0.95)
    static let violet = Color(red: 0.66, green: 0.33, blue: 0.97)
    static let teal = Color(red: 0.18, green: 0.83, blue: 0.75)
    static let pink = Color(red: 0.93, green: 0.40, blue: 0.75)

    static let aurora: [Color] = [indigo, violet, teal]

    static var auroraGradient: LinearGradient {
        LinearGradient(colors: [indigo, violet, teal], startPoint: .leading, endPoint: .trailing)
    }

    static var auroraAngular: AngularGradient {
        AngularGradient(colors: [indigo, violet, pink, teal, indigo], center: .center)
    }

    static let codeBackground = Color(red: 0.06, green: 0.06, blue: 0.08)

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

    static func perMillion(_ value: Double?) -> String {
        guard let value else { return "–" }
        if value == 0 { return "free" }
        if value < 0.1 { return String(format: "$%.3f", value) }
        if value < 10 { return String(format: "$%.2f", value) }
        return String(format: "$%.0f", value)
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
