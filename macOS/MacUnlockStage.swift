#if os(macOS)
import AppKit
import SwiftUI

/// Where the unlock screen is shown on the Mac: a panel of its own, centred over the
/// app's window and kept in front of it (the player's included), as the iPhone's and
/// the Apple TV's is a window over everything.
@MainActor
final class UnlockStage {
    static let shared = UnlockStage()
    private var panel: NSPanel?

    func show() {
        guard panel == nil else { return }
        let host = NSHostingController(rootView: UnlockView { [weak self] in self?.hide() }
            .preferredColorScheme(.dark)
            // No grey bezels behind its pills (the Mac's default button).
            .buttonStyle(.borderless)
            .frame(minWidth: 640, minHeight: 560))
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        // Closed from its own button, it's as if the screen said it was done.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        if let parent = AppWindow.current {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        panel.close()
    }

    private func closed() {
        guard panel != nil else { return }
        panel = nil
        AppWindow.current?.makeKey()
        Unlock.shared.finished()
    }
}
#endif
