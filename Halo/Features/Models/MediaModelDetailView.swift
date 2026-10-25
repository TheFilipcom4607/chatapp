import SwiftUI

/// Everything about one image, video or voice model: what it costs, how it rates in Artificial
/// Analysis's and Design Arena's blind-vote arenas, what it can do, and which models are worth
/// considering instead. Opened by tapping a model in the media browser; the big button at the
/// bottom picks it.
struct MediaModelDetailView: View {
    let kind: MediaKind
    let modelID: String
    let isCurrent: Bool
    var hasReferences = false
    let onUse: (String) -> Void

    @Environment(ModelCatalog.self) private var catalog

    var body: some View {
        let all = catalog.mediaModels(kind, hasReferences: hasReferences)
        Group {
            if let model = all.first(where: { $0.id == modelID }) {
                content(model, all: all)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ model: MediaModelSummary, all: [MediaModelSummary]) -> some View {
        List {
            header(model)
            if let about = description { aboutSection(about) }
            priceSection(model)
            arenaSection(all: all)
            DesignArenaSection(scores: catalog.designArena(kind, modelID))
            specsSection
            alternativesSection(model, all: all)
            Section {} footer: {
                Text(attribution).font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        // Without a title the bar has nothing behind its buttons; rows would scroll under them in full.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .safeAreaInset(edge: .bottom) {
            DetailUseButton(title: "Use \(model.name)", isCurrent: isCurrent, unavailableReason: model.unavailableReason) {
                onUse(model.id)
            }
        }
    }

    // MARK: Sections

    private func header(_ model: MediaModelSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.lab.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.name)
                        .font(.display(.title, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if model.isNew() {
                        Text("NEW")
                            .font(.readout(.caption2, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                // No rank here: the arena section ranks it on each board.
                if let created = model.created {
                    Text("Released \(Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                if let note = model.note {
                    Text(note).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                let features = MediaFeature.allCases.filter(model.features.contains)
                if !features.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(features) { Badge(text: $0.rawValue, color: .white) }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
                }
                if let reason = model.unavailableReason {
                    Label(reason, systemImage: "nosign")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        }
    }

    private func aboutSection(_ text: String) -> some View {
        Section {
            Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
        } header: {
            DetailSectionTitle(title: "About")
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private func priceSection(_ model: MediaModelSummary) -> some View {
        Section {
            switch kind {
            case .image:
                if let price = model.price {
                    DetailRow("Per image", (model.priceIsLearned && price > 0 ? "~" : "") + MediaModelSummary.formatPrice(price),
                              caption: model.priceIsLearned ? "What your last image cost" : "About 1K, default settings")
                } else {
                    DetailRow("Per image", model.priceUnlisted ? "No price listed" : "Not known yet")
                }
            case .video:
                let prices = videoPrices
                if prices.isEmpty { DetailRow("Per second", "No price listed") }
                ForEach(prices) { p in
                    DetailRow(p.label, "\(MediaModelSummary.formatPrice(p.silent))/sec",
                              caption: p.withAudio.map { "\(MediaModelSummary.formatPrice($0))/sec with audio" })
                }
            case .speech:
                DetailRow("1,000 characters", model.price.map(MediaModelSummary.formatPrice) ?? "No price listed",
                          caption: model.price == 0 ? nil : "About a minute of speech, roughly")
            }
        } header: {
            DetailSectionTitle(title: "Price")
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    /// Per second at each resolution the model offers, without audio and, where it differs, with it.
    private var videoPrices: [VideoPrice] {
        guard let m = catalog.videoModel(modelID) else { return [] }
        let resolutions: [String?] = (m.supportedResolutions ?? []).isEmpty ? [nil] : (m.supportedResolutions ?? []).map { $0 }
        let audio = m.generateAudio == true
        return resolutions.compactMap { res -> VideoPrice? in
            guard let silent = m.estimatedCost(seconds: 1, resolution: res?.lowercased(), audio: false) else { return nil }
            let loud = audio ? m.estimatedCost(seconds: 1, resolution: res?.lowercased(), audio: true) : nil
            return VideoPrice(label: res ?? "Per second", silent: silent, withAudio: loud.flatMap { abs($0 - silent) > 0.0001 ? $0 : nil })
        }
    }

    @ViewBuilder
    private func arenaSection(all: [MediaModelSummary]) -> some View {
        let rows = kind.boards.compactMap { board -> BoardRating? in
            guard let elo = catalog.arenaElo(board, modelID) else { return nil }
            return BoardRating(board: board, elo: elo, all: all.compactMap { catalog.arenaElo(board, $0.id) })
        }
        Section {
            if rows.isEmpty {
                Text("\(MediaModelResearch.source) hasn't rated this model yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(rows) { r in
                let place = ModelInsights.rank(r.elo, among: r.all)
                // Elo has no zero, so the bar runs from the lowest-rated model here to the best.
                let lo = r.all.min() ?? r.elo, hi = r.all.max() ?? r.elo
                ScoreBar(title: r.board.rawValue.prefix(1).uppercased() + r.board.rawValue.dropFirst(),
                         value: "\(Int(r.elo.rounded())) Elo",
                         fraction: hi > lo ? max((r.elo - lo) / (hi - lo), 0.04) : 1,
                         caption: "#\(place.rank) of \(place.of)")
            }
        } header: {
            DetailSectionTitle(title: "\(MediaModelResearch.source) arena")
        } footer: {
            if let board = rows.first?.board {
                Text("Elo from blind votes (\(catalog.arenaAsOf(board))), ranked against the other \(kind.noun)s here it has rated. 100 points is about a 64–36 split of the votes.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    @ViewBuilder
    private var specsSection: some View {
        let specs = self.specs
        if !specs.isEmpty {
            Section {
                ForEach(specs) { DetailRow($0.label, $0.value) }
                if kind == .speech, let voices = catalog.speechModel(modelID)?.supportedVoices, !voices.isEmpty {
                    let shown = voices.prefix(30).joined(separator: ", ")
                    Text(voices.count > 30 ? "\(shown) and \(voices.count - 30) more" : shown)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            } header: {
                DetailSectionTitle(title: "What it can do")
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    private var specs: [Spec] {
        var result: [Spec] = []
        switch kind {
        case .image:
            guard let m = catalog.imageModel(modelID) else { return [] }
            if !m.resolutions.isEmpty { result.append(Spec("Sizes", m.resolutions.joined(separator: ", "))) }
            if !m.aspectRatios.isEmpty { result.append(Spec("Aspect ratios", Self.list(m.aspectRatios))) }
            if !m.qualities.isEmpty { result.append(Spec("Quality", m.qualities.map(ImageQuality.label).joined(separator: ", "))) }
            let references = Int(m.supportedParameters?["input_references"]?.max ?? 0)
            result.append(Spec("Reference images", references == 0 ? "No" : m.requiresReferences ? "Needs 1 to \(references)" : "Up to \(references)"))
            if m.maxCount > 1 { result.append(Spec("Images per request", "Up to \(m.maxCount)")) }
            if m.supportsTransparency { result.append(Spec("Transparent background", "Yes")) }
            if m.makesVectors { result.append(Spec("SVG output", "Yes")) }
            if m.streams { result.append(Spec("Shows drafts while drawing", "Yes")) }
        case .video:
            guard let m = catalog.videoModel(modelID) else { return [] }
            if m.needsVideoInput { result.append(Spec("Input", "A video you give")) }
            if let r = m.supportedResolutions, !r.isEmpty { result.append(Spec("Resolutions", r.joined(separator: ", "))) }
            if let d = m.supportedDurations, !d.isEmpty { result.append(Spec("Length", Self.durations(d))) }
            if let a = m.supportedAspectRatios, !a.isEmpty { result.append(Spec("Aspect ratios", Self.list(a))) }
            result.append(Spec("Audio", m.generateAudio == true ? "Yes" : "No"))
            if !m.needsVideoInput {
                result.append(Spec("Starts from an image", m.supportsFirstFrame ? "Yes" : "No"))
                if m.supportedFrameImages?.contains("last_frame") == true { result.append(Spec("Ends on an image", "Yes")) }
            }
        case .speech:
            guard let m = catalog.speechModel(modelID) else { return [] }
            if let voices = m.supportedVoices, !voices.isEmpty { result.append(Spec("Voices", "\(voices.count)")) }
            if m.id.hasPrefix("google/gemini") { result.append(Spec("Directions on tone and pace", "Yes")) }
        }
        return result
    }

    @ViewBuilder
    private func alternativesSection(_ model: MediaModelSummary, all: [MediaModelSummary]) -> some View {
        let alternatives = MediaPicks.alternatives(to: model, among: all)
        if !alternatives.isEmpty {
            Section {
                ForEach(alternatives) { alt in
                    NavigationLink(value: alt.model.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(alt.kind.title, systemImage: alt.kind.icon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(alt.model.name).font(.subheadline.weight(.semibold))
                            Text([alt.detail, alt.model.priceLabel].compactMap { $0 }.joined(separator: " · "))
                                .font(.readout(.caption))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                DetailSectionTitle(title: "Worth a look instead")
            } footer: {
                Text("Within \(Int(MediaPicks.closeEnough)) Elo counts as about as good: a 54–46 split of the votes.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .listRowBackground(Color.white.opacity(0.03))
        }
    }

    // MARK: Pieces

    private struct VideoPrice: Identifiable {
        let label: String
        let silent: Double
        let withAudio: Double?
        var id: String { label }
    }

    private struct BoardRating: Identifiable {
        let board: MediaModelResearch.Board
        let elo: Double
        /// The board's Elo for every model of this kind it rates, to rank against.
        let all: [Double]
        var id: String { board.rawValue }
    }

    private struct Spec: Identifiable {
        let label: String
        let value: String
        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
        var id: String { label }
    }

    /// The model's own description, with Markdown links reduced to their text (they point into
    /// openrouter.ai).
    private var description: String? {
        let raw: String? = switch kind {
        case .image: catalog.imageModel(modelID)?.description
        case .video: catalog.videoModel(modelID)?.description
        case .speech: catalog.speechModel(modelID)?.description
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    }

    /// Up to six in full, then "and 4 more".
    private static func list(_ values: [String]) -> String {
        values.count <= 6 ? values.joined(separator: ", ") : values.prefix(5).joined(separator: ", ") + " and \(values.count - 5) more"
    }

    /// "4–15 s" for an unbroken run, else "5, 10 s".
    nonisolated static func durations(_ seconds: [Int]) -> String {
        let sorted = Array(Set(seconds)).sorted()
        guard let lo = sorted.first, let hi = sorted.last else { return "" }
        if sorted.count >= 3, hi - lo == sorted.count - 1 { return "\(lo)–\(hi) s" }
        return sorted.map(String.init).joined(separator: ", ") + " s"
    }

    private var attribution: AttributedString {
        var text = AttributedString(kind == .video
            ? "Ratings from \(MediaModelResearch.source)."
            : "Ratings from \(MediaModelResearch.source) and \(DesignArena.source).")
        for (name, url) in [(MediaModelResearch.source, MediaModelResearch.sourceURL), (DesignArena.source, DesignArena.sourceURL)] {
            if let range = text.range(of: name) {
                text[range].link = url
                text[range].underlineStyle = .single
            }
        }
        return text
    }
}
