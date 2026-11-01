import SwiftUI
#if os(iOS)
import UIKit

/// The composer's text box. A UITextView rather than a TextField so that pasting a photo attaches
/// it (a TextField only takes text, so a copied image pasted nothing, or just its link).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var maxLines = 8
    /// Mac only: Return on a phone keyboard adds a line, and files arrive through the + menu.
    var onSubmit: () -> Void = {}
    var onDropFiles: ([URL]) -> Void = { _ in }
    let onPasteImages: ([PlatformImage]) -> Void

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
    var onPasteImages: (([PlatformImage]) -> Void)?

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
    static func pastedImages(from pasteboard: UIPasteboard = .general) -> [PlatformImage]? {
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
#else
import AppKit

/// The composer's text box on the Mac: an NSTextView, so Return sends (Shift-Return adds a line)
/// and pasted or dropped images and files attach instead of landing as text.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var maxLines = 8
    var onSubmit: () -> Void = {}
    var onDropFiles: ([URL]) -> Void = { _ in }
    let onPasteImages: ([PlatformImage]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ComposerNSTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = NSColor(Theme.textPrimary)
        view.insertionPointColor = NSColor(Theme.accent)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        view.onSubmit = onSubmit
        view.onPasteImages = onPasteImages
        view.onDropFiles = onDropFiles
        if view.string != text {
            view.string = text
            // Text set from outside (dictation, a draft) leaves the cursor at its end.
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        // Focus changes go out on the next turn of the run loop, as on iOS.
        let isFirst = view.window?.firstResponder === view
        if isFocused, !isFirst {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !isFocused, isFirst {
            DispatchQueue.main.async { view.window?.makeFirstResponder(nil) }
        }
    }

    /// Grows with the text up to `maxLines`, then scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView,
              let layout = view.layoutManager, let container = view.textContainer else { return nil }
        let width = proposal.width ?? 280
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let fitting = layout.usedRect(for: container).height
        let lineHeight = layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: NSFont.systemFontSize))
        let maxHeight = ceil(lineHeight * CGFloat(maxLines))
        return CGSize(width: width, height: max(ceil(lineHeight), min(ceil(fitting), maxHeight)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([PlatformImage]) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76   // Return, keypad Enter
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        // Mid-composition (Japanese, Chinese…) Return confirms the text instead.
        if isReturn, modifiers.isEmpty, !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// A plain-text view reads only text, so on its own it greys out Paste for a copied image and
    /// refuses dragged-in pictures. Files and images are what `paste` and drops take instead.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable {
            let board = NSPasteboard.general
            if Self.fileURLs(on: board) != nil || Self.pastedImages(from: board) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let files = Self.fileURLs(on: board) {
            onDropFiles?(files)
        } else if let images = Self.pastedImages(from: board) {
            onPasteImages?(images)
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let files = Self.fileURLs(on: board) {
            onDropFiles?(files)
            return true
        }
        if let images = Self.pastedImages(from: board) {
            onPasteImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Files copied in the Finder or dragged in. Checked first: a copied file also carries its icon as an image.
    static func fileURLs(on board: NSPasteboard) -> [URL]? {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    /// The copied images, unless the copy is really text that happens to carry an image (then the
    /// text is what was meant). A copied image often comes with its own link; that counts as an image.
    static func pastedImages(from board: NSPasteboard) -> [PlatformImage]? {
        guard board.canReadObject(forClasses: [NSImage.self]) else { return nil }
        if let string = board.string(forType: .string), !PastingTextView.isLink(string) { return nil }
        let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage]
        return images?.isEmpty == false ? images : nil
    }
}

/// Shared with iOS, where the text view is a UITextView.
enum PastingTextView {
    static func isLink(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace), let url = URL(string: s) else { return false }
        return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }
}
#endif
