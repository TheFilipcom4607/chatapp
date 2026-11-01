import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A message's raw text, where any part of it can be selected and copied.
struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .background(Theme.background)
                .navigationTitle("Select text")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Clipboard.copy(text)
                            Haptics.success()
                            dismiss()
                        } label: { Text("Copy all") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                }
                .macSheetBar("Select text") {
                    Button {
                        Clipboard.copy(text)
                        dismiss()
                    } label: { Text("Copy all") }
                } trailing: {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }
}

#if os(iOS)
/// A read-only text view: SwiftUI's own text selection only copies the whole string, while this
/// gives the usual handles for picking a word or a few lines.
struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = [.link]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.text = text
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Theme.textPrimary)
    }
}
#else
/// A read-only NSTextView, so a drag picks any run of words across lines as in any Mac app.
struct SelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.isRichText = false
            view.textContainerInset = NSSize(width: 12, height: 12)
            view.selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.35)]
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = NSColor(Theme.textPrimary)
    }
}
#endif
