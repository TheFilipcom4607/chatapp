import AVKit
import Combine
import SwiftUI

/// OpenRouter's own benchmark on a media model's detail page: how many checks it passed, where it
/// ranks on checks, cost and speed, and a card per challenge and style prompt with its result. A card
/// opens the prompt, the output and each check, in a sheet the page presents.
struct MediaBenchmarkSection: View {
    let explore: ArenaExplore
    let modelID: String
    @Binding var opened: ArenaExplore.Challenge?

    var body: some View {
        Section {
            if let standing = explore.standing {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Self.stats(standing), id: \.label) { stat in
                        StatTile(label: stat.label, value: stat.value, detail: stat.detail)
                    }
                }
                .padding(.vertical, 6)
            }
            if !explore.challenges.isEmpty { carousel("Challenges", explore.challenges) }
            if !explore.showcases.isEmpty { carousel("Styles", explore.showcases) }
        } header: {
            DetailSectionTitle(title: "OpenRouter benchmark")
        } footer: {
            Text(footer).font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    struct Stat {
        let label: String
        let value: String
        let detail: String?
    }

    /// The four figures openrouter.ai leads with, worded the same way.
    nonisolated static func stats(_ s: ArenaExplore.Standing) -> [Stat] {
        var result = [Stat(label: "Checks passed", value: "\(s.checksPassed) of \(s.checksTotal)",
                           detail: s.evalsRun.map { "across \($0) \($0 == 1 ? "prompt" : "prompts")" })]
        if let r = s.rankOnChecks { result.append(Stat(label: "Overall rank", value: ArenaExplore.ordinal(r.position), detail: "of \(r.of) on checks")) }
        if let r = s.rankOnCost { result.append(Stat(label: "Cost rank", value: ArenaExplore.ordinal(r.position), detail: "of \(r.of), cheapest first")) }
        if let r = s.rankOnSpeed { result.append(Stat(label: "Speed rank", value: ArenaExplore.ordinal(r.position), detail: "of \(r.of), fastest first")) }
        return result
    }

    private func carousel(_ title: String, _ challenges: [ArenaExplore.Challenge]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(challenges) { challenge in
                        Button {
                            Haptics.selection()
                            opened = challenge
                        } label: {
                            ChallengeCard(challenge: challenge, rank: explore.rank(of: challenge))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            // Edge to edge, past the row's inset.
            .padding(.horizontal, -20)
        }
        .padding(.vertical, 6)
    }

    private var footer: AttributedString {
        var text = AttributedString("OpenRouter gives every model the same prompts, and judge models mark each check pass or fail. Ranks are among the models it has tested. More on openrouter.ai.")
        if let range = text.range(of: "openrouter.ai"), let url = URL(string: "https://openrouter.ai/\(modelID)/benchmarks") {
            text[range].link = url
            text[range].underlineStyle = .single
        }
        return text
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value).font(.readout(.title3, weight: .semibold))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A challenge's thumbnail, name and checks: "Full wine glass", "4/4 · #1 of 59".
private struct ChallengeCard: View {
    let challenge: ArenaExplore.Challenge
    let rank: ArenaExplore.Rank?

    var body: some View {
        let tally = challenge.tally
        VStack(alignment: .leading, spacing: 6) {
            AssetPreview(asset: challenge.lead?.cell.asset)
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(challenge.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if tally.total > 0 {
                HStack(spacing: 4) {
                    Image(systemName: tally.passed == tally.total ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                        .foregroundStyle(tally.passed == tally.total ? Theme.positive : Theme.textSecondary)
                    Text(([challenge.isShowcase ? nil : "\(tally.passed)/\(tally.total)"] + [rank.map { "#\($0.position) of \($0.of)" }])
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.readout(.caption2))
            }
        }
        .frame(width: 150)
        .accessibilityElement(children: .combine)
    }
}

/// A still for an image or video result; a speaker for a voice clip.
private struct AssetPreview: View {
    let asset: ArenaExplore.Asset?

    var body: some View {
        ZStack {
            Theme.fill
            if let url = asset?.previewURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: asset?.isAudio == true ? "waveform" : "photo")
                    .font(.title)
                    .foregroundStyle(Theme.textTertiary)
            }
            if asset?.isVideo == true {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
        }
    }
}

/// One challenge in full: what it tests, then each variant's prompt, input images, this model's
/// output, and every check, with cost and time.
struct ArenaChallengeView: View {
    let challenge: ArenaExplore.Challenge
    let rank: ArenaExplore.Rank?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if challenge.description != nil || rank != nil {
                    Section {
                        if let description = challenge.description {
                            Text(description).font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        if let rank {
                            DetailRow("Rank", "#\(rank.position) of \(rank.of)", caption: rank.tied == true ? "Tied" : nil)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.03))
                }
                ForEach(challenge.variants.filter { !$0.cells.isEmpty }) { variant in
                    variantSection(variant)
                }
            }
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(challenge.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func variantSection(_ variant: ArenaExplore.Variant) -> some View {
        Section {
            if let prompt = variant.prompt {
                Text(prompt).font(.subheadline).textSelection(.enabled)
            }
            if let inputs = variant.inputAssets, !inputs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(inputs, id: \.url) { asset in
                            AssetPreview(asset: asset)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            ForEach(Array(variant.cells.enumerated()), id: \.offset) { _, cell in
                if let asset = cell.asset { AssetView(asset: asset) }
                ForEach(Array((cell.score?.checks ?? []).enumerated()), id: \.offset) { _, check in
                    Label {
                        Text(check.label).font(.subheadline)
                    } icon: {
                        Image(systemName: check.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.pass ? Theme.positive : Theme.negative)
                    }
                    .accessibilityLabel("\(check.label): \(check.pass ? "passed" : "failed")")
                }
                let meta = [cell.costUsd.map { MediaModelSummary.formatPrice($0) },
                            cell.durationMs.map { ModelSpeed.seconds($0 / 1000) },
                            cell.provider].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.readout(.caption)).foregroundStyle(Theme.textTertiary)
                }
            }
        } header: {
            if challenge.variants.count > 1 { DetailSectionTitle(title: variant.name) }
        }
        .listRowBackground(Color.white.opacity(0.03))
    }
}

/// The output itself: the full image, a playable video, or a voice clip with a play button.
private struct AssetView: View {
    let asset: ArenaExplore.Asset

    var body: some View {
        if asset.isVideo, let url = URL(string: asset.url) {
            RemoteVideo(url: url)
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if asset.isAudio, let url = URL(string: asset.url) {
            RemoteAudioButton(url: url, title: asset.voice.map { "Voice: \($0.capitalized)" } ?? "Play")
        } else if let url = URL(string: asset.url) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ZStack { Theme.fill; ProgressView() }.aspectRatio(aspect, contentMode: .fit)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var aspect: CGFloat {
        guard let w = asset.width, let h = asset.height, w > 0, h > 0 else { return 1 }
        return CGFloat(w) / CGFloat(h)
    }
}

private struct RemoteVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}

/// Plays a clip from the web; a second tap pauses it.
private struct RemoteAudioButton: View {
    let url: URL
    let title: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        Button {
            Haptics.tap()
            if player == nil { player = AVPlayer(url: url) }
            if isPlaying {
                player?.pause()
            } else {
                // Played to the end: start over.
                if let player, let item = player.currentItem, CMTimeCompare(item.currentTime(), item.duration) >= 0 { player.seek(to: .zero) }
                player?.play()
            }
            isPlaying.toggle()
        } label: {
            Label(title, systemImage: isPlaying ? "pause.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            if (note.object as? AVPlayerItem) == player?.currentItem { isPlaying = false }
        }
        .onDisappear { player?.pause() }
    }
}
