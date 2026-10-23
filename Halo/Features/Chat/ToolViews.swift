import SwiftUI
import AVKit

struct ToolMessageView: View {
    let message: Message
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine

    /// Part of the reply that's running now (nothing the user sent comes after it).
    private var isInLiveReply: Bool {
        guard engine.isBusy(conversation) else { return false }
        let lastUser = conversation.orderedMessages.last { $0.role == .user }?.sortIndex ?? -1
        return message.sortIndex > lastUser
    }

    var body: some View {
        if let state = message.toolState {
            switch ToolName(rawValue: state.name) {
            case .generateImage, .generateVideo:
                if state.status == .awaitingApproval, let params = state.approval {
                    ApprovalCard(message: message, conversation: conversation, kind: ToolName(rawValue: state.name)!, initial: params)
                } else {
                    MediaToolResult(message: message, state: state)
                }
            case .generateSpeech:
                VStack(alignment: .leading, spacing: 8) {
                    if let item = message.media.first {
                        AudioPlayerView(item: item)
                    } else {
                        ToolStatusChip(state: state, icon: "waveform", title: "Speech")
                    }
                }
            case .runCode:
                CodeRunCard(state: state, media: message.media)
            case .shell:
                ShellCard(state: state, isLive: isInLiveReply)
            case .createArtifact, .updateArtifact:
                if let id = state.artifactID {
                    ArtifactCard(artifactID: id, version: state.artifactVersion, isUpdate: state.name == ToolName.updateArtifact.rawValue)
                } else {
                    ToolStatusChip(state: state, icon: "doc.richtext", title: "Document")
                }
            case .none:
                ToolStatusChip(state: state, icon: "wrench.and.screwdriver", title: state.name)
            }
        }
    }
}

struct ToolStatusChip: View {
    let state: ToolState
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            if state.status == .running { Spinner(size: 13) } else {
                Image(systemName: state.status == .failed ? "exclamationmark.circle" : state.status == .declined ? "xmark.circle" : icon)
                    .foregroundStyle(state.status == .failed ? Theme.negative : Theme.textSecondary)
            }
            Text(state.summary ?? title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            if let output = state.output, state.status == .failed {
                Text(output).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule(interactive: false)
    }
}

// MARK: - Approval

struct ApprovalCard: View {
    let message: Message
    let conversation: Conversation
    let kind: ToolName
    let initial: ApprovalParams

    @Environment(ChatEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AppSettings.self) private var settings
    @State private var params: ApprovalParams
    @State private var estimate: Double?

    init(message: Message, conversation: Conversation, kind: ToolName, initial: ApprovalParams) {
        self.message = message
        self.conversation = conversation
        self.kind = kind
        self.initial = initial
        _params = State(initialValue: initial)
    }

    private var isVideo: Bool { kind == .generateVideo }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isVideo ? "film" : "photo")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                Text(isVideo ? "Generate video" : "Generate image").font(.headline)
                Spacer()
            }

            TextField("Prompt", text: $params.prompt, axis: .vertical)
                .lineLimit(2...8)
                .font(.callout)
                .padding(12)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let refs = params.referenceIDs, !refs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text(isVideo ? "First frame" : "References").font(.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(refs, id: \.self) { ref in
                            if let item = engine.tools.findImage(ref: ref, in: conversation) {
                                AttachmentThumb(item: item, size: 44)
                            }
                        }
                    }
                }
            }

            modelMenu

            if isVideo { videoOptions } else { imageOptions }

            HStack(spacing: 12) {
                if let estimate {
                    Label("≈ \(Money.format(estimate))", systemImage: "creditcard")
                        .font(.readout(.footnote, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("Skip") {
                    engine.resolveApproval(message, approve: false, params: params, in: conversation)
                }
                .buttonStyle(.glass)
                Button {
                    var p = params
                    p.estimatedCost = estimate
                    engine.resolveApproval(message, approve: true, params: p, in: conversation)
                } label: {
                    Text("Generate")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(params.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 24)
        .task(id: "\(params.model)|\(params.duration ?? 0)|\(params.resolution ?? "")|\(params.count ?? 1)|\(params.generateAudio ?? false)") {
            await updateEstimate()
        }
    }

    private var modelMenu: some View {
        Menu {
            if isVideo {
                ForEach(catalog.videoModels) { m in
                    Button { params.model = m.id; normalizeVideo() } label: {
                        if m.id == params.model { Label(m.shortName, systemImage: "checkmark") } else { Text(m.shortName) }
                    }
                }
            } else {
                ForEach(catalog.imageModels.filter { params.referenceIDs?.isEmpty ?? true ? true : $0.supportsReferences }) { m in
                    Button { params.model = m.id } label: {
                        if m.id == params.model { Label(m.shortName, systemImage: "checkmark") } else { Text(m.shortName) }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "cpu")
                Text(catalog.displayName(params.model)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var imageOptions: some View {
        let info = catalog.imageModel(params.model)
        let ratios = (info?.aspectRatios.isEmpty == false ? info!.aspectRatios : ["1:1", "16:9", "9:16", "4:3", "3:4"]).filter { $0 != "auto" }
        return VStack(alignment: .leading, spacing: 10) {
            ChipPicker(options: Array(ratios.prefix(9)), selection: Binding(get: { params.aspectRatio ?? "1:1" }, set: { params.aspectRatio = $0 }))
            if let res = info?.resolutions, !res.isEmpty {
                ChipPicker(options: res, selection: Binding(get: { params.resolution ?? (res.contains("1K") ? "1K" : res.first!) }, set: { params.resolution = $0 }))
            }
            Stepper(value: Binding(get: { params.count ?? 1 }, set: { params.count = $0 }), in: 1...4) {
                Text("\(params.count ?? 1) image\((params.count ?? 1) == 1 ? "" : "s")").font(.subheadline)
            }
        }
    }

    private var videoOptions: some View {
        let info = catalog.videoModel(params.model)
        // The catalog can report empty lists; fall back so the pickers always have options.
        let durations = info?.supportedDurations.flatMap { $0.isEmpty ? nil : $0 } ?? [4, 6, 8]
        let resolutions = info?.supportedResolutions.flatMap { $0.isEmpty ? nil : $0 } ?? ["720p", "1080p"]
        let ratios = info?.supportedAspectRatios.flatMap { $0.isEmpty ? nil : $0 } ?? ["16:9", "9:16", "1:1"]
        return VStack(alignment: .leading, spacing: 10) {
            ChipPicker(options: Array(durations.prefix(10)).map { "\($0)s" },
                       selection: Binding(get: { "\(params.duration ?? durations.first ?? 6)s" },
                                          set: { params.duration = Int($0.dropLast()) }))
            ChipPicker(options: resolutions, selection: Binding(get: { params.resolution ?? resolutions.first! }, set: { params.resolution = $0 }))
            ChipPicker(options: Array(ratios.prefix(6)), selection: Binding(get: { params.aspectRatio ?? ratios.first! }, set: { params.aspectRatio = $0 }))
            if info?.generateAudio == true {
                Toggle(isOn: Binding(get: { params.generateAudio ?? true }, set: { params.generateAudio = $0 })) {
                    Text("With audio").font(.subheadline)
                }
                .tint(Theme.textSecondary)
            }
        }
    }

    private func normalizeVideo() {
        guard let info = catalog.videoModel(params.model) else { return }
        if let d = info.supportedDurations, !d.isEmpty, let cur = params.duration, !d.contains(cur) {
            params.duration = d.min(by: { abs($0 - cur) < abs($1 - cur) })
        }
        if let r = info.supportedResolutions, !r.isEmpty, !(r.contains(params.resolution ?? "")) {
            params.resolution = r.contains("720p") ? "720p" : r.first
        }
        if let a = info.supportedAspectRatios, !a.isEmpty, !(a.contains(params.aspectRatio ?? "")) {
            params.aspectRatio = a.first
        }
        params.generateAudio = info.generateAudio == true ? (params.generateAudio ?? true) : nil
    }

    private func updateEstimate() async {
        if isVideo {
            estimate = catalog.videoModel(params.model)?.estimatedCost(seconds: params.duration ?? 6, resolution: params.resolution,
                                                                       audio: params.generateAudio ?? false)
        } else {
            if let per = await catalog.imagePrice(params.model) { estimate = per * Double(params.count ?? 1) } else { estimate = nil }
        }
    }
}

struct ChipPicker: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button {
                        withAnimation(Motion.snappy) { selection = option }
                        Haptics.selection()
                    } label: {
                        Text(option)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(selection == option ? Theme.onAccent : Theme.textSecondary)
                            .background {
                                Capsule().fill(selection == option ? Theme.accent : Theme.fill)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Results

struct MediaToolResult: View {
    let message: Message
    let state: ToolState

    var body: some View {
        let media = message.media
        VStack(alignment: .leading, spacing: 10) {
            if state.status == .running {
                GeneratingCard(isVideo: state.name == ToolName.generateVideo.rawValue,
                               note: state.progressNote, prompt: state.approval?.prompt, aspect: state.approval?.aspectRatio)
            } else if media.isEmpty {
                ToolStatusChip(state: state, icon: "photo", title: state.status == .declined ? "Skipped" : "Image")
            } else if media.first?.kind == .video, let item = media.first {
                VideoCard(item: item)
            } else {
                ImageGrid(items: media)
            }
            if !media.isEmpty, let summary = state.summary {
                Text("\(AppModel.shared.catalog.displayName(state.approval?.model ?? "")) · \(summary)")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct GeneratingCard: View {
    let isVideo: Bool
    let note: String?
    let prompt: String?
    let aspect: String?

    var body: some View {
        let ratio: CGFloat = {
            guard let aspect, let parts = Optional(aspect.split(separator: ":")), parts.count == 2,
                  let w = Double(parts[0]), let h = Double(parts[1]), h > 0 else { return 1 }
            return CGFloat(w / h)
        }()
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.fill)
            VStack(spacing: 12) {
                Spinner(size: 20)
                ShimmerText(text: isVideo ? (note ?? "Generating video") : "Generating image", font: .subheadline.weight(.medium))
                if let prompt {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
        }
        .aspectRatio(max(0.6, min(ratio, 2)), contentMode: .fit)
        .frame(maxWidth: 360)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct ImageGrid: View {
    let items: [MediaItem]
    @Environment(AppModel.self) private var app

    var body: some View {
        let columns = items.count == 1 ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                if let img = MediaStore.image(for: item) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
                        .onTapGesture { app.viewingImage = item }
                        .contextMenu {
                            Button { UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil); Haptics.success(); app.showToast("Saved to Photos") } label: {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                            Button { UIPasteboard.general.image = img; Haptics.success() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button { app.requestComposer(prefill: "Edit \(item.refID): ") } label: { Label("Edit this image", systemImage: "wand.and.stars") }
                            ShareLink(item: Image(uiImage: img), preview: SharePreview(item.prompt ?? "Image", image: Image(uiImage: img)))
                        } preview: {
                            Image(uiImage: img).resizable().scaledToFit()
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: items.count == 1 ? 380 : .infinity, alignment: .leading)
    }
}

struct VideoCard: View {
    let item: MediaItem
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            .onAppear { if player == nil { player = AVPlayer(url: MediaStore.url(for: item)) } }
            .contextMenu {
                ShareLink(item: MediaStore.url(for: item)) { Label("Share video", systemImage: "square.and.arrow.up") }
            }
    }
}

/// Inline audio player with a glass capsule and live progress.
struct AudioPlayerView: View {
    let item: MediaItem
    @State private var controller = AudioController()

    var body: some View {
        HStack(spacing: 14) {
            Button {
                controller.toggle(url: MediaStore.url(for: item))
                Haptics.tap()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 46, height: 46)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.onAccent)
            .background(Circle().fill(Theme.accent))

            VStack(alignment: .leading, spacing: 6) {
                WaveformBar(progress: controller.progress, active: controller.isPlaying)
                    .frame(height: 26)
                HStack {
                    Text(item.prompt.map { String($0.prefix(60)) } ?? "Audio")
                        .lineLimit(1)
                    Spacer()
                    Text(controller.timeLabel).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }
            ShareLink(item: MediaStore.url(for: item)) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 26)
        .frame(maxWidth: 420)
        .onAppear { controller.prepare(url: MediaStore.url(for: item)) }
        .onDisappear { controller.stop() }
    }
}

struct WaveformBar: View {
    let progress: Double
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let count = 36
                let w = geo.size.width / CGFloat(count)
                HStack(alignment: .center, spacing: w * 0.35) {
                    ForEach(0..<count, id: \.self) { i in
                        let seed = sin(Double(i) * 1.7) * 0.5 + 0.5
                        let wobble = active ? (sin(t * 6 + Double(i)) * 0.18) : 0
                        let h = max(0.15, min(1, seed * 0.8 + 0.2 + wobble))
                        Capsule()
                            .fill(Double(i) / Double(count) <= progress ? Theme.textPrimary : Color.white.opacity(0.2))
                            .frame(width: w * 0.65, height: geo.size.height * h)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

@Observable
final class AudioController: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var progress: Double = 0
    var duration: TimeInterval = 0
    var current: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var timeLabel: String {
        let t = isPlaying || current > 0 ? current : duration
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    func prepare(url: URL) {
        guard player == nil, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    func toggle(url: URL) {
        prepare(url: url)
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let p = self.player else { return }
                self.current = p.currentTime
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
            }
        }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        progress = 0
        current = 0
        timer?.invalidate()
    }
}

// MARK: - Code

struct CodeRunCard: View {
    let state: ToolState
    let media: [MediaItem]
    @State private var showCode = false

    var body: some View {
        let args = JSONValue.parse(state.arguments) ?? .object([:])
        let language = args["language"]?.stringValue ?? "python"
        let code = args["code"]?.stringValue ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.smooth) { showCode.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if state.status == .running { Spinner(size: 13) } else {
                        Image(systemName: state.status == .failed ? "exclamationmark.circle" : "terminal")
                            .foregroundStyle(state.status == .failed ? Theme.negative : Theme.textSecondary)
                    }
                    Text(language.capitalized).font(.footnote.weight(.semibold))
                    Text(state.summary ?? "Running…").font(.footnote).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showCode ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            if showCode {
                CodeBlockView(language: language, code: code)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let output = state.output, !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output)
                        .font(.caption.monospaced())
                        .foregroundStyle(state.status == .failed ? Theme.negative : Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !media.isEmpty { ImageGrid(items: media) }
        }
        .padding(14)
        .glassCard(cornerRadius: 22)
    }
}

/// A `shell` call: the command line and what it printed, like a terminal. Open while its reply is
/// still going, then folded to one row so a chat with many requests stays short.
struct ShellCard: View {
    let state: ToolState
    /// The reply this call belongs to is still running.
    let isLive: Bool
    /// The user's own choice, which wins over following the reply.
    @State private var userOpen: Bool?
    @State private var showAll = false

    private var open: Bool { userOpen ?? isLive }

    var body: some View {
        let command = JSONValue.parse(state.arguments)?["command"]?.stringValue ?? ""
        let output = (state.output ?? "").trimmingCharacters(in: .newlines)
        let long = output.count > 600 || output.filter { $0 == "\n" }.count > 10
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.smooth) { userOpen = !open }
            } label: {
                HStack(spacing: 8) {
                    if state.status == .running { Spinner(size: 13) } else {
                        Image(systemName: state.status == .failed ? "exclamationmark.circle" : state.status == .declined ? "xmark.circle" : "terminal")
                            .foregroundStyle(state.status == .failed ? Theme.negative : Theme.textSecondary)
                    }
                    Text("Shell").font(.footnote.weight(.semibold))
                    if !open {
                        Text(Self.preview(command))
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            // The end of the path is the part that tells calls apart.
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    Text(state.status == .awaitingApproval ? "Waiting for approval" : state.summary ?? "Running…")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // While it waits, the command is in the approval popup; no need to show it twice.
            if open && state.status != .awaitingApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Text("$ " + command)
                        .foregroundStyle(Theme.textPrimary)
                    if !output.isEmpty {
                        Text(output)
                            .foregroundStyle(state.status == .failed ? Theme.negative : Theme.textSecondary)
                            .lineLimit(showAll ? nil : 10)
                    }
                    if long {
                        Button(showAll ? "Show less" : "Show all") {
                            withAnimation(Motion.smooth) { showAll.toggle() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .buttonStyle(.plain)
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, open ? 14 : 11)
        .glassCard(cornerRadius: 22)
        .animation(Motion.smooth, value: isLive)
    }

    /// What the row shows folded: the URL called (host and path), else the command itself.
    static func preview(_ command: String) -> String {
        let words = command.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        if let raw = words.first(where: { $0.contains("://") || ($0.contains(".") && $0.contains("/") && !$0.hasPrefix("-") && !$0.hasPrefix(".")) }),
           let url = URL(string: raw.contains("://") ? raw : "https://" + raw), let host = url.host() {
            return host + url.path()
        }
        return command
    }
}

/// Asks before a shell command runs, Claude Code style: the command, then Deny / Always / Allow.
/// Sits above the composer while any command in the chat is waiting.
struct ShellApprovalPopup: View {
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var app

    private var pending: [Message] {
        conversation.orderedMessages.filter {
            $0.toolState?.name == ToolName.shell.rawValue && $0.toolState?.status == .awaitingApproval
        }
    }

    var body: some View {
        let waiting = pending
        Group {
            if let message = waiting.first, let params = message.toolState?.approval {
                card(message, command: params.prompt, params: params, more: waiting.count - 1)
                    .id(message.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: waiting.map(\.id))
    }

    private func card(_ message: Message, command: String, params: ApprovalParams, more: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(Theme.textSecondary)
                Text("Run this command?").font(.subheadline.weight(.semibold))
                Spacer()
                if more > 0 {
                    Text("+\(more) more").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            ScrollView {
                Text("$ " + command)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 8) {
                Button("Deny") {
                    engine.resolveApproval(message, approve: false, params: params, in: conversation)
                }
                .buttonStyle(.glass)
                Spacer(minLength: 0)
                Button("Always allow") {
                    settings.askBeforeShell = false
                    engine.resolveApproval(message, approve: true, params: params, in: conversation)
                    // The rest of this turn's commands too: that's what "always" means.
                    for other in pending { engine.resolveApproval(other, approve: true, params: other.toolState?.approval ?? params, in: conversation) }
                    app.showToast("Commands will run without asking. Change it in Settings.")
                }
                .buttonStyle(.glass)
                Button {
                    engine.resolveApproval(message, approve: true, params: params, in: conversation)
                } label: {
                    Text("Allow")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 12)
    }
}

// MARK: - Artifacts

struct ArtifactCard: View {
    let artifactID: UUID
    let version: Int?
    let isUpdate: Bool
    @Environment(ChatEngine.self) private var engine
    @Environment(AppModel.self) private var app

    var body: some View {
        if let artifact = engine.artifact(id: artifactID) {
            Button {
                Haptics.tap()
                app.fullScreenArtifact = .artifact(artifactID, version)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.fillStrong)
                        Image(systemName: artifact.kind.icon).font(.body).foregroundStyle(Theme.textPrimary)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artifact.title).font(.display(.headline, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text("\(artifact.kind.label) · \(isUpdate ? "Updated to " : "")v\(version ?? artifact.latest?.number ?? 1)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(12)
                .glassCard(cornerRadius: 22, interactive: true)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Live preview of a tool call while its arguments stream in (e.g. a document being written).
struct ToolDraftCard: View {
    let name: String
    let arguments: String

    var body: some View {
        let fields = PartialJSON.stringFields(arguments)
        switch ToolName(rawValue: name) {
        case .createArtifact, .updateArtifact:
            let content = fields["content"] ?? ""
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Spinner(size: 14)
                    Text(fields["title"] ?? (name == ToolName.updateArtifact.rawValue ? "Editing document" : "Writing document"))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(content.count) chars").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                if !content.isEmpty {
                    Text(String(content.suffix(600)))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
                        .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                }
            }
            .padding(14)
            .glassCard(cornerRadius: 22)
        case .runCode:
            let code = fields["code"] ?? ""
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Spinner(size: 13)
                    Text("Writing \(fields["language"]?.capitalized ?? "code")").font(.footnote.weight(.medium)).foregroundStyle(Theme.textSecondary)
                }
                if !code.isEmpty {
                    CodeBlockView(language: fields["language"] ?? "python", code: code, isStreaming: true)
                }
            }
        case .shell:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spinner(size: 13)
                Text("$ " + (fields["command"] ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }
        default:
            ShimmerText(text: LivePhaseIndicator.label(for: name), font: .footnote.weight(.medium))
        }
    }
}
