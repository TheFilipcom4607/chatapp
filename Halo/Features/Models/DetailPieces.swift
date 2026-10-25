import SwiftUI

/// Parts the chat and media model detail pages share.

/// Design Arena's ratings as tiles, two to a row: the category, its Elo, a bar for the share of
/// votes won, and the rank among every model Design Arena has tested.
struct DesignArenaSection: View {
    let scores: [ORModel.ArenaScore]
    /// Every listed model's scores, this one's included, to rank against the others rated in the
    /// same arena and category.
    let all: [[ORModel.ArenaScore]]

    var body: some View {
        if !scores.isEmpty {
            Section {
                ForEach(DesignArena.groups(scores)) { group in
                    if let title = group.title {
                        Text(title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    let rows = ranked(group.scores)
                    let shown = expanded.contains(group.id) ? rows : Array(rows.prefix(Self.collapsed))
                    ForEach(shown, id: \.score.category) { row in
                        let score = row.score, all = row.all
                        // Elo has no zero, so the bar runs from the lowest-rated model here to the best.
                        let lo = all.min() ?? score.elo, hi = all.max() ?? score.elo
                        ScoreBar(title: DesignArena.name(score.category),
                                 value: "\(Int(score.elo.rounded())) Elo",
                                 fraction: hi > lo ? max((score.elo - lo) / (hi - lo), 0.04) : 1,
                                 caption: all.count > 1 ? "#\(row.place.rank) of \(row.place.of)" : nil)
                    }
                    if rows.count > Self.collapsed {
                        let open = expanded.contains(group.id)
                        Button(open ? "Show fewer" : "Show all \(rows.count)") {
                            withAnimation { if open { expanded.remove(group.id) } else { expanded.insert(group.id) } }
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            } header: {
                DetailSectionTitle(title: DesignArena.source)
            } footer: {
                Text(Self.footer).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    /// All coding, then the three categories it places best in, are shown until the rest are opened.
    private static let collapsed = 4
    @State private var expanded: Set<String> = []

    private struct Row {
        let score: ORModel.ArenaScore
        let all: [Double]
        let place: (rank: Int, of: Int)
    }

    /// The coding-wide score first, then the rest from the best placing (rank as a share of the field) down.
    private func ranked(_ scores: [ORModel.ArenaScore]) -> [Row] {
        let rows = scores.map { score in
            let all = peers(score)
            return Row(score: score, all: all, place: ModelInsights.rank(score.elo, among: all))
        }
        func share(_ r: Row) -> Double { Double(r.place.rank) / Double(max(r.place.of, 1)) }
        return rows.sorted {
            let a = $0.score.category == DesignArena.overall, b = $1.score.category == DesignArena.overall
            return a != b ? a : share($0) != share($1) ? share($0) < share($1) : $0.score.elo > $1.score.elo
        }
    }

    private func peers(_ score: ORModel.ArenaScore) -> [Double] {
        all.compactMap { scores in scores.first { $0.category == score.category && $0.arena == score.arena }?.elo }
    }

    private static var footer: AttributedString {
        var text = AttributedString("Elo from blind votes on \(DesignArena.source), ranked against the other models here it has rated.")
        if let range = text.range(of: DesignArena.source) {
            text[range].link = DesignArena.sourceURL
            text[range].underlineStyle = .single
        }
        return text
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
