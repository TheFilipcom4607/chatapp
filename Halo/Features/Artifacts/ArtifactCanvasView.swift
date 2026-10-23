import SwiftUI

struct ArtifactCanvasView: View {
    let artifactID: UUID
    let initialVersion: Int?

    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview", code = "Code", changes = "Changes"
        var id: String { rawValue }
    }

    @Environment(ChatEngine.self) private var engine
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var versionNumber: Int?
    @State private var mode: Mode = .preview
    @State private var shareURL: URL?
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Group {
                if let artifact = engine.artifact(id: artifactID), let version = artifact.version(versionNumber ?? initialVersion) {
                    content(artifact, version: version)
                        .toolbar { toolbar(artifact, version: version) }
                        .navigationTitle(artifact.title)
                } else {
                    ContentUnavailableView("Artifact not found", systemImage: "doc.questionmark")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.background)
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
    }

    @ViewBuilder
    private func content(_ artifact: Artifact, version: ArtifactVersion) -> some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(availableModes(artifact)) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch mode {
            case .preview:
                switch artifact.kind {
                case .markdown:
                    ScrollView {
                        MarkdownView(text: version.content)
                            .padding(20)
                            .textSelection(.enabled)
                    }
                case .code:
                    ScrollView { CodeBlockView(language: artifact.language ?? "", code: version.content).padding(16) }
                case .html, .react, .svg, .mermaid:
                    WebPreview(html: HTMLTemplates.page(kind: artifact.kind, content: version.content))
                        .ignoresSafeArea(edges: .bottom)
                        .id(version.number)
                }
            case .code:
                ScrollView {
                    CodeBlockView(language: codeLanguage(artifact), code: version.content).padding(16)
                }
            case .changes:
                DiffView(artifact: artifact, version: version)
            }
        }
        .animation(Motion.smooth, value: mode)
    }

    private func availableModes(_ artifact: Artifact) -> [Mode] {
        var modes: [Mode] = artifact.kind == .code ? [.preview] : [.preview, .code]
        if artifact.versions.count > 1 { modes.append(.changes) }
        return modes
    }

    private func codeLanguage(_ artifact: Artifact) -> String {
        switch artifact.kind {
        case .markdown: return "markdown"
        case .html: return "html"
        case .react: return "jsx"
        case .svg: return "html"
        case .mermaid: return "mermaid"
        case .code: return artifact.language ?? ""
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ artifact: Artifact, version: ArtifactVersion) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if artifact.versions.count > 1 {
                Menu {
                    ForEach(artifact.versions.reversed()) { v in
                        Button {
                            versionNumber = v.number
                            Haptics.selection()
                        } label: {
                            Text("v\(v.number)" + (v.summary.map { " · \($0)" } ?? ""))
                        }
                    }
                } label: {
                    Text("v\(version.number)").font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            Menu {
                Button { UIPasteboard.general.string = version.content; Haptics.success(); app.showToast("Copied") } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button { export(artifact, version, format: ExportService.defaultExtension(for: artifact)) } label: {
                    Label("Export .\(ExportService.defaultExtension(for: artifact))", systemImage: "doc")
                }
                if artifact.kind != .code {
                    Button { export(artifact, version, format: "html") } label: { Label("Export HTML", systemImage: "globe") }
                }
                Button { exportPDF(artifact, version) } label: { Label("Export PDF", systemImage: "doc.richtext") }
            } label: {
                if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

    private func export(_ artifact: Artifact, _ version: ArtifactVersion, format: String) {
        shareURL = try? ExportService.fileURL(for: artifact, version: version, format: format)
    }

    private func exportPDF(_ artifact: Artifact, _ version: ArtifactVersion) {
        exporting = true
        Task {
            let html: String
            switch artifact.kind {
            case .markdown: html = ExportService.markdownHTML(version.content, title: artifact.title)
            case .code: html = "<html><body><pre style='font:12px ui-monospace,monospace;white-space:pre-wrap'>\(HTMLTemplates.escape(version.content))</pre></body></html>"
            default: html = HTMLTemplates.page(kind: artifact.kind, content: version.content)
            }
            shareURL = try? await ExportService.pdf(html: html, name: artifact.title)
            exporting = false
        }
    }
}

struct DiffView: View {
    let artifact: Artifact
    let version: ArtifactVersion

    var body: some View {
        let previous = artifact.versions.last { $0.number < version.number }
        let rows = LineDiff.diff(old: previous?.content ?? "", new: version.content)
        let stats = LineDiff.stats(rows)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("v\(previous?.number ?? 0) → v\(version.number)").font(.subheadline.weight(.semibold))
                    Text("+\(stats.added)").foregroundStyle(Theme.positive)
                    Text("−\(stats.removed)").foregroundStyle(Theme.negative)
                    Spacer()
                }
                .font(.footnote.monospacedDigit())
                .padding(.bottom, 10)
                if let summary = version.summary {
                    Text(summary).font(.footnote).foregroundStyle(Theme.textSecondary).padding(.bottom, 10)
                }
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                            .frame(width: 12)
                            .foregroundStyle(row.kind == .added ? Theme.positive : row.kind == .removed ? Theme.negative : Theme.textTertiary)
                        Text(row.text.isEmpty ? " " : row.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(row.kind == .same ? Theme.textSecondary : Theme.textPrimary)
                    }
                    .font(.caption.monospaced())
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(row.kind == .added ? Theme.positive.opacity(0.12) : row.kind == .removed ? Theme.negative.opacity(0.12) : .clear)
                }
            }
            .padding(16)
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
