#if os(macOS)
import AppKit
import SwiftUI

/// The app's own window, for what asks the window's size (subtitles sized to it, pictures
/// asked for at its scale): the Mac's key window, else the one in front.
@MainActor
enum AppWindow {
    static var current: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    static var size: CGSize {
        current?.contentView?.bounds.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
    }

    static var scale: CGFloat { current?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The window the app is in: the first of its pages to open. Any other is closed as it
    /// comes (MacWindowSetup).
    static weak var main: NSWindow?
}

/// What's set on the app's window itself, as it comes: its smallest size (asked of
/// SwiftUI as a frame on the page, the window never opened at all), and no tabs. The app
/// is one window: a second (a link opening one, or macOS bringing back several from an
/// earlier run) is closed, and the first comes forward instead.
struct MacWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Watcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if let main = AppWindow.main, main !== window, main.isVisible || main.isMiniaturized {
                DispatchQueue.main.async {
                    window.close()
                    if main.isMiniaturized { main.deminiaturize(nil) }
                    main.makeKeyAndOrderFront(nil)
                }
                return
            }
            AppWindow.main = window
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.tabbingMode = .disallowed
        }
    }
}
#endif
