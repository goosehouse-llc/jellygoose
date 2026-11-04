#if os(macOS)
import AppKit
import SwiftUI

/// Where a film plays on the Mac: a window of its own, as the iPhone's player is on a
/// stage of its own (`PlayerStage`). It opens over the app's window at its size, goes
/// full screen by itself (F, a double click, or the green button) and leaves the app's
/// window free beneath it. Closing it (its button, ⌘W) closes the player the way the
/// player's own button does, so where the film got to is filed.
@MainActor
final class MacPlayerStage: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = MacPlayerStage()
    /// Posted to have the player close itself the way its own button does.
    static let closeAsked = Notification.Name("goosetv.mac.player.closeAsked")
    /// From the menu bar's Controls menu: play or pause, and skip (the seconds, an Int32,
    /// as the object).
    static let playPauseAsked = Notification.Name("goosetv.mac.player.playPauseAsked")
    static let skipAsked = Notification.Name("goosetv.mac.player.skipAsked")

    /// Whether a film is up, and playing: for the Controls menu.
    @Published private(set) var showing = false
    @Published var filmPlaying = false

    private var window: NSWindow?
    /// The film's window, while there is one.
    var stageWindow: NSWindow? { window }
    private var playing: String?
    private var whenGone: (() -> Void)?
    /// Set while the player itself is closing the window, so the close isn't asked again.
    private var closingForPlayer = false

    func open(_ player: PlayerView, id: String, app: AppState, whenGone: @escaping () -> Void) {
        if playing == id, let window {
            window.makeKeyAndOrderFront(nil)
            self.whenGone = whenGone
            return
        }
        strike()
        let shown = player
            .environment(\.playerClose, { [weak self] in self?.close() } as (() -> Void)?)
            // What the app's own window is given at its root.
            .environmentObject(app)
            .environment(\.appState, app)
            .themed(app.shownTheme)
            .preferredColorScheme(.dark)
            .font(.app(29))
            .buttonStyle(.borderless)
            .ignoresSafeArea()
        let host = NSHostingController(rootView: shown)
        host.sizingOptions = []
        let stage = NSWindow(contentViewController: host)
        stage.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        stage.titlebarAppearsTransparent = true
        stage.titleVisibility = .hidden
        stage.title = String(localized: "Player", comment: "Name of the Mac window a film plays in")
        stage.backgroundColor = .black
        stage.appearance = NSAppearance(named: .darkAqua)
        stage.collectionBehavior = [.fullScreenPrimary]
        stage.isReleasedWhenClosed = false
        stage.delegate = self
        stage.setFrame(Self.frame(over: AppWindow.current), display: false)
        stage.contentMinSize = NSSize(width: 480, height: 270)
        stage.makeKeyAndOrderFront(nil)
        window = stage
        playing = id
        showing = true
        self.whenGone = whenGone
    }

    /// The film is done with: the player's own close, or Escape.
    func close() {
        guard let stage = window else { return }
        let gone = whenGone
        window = nil
        playing = nil
        showing = false
        filmPlaying = false
        whenGone = nil
        closingForPlayer = true
        // Out of full screen first, so the app's window isn't left on a full-screen space.
        if stage.styleMask.contains(.fullScreen) { stage.toggleFullScreen(nil) }
        stage.close()
        closingForPlayer = false
        stage.contentViewController = nil
        gone?()
    }

    /// Takes the window down at once, for the next film to go up.
    private func strike() {
        guard let stage = window else { return }
        window = nil
        playing = nil
        showing = false
        filmPlaying = false
        let gone = whenGone
        whenGone = nil
        closingForPlayer = true
        stage.close()
        closingForPlayer = false
        stage.contentViewController = nil
        gone?()
    }

    /// Its close button or ⌘W: the player is asked to close, files where it got to, and
    /// closes the window itself.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingForPlayer { return true }
        NotificationCenter.default.post(name: Self.closeAsked, object: nil)
        return false
    }

    /// The app's window's frame, else a 16:9 window in the middle of the screen.
    private static func frame(over parent: NSWindow?) -> NSRect {
        if let parent, parent.isVisible, !parent.styleMask.contains(.fullScreen) { return parent.frame }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, screen.width * 0.8), height = width * 9 / 16
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }
}

/// The Mac's way of showing a film: in the player's own window (see `MacPlayerStage`).
struct MacStagedPlayer: ViewModifier {
    @Binding var item: BaseItem?
    let player: (BaseItem) -> PlayerView
    @EnvironmentObject private var app: AppState

    func body(content: Content) -> some View {
        content.onChange(of: item?.id) { _, _ in
            guard let item else { return }
            let asked = $item
            MacPlayerStage.shared.open(player(item), id: item.id, app: app) { asked.wrappedValue = nil }
        }
    }
}
#endif
