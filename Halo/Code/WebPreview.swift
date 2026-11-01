import SwiftUI
import WebKit

/// Live HTML preview.
struct WebPreview {
    let html: String
    var transparent = false

    private func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.isOpaque = !transparent
        web.backgroundColor = transparent ? .clear : .white
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        #else
        if transparent { web.setValue(false, forKey: "drawsBackground") }
        #endif
        #if DEBUG
        web.isInspectable = true
        #endif
        web.loadHTMLString(html, baseURL: URL(string: "https://halo.local/"))
        context.coordinator.lastHTML = html
        return web
    }

    private func update(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        web.loadHTMLString(html, baseURL: URL(string: "https://halo.local/"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML = "" }
}

#if os(iOS)
extension WebPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context: context) }
}
#else
extension WebPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context: context) }
}
#endif

struct CodePreviewSheet: View {
    let language: String
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPreview(html: HTMLTemplates.page(language: language, code: code))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Preview")
                .inlineNavigationTitle()
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
    @State private var images: [PlatformImage] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CodeBlockView(language: language, code: code)
                    HStack(spacing: 8) {
                        if running { Spinner(size: 13); ShimmerText(text: language == "python" ? "Running (first Python run downloads the runtime)" : "Running") }
                        else if let result {
                            Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.error == nil ? Theme.textSecondary : Theme.negative)
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
                        Image(platformImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Run \(language.capitalized)")
            .inlineNavigationTitle()
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
        images = r.images.compactMap(PlatformImage.init(data:))
        running = false
        r.error == nil ? Haptics.success() : Haptics.error()
    }
}
