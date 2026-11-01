import SwiftUI
#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#else
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

/// The bits of UIImage's API the app uses, so shared code reads the same on both platforms.
extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    /// Pixels per point, like UIImage.scale.
    var scale: CGFloat {
        guard let cg = cgImage, size.width > 0 else { return 1 }
        return CGFloat(cg.width) / size.width
    }

    func pngData() -> Data? { bitmap?.representation(using: .png, properties: [:]) }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmap?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    /// A copy scaled to `size` pixels (UIImage's version keeps the aspect ratio; every caller asks for a square).
    func preparingThumbnail(of size: CGSize) -> NSImage? {
        guard let cg = cgImage else { return nil }
        return NSImage.render(size: size) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        }
    }

    private var bitmap: NSBitmapImageRep? { cgImage.map(NSBitmapImageRep.init(cgImage:)) }
}
#endif

extension Image {
    init(platformImage image: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

extension PlatformImage {
    /// Draws into a fresh bitmap of `size` pixels (origin top-left on iOS, bottom-left on the Mac).
    static func render(size: CGSize, _ draw: (CGContext) -> Void) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        #else
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(size: size) }
        draw(ctx)
        return ctx.makeImage().map(NSImage.init(cgImage:)) ?? NSImage(size: size)
        #endif
    }
}

extension Color {
    /// The system's placeholder gray, for hints drawn over an empty text box.
    static var placeholderText: Color {
        #if canImport(UIKit)
        Color(uiColor: .placeholderText)
        #else
        Color(nsColor: .placeholderTextColor)
        #endif
    }
}

/// Where Halo keeps its files. iOS gives each app its own folders; an unsandboxed Mac app shares
/// the user's Library with every other app, so Halo nests its files in a folder of its own there.
enum AppFolders {
    static var support: URL { folder(.applicationSupportDirectory) }
    static var caches: URL { folder(.cachesDirectory) }

    private static func folder(_ kind: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask)[0]
        #if os(macOS)
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Halo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #else
        return base
        #endif
    }
}

/// The system clipboard.
@MainActor
enum Clipboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    static func copy(_ image: PlatformImage) {
        #if canImport(UIKit)
        UIPasteboard.general.image = image
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #endif
    }
}

/// Keeping a generated image: the photo library on iOS, the Downloads folder on the Mac.
@MainActor
enum ImageSaver {
    #if os(iOS)
    static let actionTitle = "Save to Photos"
    #else
    static let actionTitle = "Save to Downloads"
    #endif

    /// Saves `item` (shown as `image`) and returns what to tell the user.
    static func save(_ image: PlatformImage, item: MediaItem) -> String {
        #if os(iOS)
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        return "Saved to Photos"
        #else
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let ext = MediaStore.url(for: item).pathExtension
        var target = folder.appendingPathComponent("Halo \(item.refID).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("Halo \(item.refID) \(n).\(ext)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: MediaStore.url(for: item), to: target)
            return "Saved to Downloads"
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
        #endif
    }
}

/// iOS-only modifiers that have no Mac counterpart, so call sites don't need `#if` around each.
#if os(iOS)
extension View {
    /// Lists already wrap their headers and footers on iOS (see the Mac's version).
    func wrapsInList() -> some View { self }
}
#endif

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension View {
    /// The Mac's defaults differ from iOS: forms go two-column, and buttons and menus get bezels.
    /// This brings them back to the iOS look the app is designed around. Sheets need it again,
    /// since they don't inherit these styles.
    func platformDefaults() -> some View {
        #if os(macOS)
        formStyle(.grouped)
            .textFieldStyle(.plain)
            .buttonStyle(.borderless)
            .menuStyle(.button)
            .menuIndicator(.hidden)
        #else
        self
        #endif
    }

    /// Sheets on the Mac size to their content, which collapses lists and overflows long forms.
    func sheetFrame(width: CGFloat = 640, height: CGFloat = 720) -> some View {
        #if os(macOS)
        modifier(MacSheet(width: width, height: height))
        #else
        self
        #endif
    }

    /// A search field that stays visible: pinned under the title on iOS, and on the Mac a field of
    /// its own under the sheet's bar (Mac sheets have no toolbar left to hold one, see `macSheetBar`).
    func pinnedSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        safeAreaInset(edge: .top, spacing: 0) { MacSearchField(text: text, prompt: prompt) }
        #endif
    }

    #if os(iOS)
    /// The Mac's stand-in for a sheet's navigation bar; iOS keeps its own.
    func macSheetBar<Leading: View, Trailing: View>(_ title: String = "", back: Bool = false,
                                                    @ViewBuilder leading: () -> Leading = { EmptyView() },
                                                    @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        self
    }

    /// The same bar with a control in the middle instead of a title.
    func macSheetBar<Center: View>(back: Bool = false, @ViewBuilder center: () -> Center) -> some View {
        self
    }
    #else
    /// A Mac sheet shows only the title and back button of its toolbar and drops every other
    /// item (close, save, sort…), so on the Mac a sheet's screens hide that bar and draw this one:
    /// the title centered, `back` and `leading` on the left, `trailing` on the right.
    func macSheetBar<Leading: View, Trailing: View>(_ title: String = "", back: Bool = false,
                                                    @ViewBuilder leading: () -> Leading = { EmptyView() },
                                                    @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        modifier(MacSheetBar(back: back, leading: leading(), center: Text(title).font(.headline).lineLimit(1),
                             trailing: trailing()))
    }

    /// The same bar with a control in the middle instead of a title.
    func macSheetBar<Center: View>(back: Bool = false, @ViewBuilder center: () -> Center) -> some View {
        modifier(MacSheetBar(back: back, leading: EmptyView(), center: center(), trailing: EmptyView()))
    }
    #endif
}

#if os(macOS)
/// A window-like size for a sheet, the app's styles (sheets don't inherit them), and Escape to close.
private struct MacSheet: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .frame(minWidth: width * 0.8, idealWidth: width, minHeight: height * 0.7, idealHeight: height)
            .platformDefaults()
            .onExitCommand { dismiss() }
    }
}

private struct MacSheetBar<Leading: View, Center: View, Trailing: View>: ViewModifier {
    let back: Bool
    let leading: Leading
    let center: Center
    let trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .windowToolbar)
            .safeAreaInset(edge: .top, spacing: 0) {
                CenteredBarLayout {
                    HStack(spacing: 8) {
                        if back {
                            // In a pushed screen, dismiss goes back a level.
                            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("Back")
                        }
                        leading
                    }
                    center
                    HStack(spacing: 8) { trailing }
                }
                .buttonStyle(SheetBarButtonStyle())
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(Theme.background)
            }
    }
}

/// The bar's buttons: a glass circle around an icon, a capsule around words, as iOS draws them.
private struct SheetBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SheetBarButton(configuration: configuration)
    }

    private struct SheetBarButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        }
    }
}

/// The Mac's search field for a sheet's list, styled like the sidebar's.
private struct MacSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.fill, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Theme.background)
    }
}

/// iOS toolbar placements, mapped to where the Mac puts the same kind of item.
extension ToolbarItemPlacement {
    static let topBarLeading = ToolbarItemPlacement.navigation
    static let topBarTrailing = ToolbarItemPlacement.primaryAction
}

/// Stand-ins for iOS-only modifiers: no-ops on the Mac, or the nearest Mac equivalent.
enum TextInputAutocapitalization { case never, words, sentences, characters }
enum KeyboardType { case `default`, URL, decimalPad, numberPad, emailAddress }
enum ListSectionSpacing { case `default`, compact }

extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .automatic }
}

extension View {
    func textInputAutocapitalization(_ style: TextInputAutocapitalization?) -> some View { self }
    func keyboardType(_ type: KeyboardType) -> some View { self }
    func listSectionSpacing(_ spacing: ListSectionSpacing) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }

    /// A Mac list cuts its section headers and footers to one line; this one wraps, as on iOS.
    func wrapsInList() -> some View { lineLimit(nil).fixedSize(horizontal: false, vertical: true) }

    /// The Mac has no full-screen covers; a sheet is the closest.
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().sheetFrame(width: 960, height: 760) }
    }

    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                           @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).sheetFrame(width: 960, height: 760) }
    }
}
#endif
