#if os(macOS)
import AppKit

/// The picture, as far as the keyboard and trackpad are concerned: the Mac's side of
/// `RemoteSurface`, turning what a Mac has into the same actions the Apple TV's remote
/// and the iPad's touches give. Left and right arrows click or, held, scrub (timed as
/// the remote's are); up and down are the remote's; space plays and pauses; Return
/// selects; F goes full screen and back; Escape leaves full screen, or else is the
/// remote's Back (a menu put away, then the film closed). A click is the iPad's tap (the
/// controls up or away); a double click goes full screen and back, as in every Mac
/// player; a sideways swipe on the trackpad scrubs, as a swipe on the remote does.
final class RemoteSurfaceView: NSView {
    var actions = RemoteSurface.Actions()

    private var holdTimer: Timer?
    private var holdStart: Date?
    private var lastTick: Date?
    private var holdDirection: Double = 0
    private var held = false
    /// How long a press has to last to be a hold rather than a click.
    private static let holdAfter: TimeInterval = 0.35

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    /// On screen, it takes the keys, so the arrows and space reach the player at once.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: if !event.isARepeat { startHolding(-1) }     // left
        case 124: if !event.isARepeat { startHolding(1) }      // right
        case 126: actions.up()
        case 125: actions.down()
        case 49: if !event.isARepeat { actions.playPause() }  // space
        case 36, 76: if !event.isARepeat { actions.select() } // Return, Enter
        case 3 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:   // F
            if !event.isARepeat { fullScreenWindow?.toggleFullScreen(nil) }
        case 53:                                                // Escape
            guard !event.isARepeat else { return }
            if let window = fullScreenWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            else { actions.menu() }
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124: finishHolding()
        default: super.keyUp(with: event)
        }
    }

    /// The window that goes full screen: a cover's sheet takes its window with it.
    private var fullScreenWindow: NSWindow? { window?.sheetParent ?? window }

    // MARK: Mouse and trackpad

    override func mouseUp(with event: NSEvent) {
        let x = Double(convert(event.locationInWindow, from: nil).x / max(bounds.width, 1))
        if event.clickCount == 2 { fullScreenWindow?.toggleFullScreen(nil) } else if event.clickCount == 1 { actions.touch(x) }
    }

    /// A sideways swipe of two fingers scrubs, as a finger on the remote does.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event); return
        }
        actions.swipe(-event.scrollingDeltaX)
    }

    // MARK: Holding an arrow

    private func startHolding(_ direction: Double) {
        stopHolding()
        holdDirection = direction
        holdStart = Date()
        held = false
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func holdTick() {
        guard let holdStart else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(holdStart)
        guard elapsed >= Self.holdAfter else { return }
        let step = lastTick.map { now.timeIntervalSince($0) } ?? (1.0 / 30)
        lastTick = now
        held = true
        actions.hold(holdDirection, elapsed - Self.holdAfter, step)
    }

    /// Let go: a click if it never became a hold.
    private func finishHolding() {
        let wasHeld = held
        let direction = holdDirection
        stopHolding()
        if !wasHeld, direction != 0 { actions.tap(direction) }
    }

    func stopHolding() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        lastTick = nil
        held = false
        holdDirection = 0
    }
}
#endif
