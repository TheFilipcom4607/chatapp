import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's "Halo": shows what's being shared, takes an optional note and leaves it all
/// in the App Group inbox for the app to put in a new chat.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "Halo", code: NSUserCancelledError))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }
}

@MainActor
@Observable
final class ShareModel {
    var text: String?
    var url: URL?
    var images: [UIImage] = []
    var note = ""
    var isLoading = true
    var saved = false
    var error: String?
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    static let maxImages = 6

    var isEmpty: Bool { (text ?? "").isEmpty && url == nil && images.isEmpty }

    func load(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), images.count < Self.maxImages {
                if let data = try? await provider.loadData(UTType.image), let image = UIImage(data: data) {
                    images.append(image)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), url == nil {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
                   let found = (item as? URL) ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }),
                   !found.isFileURL {
                    url = found
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), text == nil {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                    text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                }
            }
        }
        // Safari shares a page's address as text too; keep it once.
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), t == url?.absoluteString { text = nil }
        isLoading = false
    }

    func send() {
        let jpegs = images.compactMap { Self.jpeg($0) }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SharedItem(text: text, url: url?.absoluteString, note: trimmedNote.isEmpty ? nil : trimmedNote)
        do {
            try ShareInbox.write(item, images: jpegs)
            withAnimation { saved = true }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fits within 2048 points on the long side, as the app's own attachments do.
    private static func jpeg(_ image: UIImage) -> Data? {
        let size = image.size
        let scale = min(1, 2048 / max(size.width, size.height, 1))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.jpegData(compressionQuality: 0.85)
    }
}

private extension NSItemProvider {
    func loadData(_ type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var noteFocused: Bool

    private let accent = Color(red: 0.97, green: 0.80, blue: 0.55)

    var body: some View {
        NavigationStack {
            Group {
                if model.saved {
                    saved
                } else {
                    form
                }
            }
            .navigationTitle("Halo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.saved {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { model.cancel() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Send to Halo") { model.send() }
                            .fontWeight(.semibold)
                            .disabled(model.isLoading || (model.isEmpty && model.note.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                }
            }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        Form {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            if !model.images.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(model.images.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
            }
            if let url = model.url {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.host ?? url.absoluteString).font(.subheadline.weight(.semibold))
                            Text(url.absoluteString.removingPercentEncoding ?? url.absoluteString)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    } icon: { Image(systemName: "link") }
                }
            }
            if let text = model.text, !text.isEmpty {
                Section {
                    Text(text).font(.callout).lineLimit(8)
                }
            }
            Section {
                TextField("Add a question or note (optional)", text: $model.note, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($noteFocused)
            } footer: {
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("It waits in a new chat in Halo, where you can check it and send it.")
                }
            }
        }
    }

    private var saved: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(accent)
            Text("Saved for Halo").font(.title3.weight(.semibold))
            Text("Open Halo to send it.")
                .foregroundStyle(.secondary)
            Button { model.finish() } label: {
                Text("Done").fontWeight(.semibold).foregroundStyle(.black).padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}
