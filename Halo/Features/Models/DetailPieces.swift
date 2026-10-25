import SwiftUI

/// Parts the chat and media model detail pages share.

/// Design Arena's ratings as tiles, two to a row: the category, its Elo, a bar for the share of
/// votes won, and the rank among every model Design Arena has tested.
struct DesignArenaSection: View {
    let scores: [ORModel.ArenaScore]

    var body: some View {
        if !scores.isEmpty {
            Section {
                ForEach(DesignArena.groups(scores)) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = group.title {
                            Text(title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(group.scores, id: \.category) { ArenaTile(score: $0) }
                        }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                DetailSectionTitle(title: DesignArena.source)
            } footer: {
                Text(Self.footer).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    private static var footer: AttributedString {
        var text = AttributedString("Elo from blind votes on \(DesignArena.source), where people pick the better of two models' work for the same prompt. The bar is the share of votes won; the rank is among every model it has tested.")
        if let range = text.range(of: DesignArena.source) {
            text[range].link = DesignArena.sourceURL
            text[range].underlineStyle = .single
        }
        return text
    }
}

private struct ArenaTile: View {
    let score: ORModel.ArenaScore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DesignArena.name(score.category))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2, reservesSpace: true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(score.elo.rounded()))").font(.readout(.title3, weight: .semibold))
                Text("Elo").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            if let winRate = score.winRate {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill)
                        Capsule().fill(Theme.textSecondary).frame(width: geo.size.width * min(max(winRate / 100, 0), 1))
                    }
                }
                .frame(height: 4)
            }
            if let caption = DesignArena.caption(score) {
                Text(caption).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A score with a bar against the best: "Intelligence  63", a bar, "#4 of 285".
struct ScoreBar: View {
    let title: String
    let value: String
    let fraction: Double
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer()
                if let caption { Text(caption).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary) }
                Text(value).font(.readout(.subheadline, weight: .semibold))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.textSecondary).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct DetailSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(nil)
    }
}

/// "Input  $3.00", with an optional line under the value.
struct DetailRow: View {
    let label: String
    let value: String
    var caption: String? = nil

    init(_ label: String, _ value: String, caption: String? = nil) {
        self.label = label
        self.value = value
        self.caption = caption
    }

    var body: some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.readout(.subheadline)).foregroundStyle(Theme.textSecondary)
                if let caption { Text(caption).font(.readout(.caption2)).foregroundStyle(Theme.textTertiary) }
            }
        }
    }
}

/// The big button at the bottom of a detail page: "Use Claude Sonnet 5.5", or "In use".
struct DetailUseButton: View {
    let title: String
    let isCurrent: Bool
    /// Set when the model can't be picked here; it's shown in place of the title.
    var unavailableReason: String? = nil
    let action: () -> Void

    var body: some View {
        let enabled = !isCurrent && unavailableReason == nil
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(isCurrent ? "In use" : unavailableReason ?? title,
                  systemImage: isCurrent ? "checkmark" : unavailableReason != nil ? "nosign" : "arrow.up.circle.fill")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(enabled ? Theme.onAccent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Opaque either way: the list scrolls underneath. Outside the button, which fades it when disabled.
        .background(enabled ? Theme.accent : Theme.elevated, in: Capsule())
        .overlay { if !enabled { Capsule().strokeBorder(Theme.hairline) } }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
        // Rows fade out behind the button instead of showing through around it.
        .background {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }
}
