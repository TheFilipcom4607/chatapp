import SwiftUI
import UIKit

/// The composer's text box. A UITextView rather than a TextField so that pasting a photo attaches
/// it (a TextField only takes text, so a copied image pasted nothing, or just its link).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var maxLines = 8
    let onPasteImages: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Theme.textPrimary)
        view.tintColor = UIColor(Theme.accent)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.keyboardDismissMode = .interactive
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        if view.text != text {
            view.text = text
            // Text set from outside (dictation, a draft) leaves the cursor at its end.
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        // Focus changes go out on the next turn of the run loop: changing first responder inside an
        // update can re-enter SwiftUI's update.
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    /// Grows with the text up to `maxLines`, then scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = view.font?.lineHeight ?? 22
        let maxHeight = ceil(lineHeight * CGFloat(maxLines))
        let scrolls = fitting > maxHeight
        if view.isScrollEnabled != scrolls {
            DispatchQueue.main.async { view.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: max(ceil(lineHeight), min(fitting, maxHeight)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            if parent.text != view.text { parent.text = view.text }
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class PastingTextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Only `hasImages` here: reading the pasteboard's contents outside a paste asks the user.
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let images = Self.pastedImages(), !images.isEmpty {
            onPasteImages?(images)
        } else {
            super.paste(sender)
        }
    }

    /// The copied images, unless the copy is really text that happens to carry an image (then the
    /// text is what was meant). A copied image often comes with its own link; that counts as an image.
    static func pastedImages(from pasteboard: UIPasteboard = .general) -> [UIImage]? {
        guard pasteboard.hasImages else { return nil }
        if pasteboard.hasStrings, let string = pasteboard.string, !isLink(string) { return nil }
        return pasteboard.images
    }

    static func isLink(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace), let url = URL(string: s) else { return false }
        return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }
}
