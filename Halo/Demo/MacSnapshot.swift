#if os(macOS) && DEBUG
import AppKit
import SwiftUI

/// UI review without screen access (a locked or sleeping Mac blocks window screenshots): launched
/// with `-snapshot`, the app draws its own window into `tmp/snapshot.png` in its container a few
/// seconds after launch, and an open sheet into `tmp/snapshot-sheet.png`. `kill -USR1` takes
/// another, e.g. after driving a menu item with System Events.
@MainActor
enum MacSnapshot {
    static func scheduleIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-snapshot") else { return }
        let delay = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 4
        // While the Mac is locked SwiftUI doesn't open the window at all, so host the same root in one of ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !NSApp.windows.contains(where: { $0.contentView != nil && $0.frame.width > 200 }) else { return }
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Halo"
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: HaloApp.root)
            window.orderFront(nil)
            offscreen = window
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { writeAll() }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { writeAll() }
        source.resume()
        signalSource = source
    }

    private static var offscreen: NSWindow?
    private static var signalSource: DispatchSourceSignal?

    static func writeAll() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        // While the Mac is locked a new window exists but isn't visible yet; it still draws.
        let candidates = NSApp.windows.filter { $0.sheetParent == nil && $0.contentView != nil && $0.frame.width > 200 }
        guard let window = candidates.first(where: \.isVisible) ?? candidates.first else {
            let names = NSApp.windows.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: "\n")
            try? "no window\n\(names)".write(to: dir.appendingPathComponent("snapshot.txt"), atomically: true, encoding: .utf8)
            return
        }
        write(window, to: dir.appendingPathComponent("snapshot.png"))
        if let sheet = window.attachedSheet { write(sheet, to: dir.appendingPathComponent("snapshot-sheet.png")) }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        // The frame view includes the title bar; the content view alone would leave it out.
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
