import SwiftUI
import WebKit

/// Live HTML preview.
struct WebPreview: UIViewRepresentable {
    let html: String
    var transparent = false

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = !transparent
        web.backgroundColor = transparent ? .clear : .white
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        #if DEBUG
        web.isInspectable = true
        #endif
        web.loadHTMLString(html, baseURL: URL(string: "https://halo.local/"))
        context.coordinator.lastHTML = html
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: URL(string: "https://halo.local/"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML = "" }
}

struct CodePreviewSheet: View {
    let language: String
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPreview(html: HTMLTemplates.page(language: language, code: code))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                }
        }
    }
}

struct CodeRunSheet: View {
    let language: String
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var result: CodeRunResult?
    @State private var running = true
    @State private var images: [UIImage] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CodeBlockView(language: language, code: code)
                    HStack(spacing: 8) {
                        if running { AuroraSpinner(size: 14); ShimmerText(text: language == "python" ? "Running Python (first run loads Pyodide)…" : "Running…") }
                        else if let result {
                            Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.error == nil ? Theme.teal : .orange)
                            Text(String(format: "Finished in %.2fs", result.duration)).font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let result {
                        Text(result.consoleText)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Run \(language.capitalized)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await run() } } label: { Image(systemName: "arrow.clockwise") }.disabled(running)
                }
            }
            .task { await run() }
        }
    }

    private func run() async {
        running = true
        let r = await CodeRunner.run(language: language, code: code)
        result = r
        images = r.images.compactMap(UIImage.init(data:))
        running = false
        r.error == nil ? Haptics.success() : Haptics.error()
    }
}
