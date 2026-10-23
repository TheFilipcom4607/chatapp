import SwiftUI

/// Slow-moving aurora mesh used behind the home greeting.
struct AuroraBackground: View {
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let s = Float(sin(t * 0.35)) * 0.12
            let c = Float(cos(t * 0.27)) * 0.12
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + s, 0], [1, 0],
                    [0, 0.5 + c], [0.5 - c, 0.5 + s], [1, 0.5 - s],
                    [0, 1], [0.5 + c, 1], [1, 1],
                ],
                colors: [
                    .black, Theme.indigo.opacity(0.55 * intensity), .black,
                    Theme.violet.opacity(0.35 * intensity), Theme.indigo.opacity(0.25 * intensity), Theme.teal.opacity(0.3 * intensity),
                    .black, Theme.teal.opacity(0.18 * intensity), .black,
                ]
            )
            .blur(radius: 60)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Glowing, breathing orb (Halo's mascot).
struct GlowOrb: View {
    var size: CGFloat = 120
    var active = false

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = active ? 1.6 : 0.6
            let breathe = 1 + 0.05 * sin(t * 1.4 * speed)
            ZStack {
                Circle()
                    .fill(Theme.auroraAngular)
                    .rotationEffect(.radians(t * 0.5 * speed))
                    .blur(radius: size * 0.28)
                    .opacity(0.9)
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [Theme.indigo, Theme.violet, Theme.pink, Theme.teal, Theme.indigo], center: .center),
                        lineWidth: size * 0.075
                    )
                    .rotationEffect(.radians(-t * 0.8 * speed))
                    .blur(radius: 1.5)
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    .padding(size * 0.03)
                    .blur(radius: 0.6)
            }
            .frame(width: size * 0.6, height: size * 0.6)
            .scaleEffect(breathe)
            .frame(width: size, height: size)
        }
        .allowsHitTesting(false)
    }
}

/// Text with a moving highlight sweep ("Thinking…").
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
                    LinearGradient(colors: [.clear, Theme.violet, .white, Theme.teal, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.8)
                        .offset(x: phase * geo.size.width * 1.4)
                }
                .mask(Text(text).font(font))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Animated aurora gradient applied to text (greeting).
struct AuroraText: View {
    let text: String
    var font: Font

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let shift = CGFloat(sin(t * 0.6)) * 0.5
            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.indigo, Theme.violet, Theme.pink, Theme.teal],
                                   startPoint: UnitPoint(x: -0.2 + shift, y: 0),
                                   endPoint: UnitPoint(x: 1.2 + shift, y: 1))
                )
        }
    }
}

/// Three pulsing dots used while waiting for the first token.
struct TypingDots: View {
    @State private var animate = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(animate ? 1 : 0.5)
                    .opacity(animate ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18), value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

/// Small rotating aurora ring used as an activity indicator.
struct AuroraSpinner: View {
    var size: CGFloat = 18
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(Theme.auroraAngular, style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
