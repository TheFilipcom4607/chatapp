import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct Composer: View {
    let conversation: Conversation?

    @Environment(AppModel.self) private var app
    @Environment(ChatEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @State private var text = ""
    @State private var attachments: [MediaItem] = []
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var dictation = DictationService()
    @State private var dictationBase = ""
    @FocusState private var focused: Bool
    @Namespace private var glass

    private var isBusy: Bool { conversation.map { engine.isBusy($0) } ?? false }
    private var modelID: String { conversation?.modelID ?? app.draft.modelID }
    private var model: ORModel? { catalog.model(modelID) }
    private var webSearch: Bool { conversation?.webSearch ?? app.draft.webSearch }
    private var effort: String? { conversation?.reasoningEffort ?? app.draft.reasoningEffort }
    private var canSend: Bool {
        !isBusy && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { item in
                            AttachmentThumb(item: item, size: 60)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        withAnimation(Motion.snappy) { attachments.removeAll { $0.id == item.id } }
                                        MediaStore.delete(item)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.body)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = dictation.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }

            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(dictation.isRecording ? "Listening…" : "Ask anything", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .font(.body)
                        .focused($focused)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .submitLabel(.return)

                    HStack(spacing: 8) {
                        attachMenu
                        SearchChip(isOn: webSearch) { toggleSearch() }
                        if let model, model.supportsReasoning, !model.reasoningEfforts.isEmpty {
                            EffortMenu(efforts: model.reasoningEfforts, mandatory: model.reasoning?.mandatory == true,
                                       selection: effort) { setEffort($0) }
                        }
                        Spacer(minLength: 0)
                        micButton
                        sendButton
                    }
                }
                .padding(12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .animation(Motion.snappy, value: attachments.count)
        .animation(Motion.snappy, value: isBusy)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .plainText, .sourceCode, .json, .commaSeparatedText, .image, .audio, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image, let data = ImageDownscaler.jpegData(from: image),
                   let item = try? MediaStore.save(data, kind: .image, mimeType: "image/jpeg", ext: "jpg", originalName: "Photo") {
                    withAnimation(Motion.snappy) { attachments.append(item) }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: dictation.transcript) { _, t in
            guard dictation.isRecording || !t.isEmpty else { return }
            text = dictationBase.isEmpty ? t : dictationBase + " " + t
        }
        .onChange(of: app.composerFocusTick) { _, _ in
            if let prefill = app.composerPrefill {
                text = prefill
                app.composerPrefill = nil
            }
            focused = true
        }
    }

    // MARK: Pieces

    private var attachMenu: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { showFiles = true } label: { Label("Files & PDFs", systemImage: "doc") }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private var micButton: some View {
        Button {
            if !dictation.isRecording { dictationBase = text.trimmingCharacters(in: .whitespaces) }
            Task { await dictation.toggle() }
        } label: {
            Image(systemName: dictation.isRecording ? "waveform" : "mic")
                .font(.body.weight(.semibold))
                .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                .frame(width: 36, height: 36)
                .foregroundStyle(dictation.isRecording ? Theme.onAccent : Theme.textPrimary)
                .background { if dictation.isRecording { Circle().fill(Theme.accent) } }
                .scaleEffect(1 + CGFloat(dictation.level) * 0.2)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: dictation.level)
    }

    private var sendButton: some View {
        Group {
            if isBusy {
                Button {
                    if let conversation { engine.stop(conversation) }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(Theme.onAccent)
                        .background(Circle().fill(Theme.accent))
                }
                .glassEffectID("send", in: glass)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(canSend ? Theme.onAccent : Theme.textTertiary)
                        .background(Circle().fill(canSend ? Theme.accent : Theme.fillStrong))
                }
                .disabled(!canSend)
                .glassEffectID("send", in: glass)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Actions

    private func send() {
        if dictation.isRecording { dictation.stop() }
        let message = text
        let media = attachments
        text = ""
        attachments = []
        dictationBase = ""
        if let conversation {
            engine.send(text: message, media: media, in: conversation)
        } else {
            app.sendFromDraft(text: message, media: media)
        }
    }

    private func toggleSearch() {
        Haptics.selection()
        if let conversation { conversation.webSearch.toggle() } else { app.draft.webSearch.toggle() }
    }

    private func setEffort(_ value: String?) {
        Haptics.selection()
        if let conversation { conversation.reasoningEffort = value } else { app.draft.reasoningEffort = value }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                   let jpeg = ImageDownscaler.jpegData(from: image),
                   let saved = try? MediaStore.save(jpeg, kind: .image, mimeType: "image/jpeg", ext: "jpg", originalName: "Photo") {
                    withAnimation(Motion.snappy) { attachments.append(saved) }
                }
            }
            photoItems = []
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let name = url.lastPathComponent
            var item: MediaItem?
            if type.conforms(to: .pdf) {
                item = try? MediaStore.save(data, kind: .pdf, mimeType: "application/pdf", ext: "pdf", originalName: name)
            } else if type.conforms(to: .image), let image = UIImage(data: data), let jpeg = ImageDownscaler.jpegData(from: image) {
                item = try? MediaStore.save(jpeg, kind: .image, mimeType: "image/jpeg", ext: "jpg", originalName: name)
            } else if type.conforms(to: .audio) {
                let ext = url.pathExtension.lowercased()
                item = try? MediaStore.save(data, kind: .audio, mimeType: ext == "mp3" ? "audio/mpeg" : "audio/\(ext)", ext: ext, originalName: name)
            } else if String(data: data, encoding: .utf8) != nil {
                item = try? MediaStore.save(data, kind: .text, mimeType: "text/plain", ext: url.pathExtension.isEmpty ? "txt" : url.pathExtension, originalName: name)
            }
            if let item { withAnimation(Motion.snappy) { attachments.append(item) } }
        }
    }
}

struct SearchChip: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text("Search")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background { if isOn { Capsule().fill(Theme.fillStrong) } }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .animation(Motion.snappy, value: isOn)
    }
}

struct EffortMenu: View {
    let efforts: [String]
    let mandatory: Bool
    let selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            Button { onSelect(nil) } label: {
                if selection == nil { Label("Default", systemImage: "checkmark") } else { Text("Default") }
            }
            ForEach(efforts, id: \.self) { e in
                Button { onSelect(e) } label: {
                    if selection == e { Label(Self.label(e), systemImage: "checkmark") } else { Text(Self.label(e)) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                Text(selection.map(Self.label) ?? "Think")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(selection == nil ? Theme.textSecondary : Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background { if selection != nil { Capsule().fill(Theme.fillStrong) } }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    static func label(_ effort: String) -> String {
        switch effort {
        case "none": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        default: return effort.capitalized
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onImage(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImage(nil)
            parent.dismiss()
        }
    }
}
