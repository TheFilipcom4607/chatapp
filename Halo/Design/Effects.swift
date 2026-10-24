import SwiftUI

/// Text with a soft highlight sweep, for "Thinking" / progress labels.
struct ShimmerText: View {
    let text: String
    var font: Font = .callout.weight(.medium)

    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Theme.textTertiary)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.3)
                }
                .mask(Text(text).font(font))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Minimal rotating arc used as an activity indicator.
struct Spinner: View {
    var size: CGFloat = 16
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: max(1.5, size * 0.12), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// Halo's mark: a black disc with a thin white corona and a small flare (matches the app icon).
/// With `orbiting`, the flare travels around the rim and the corona breathes: Halo's "working" signal.
struct EclipseMark: View {
    var size: CGFloat = 64
    var orbiting = false

    /// Where the flare sits at rest, up and to the right, as on the icon.
    private static let restAngle = -58.0 * .pi / 180
    /// Seconds per lap of the flare.
    private static let lap = 2.4

    var body: some View {
        if orbiting {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.lap) / Self.lap
                disc(flareAngle: Self.restAngle + t * 2 * .pi, glow: 0.5 + 0.2 * sin(t * 4 * .pi))
            }
        } else {
            disc(flareAngle: Self.restAngle, glow: 0.55)
        }
    }

    private func disc(flareAngle: Double, glow: Double) -> some View {
        let flare = max(3, size * 0.09)
        return ZStack {
            Circle()
                .stroke(Theme.corona.opacity(glow), lineWidth: max(1.5, size * 0.05))
                .blur(radius: max(1, size * 0.08))
            Circle()
                .stroke(Color.white, lineWidth: max(1, size * 0.018))
            Circle()
                .fill(Color.black)
                .padding(max(0.5, size * 0.012))
            Circle()
                .fill(Color.white)
                .frame(width: flare, height: flare)
                .blur(radius: flare * 0.17)
                .shadow(color: Theme.corona, radius: max(2, size * 0.08))
                .offset(x: CGFloat(cos(flareAngle)) * size / 2, y: CGFloat(sin(flareAngle)) * size / 2)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum Keyboard {
    /// Resigns whatever text field has focus, wherever it is.
    @MainActor static func dismiss() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.endEditing(true) }
    }
}

/// Fades a sideways scroller's edges where there's more to scroll, so a cut-off row reads as one
/// that scrolls rather than one that's clipped.
struct HorizontalScrollFade: ViewModifier {
    var width: CGFloat = 20
    @State private var leading = false
    @State private var trailing = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { geo in
                [geo.contentOffset.x > -geo.contentInsets.leading + 1,
                 geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width + geo.contentInsets.trailing - 1]
            } action: { _, edges in
                leading = edges[0]
                trailing = edges[1]
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: leading ? width : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: trailing ? width : 0)
                }
            }
    }
}

extension View {
    func horizontalScrollFade() -> some View { modifier(HorizontalScrollFade()) }
}
