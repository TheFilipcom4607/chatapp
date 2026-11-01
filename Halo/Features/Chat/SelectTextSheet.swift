import SwiftUI
#if os(iOS)
import UIKit
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
/// On the Mac, SwiftUI's text selection already picks words and lines.
struct SelectableText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
    }
}
#endif
