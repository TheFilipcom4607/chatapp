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

/// Small pulsing dot shown before the first token arrives (like ChatGPT).
struct PulseDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Theme.textPrimary)
            .frame(width: 12, height: 12)
            .scaleEffect(on ? 1 : 0.7)
            .opacity(on ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.8).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

/// Halo's mark: a black disc with a thin white corona and a small flare (matches the app icon).
struct EclipseMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.55), lineWidth: size * 0.05)
                .blur(radius: size * 0.08)
            Circle()
                .stroke(Color.white, lineWidth: max(1, size * 0.018))
            Circle()
                .fill(Color.black)
                .padding(size * 0.012)
            Circle()
                .fill(Color.white)
                .frame(width: size * 0.09, height: size * 0.09)
                .blur(radius: size * 0.015)
                .shadow(color: .white, radius: size * 0.08)
                .offset(x: size * 0.265, y: -size * 0.425)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
