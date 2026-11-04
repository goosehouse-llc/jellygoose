#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// A right click (or a Control-click) on the view: the Mac's way to the menu a long
    /// press opens elsewhere. Every other click goes through to the view as before.
    func onSecondaryClick(_ action: @escaping () -> Void) -> some View {
        overlay(SecondaryClickCatcher(action: action))
    }
}

/// A transparent layer over a view that answers right clicks only: for anything else it
/// isn't there (hitTest passes the click on), so the view under it is clicked, hovered and
/// scrolled as it was.
private struct SecondaryClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: (() -> Void)?

        private static func isSecondary(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            return event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            Self.isSecondary(NSApp.currentEvent) ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { action?() } else { super.mouseDown(with: event) }
        }
    }
}
#endif
