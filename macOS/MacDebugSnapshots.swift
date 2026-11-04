#if os(macOS) && DEBUG
import AppKit

/// For looking at the Mac app from a script, without screen-recording permission: with
/// GOOSETV_MAC_SNAP=<folder name> in its environment, the app writes a picture of its front
/// window there every few seconds (snap-01.png, snap-02.png, ...), as many as
/// GOOSETV_MAC_SNAP_COUNT says (20 if it says nothing). Debug builds only.
@MainActor
enum MacDebugSnapshots {
    /// Posted for jellygoose://livewatch: Live TV puts its corner's channel full screen.
    static let watchLive = Notification.Name("goosetv.debug.watchLive")
    private static var taken = 0
    private static var sendTo: URL?
    /// Windows coming and going since launch, for the note when none is on screen.
    private static var events: [String] = []
    private static let started = Date()

    /// A line for the window list beside the next picture.
    static func log(_ what: String) { note(what, nil) }

    private static func note(_ what: String, _ window: NSWindow?) {
        let t = String(format: "%5.1fs", Date().timeIntervalSince(started))
        events.append("\(t) \(what) \(window.map { "\(type(of: $0)) '\($0.title)'" } ?? "")")
    }

    static func startIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard let asked = env["GOOSETV_MAC_SNAP"] else { return }
        // An address (http://127.0.0.1:<port>/): each picture is sent there, for a script
        // that can't read the app's container (macOS keeps other apps out of it). Otherwise
        // the sandbox lets the app write in its own container: a name alone is a folder in
        // its temporary one (~/Library/Containers/<id>/Data/tmp/<name>).
        if asked.hasPrefix("http") { sendTo = URL(string: asked) }
        let folder = asked.hasPrefix("/") || sendTo != nil ? asked : (NSTemporaryDirectory() as NSString).appendingPathComponent(asked)
        let count = Int(env["GOOSETV_MAC_SNAP_COUNT"] ?? "") ?? 20
        let every = Double(env["GOOSETV_MAC_SNAP_EVERY"] ?? "") ?? 4
        if sendTo == nil { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let center = NotificationCenter.default
        for (name, what) in [(NSWindow.didBecomeMainNotification, "main"), (NSWindow.willCloseNotification, "closing"),
                             (NSWindow.didBecomeKeyNotification, "key"), (NSWindow.didMiniaturizeNotification, "minimised")] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { Self.note(what, note.object as? NSWindow) }
            }
        }
        note("launched", nil)
        Timer.scheduledTimer(withTimeInterval: every, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard taken < count else { timer.invalidate(); return }
                taken += 1
                snap(to: (folder as NSString).appendingPathComponent(String(format: "snap-%02d.png", taken)))
            }
        }
    }

    /// A click for a script, by link (jellygoose://click/0.5,0.3 or rightclick/…): at a point
    /// given as fractions of the front window across and down from its top left. Sent to the
    /// window, not posted to the app, and nothing is brought forward: the app is often not
    /// the one in front while a script runs (whoever's at the Mac is using another).
    static func click(_ spec: String, right: Bool) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window = target,
              let content = window.contentView else { return }
        let size = content.bounds.size
        let inWindow = content.convert(NSPoint(x: parts[0] * size.width, y: (1 - parts[1]) * size.height), to: nil)
        // Behind another app, the window takes a first click only to come forward, unless
        // the view under it says it takes first clicks: told so here, as a toolbar's
        // buttons are, so the click goes through and nothing comes forward.
        if let frame = content.superview, let hit = frame.hitTest(frame.superview?.convert(inWindow, from: nil) ?? inWindow) {
            takesFirstClicks(hit)
            note("click \(spec) on \(String(describing: type(of: hit)).prefix(60)) first=\(hit.acceptsFirstMouse(for: nil)) key=\(window.isKeyWindow)", nil)
        }
        let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            guard let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
            else { continue }
            // Through the window, as a click arrives: SwiftUI's taps are gesture
            // recognisers, which hear the window's events, not the view's own.
            window.sendEvent(event)
        }
    }

    /// The window a script means: the film's while one is up, else whatever covers the
    /// app's window (Live TV, Now Playing), else the app's window. Not simply the one in
    /// front: a link brings the app's window forward over the film's.
    private static var mainOnly = false

    private static var target: NSWindow? {
        if mainOnly, let main = AppWindow.main { return main }
        // The unlock screen's panel, over everything while it's up.
        if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.contentView != nil && $0.frame.width > 200 }) { return panel }
        if let film = MacPlayerStage.shared.stageWindow, film.isVisible { return film }
        if let main = AppWindow.main, main.isVisible { return main.attachedSheet ?? main }
        return NSApp.orderedWindows.first(where: { $0.isVisible })
    }

    private static var throughClasses = Set<ObjectIdentifier>()

    /// Every view of the hit view's class takes first clicks from now on (debug runs for a
    /// script alone).
    private static func takesFirstClicks(_ view: NSView) {
        let viewClass: AnyClass = type(of: view)
        guard throughClasses.insert(ObjectIdentifier(viewClass)).inserted else { return }
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        guard let method = class_getInstanceMethod(viewClass, selector) else { return }
        let yes: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        class_replaceMethod(viewClass, selector, imp_implementationWithBlock(yes), method_getTypeEncoding(method))
    }

    /// A key for a script, by link (jellygoose://key/space): down and up, to the front
    /// window's first responder, for the same reason.
    static func key(_ name: String) {
        let keys: [String: (UInt16, String)] = [
            "space": (49, " "), "return": (36, "\r"), "escape": (53, "\u{1b}"), "f": (3, "f"),
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        ]
        guard let (code, characters) = keys[name], let window = target else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
        }
    }

    /// A picture now, named, for a script that asks by link (jellygoose://snap/<name>):
    /// sent where GOOSETV_MAC_SNAP said, or to the container's tmp folder.
    static func snapNow(_ name: String) {
        // "main-…": the app's own window, even with a film's window up.
        mainOnly = name.hasPrefix("main-")
        defer { mainOnly = false }
        let file = (name.isEmpty ? "now" : name) + ".png"
        let folder = sendTo == nil ? (NSTemporaryDirectory() as NSString).appendingPathComponent("snaps") : "/"
        if sendTo == nil { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        snap(to: (folder as NSString).appendingPathComponent(file))
        // Beside it, the windows there are, front first.
        var list = NSApp.orderedWindows.map { "\(type(of: $0)) '\($0.title)' visible=\($0.isVisible) key=\($0.isKeyWindow) frame=\($0.frame)" }
        // What the music player has on, and from where (a file or the server).
        list.append("music: \(MusicPlayer.shared.current?.displayTitle ?? "-") playing=\(MusicPlayer.shared.isPlaying) from \(MusicPlayer.shared.debugSource)")
        // The downloads, by state.
        let records = Downloads.shared.records.values
        for record in records where Downloads.shared.item(record.id)?.isPlayableAudio == false {
            list.append("  \(Downloads.shared.item(record.id)?.displayTitle ?? record.id): \(record.state) \(record.bytesWritten)/\(record.bytesExpected) bytes, \(record.converted ?? "original"), subtitles \(record.subtitleFiles?.keys.sorted() ?? []), \(record.fileName)")
        }
        list.append("downloads: \(records.filter { $0.state == .done }.count) done, \(records.filter { $0.state == .downloading }.count) coming, \(records.filter { $0.state == .failed }.count) failed; groups \(Downloads.shared.groups.values.map { "\($0.name)=\(Downloads.shared.groupCounts($0.id).done)/\($0.itemIds.count)" })")
        list.append("app icon: \(AppIcon.current.rawValue)")
        save(Data((list + ["events:"] + events).joined(separator: "\n").utf8),
             as: (folder as NSString).appendingPathComponent((name.isEmpty ? "now" : name) + "-windows.txt"))
        // What the Dock is showing for the app, beside it.
        if let tiff = NSApplication.shared.applicationIconImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            save(png, as: (folder as NSString).appendingPathComponent((name.isEmpty ? "now" : name) + "-dock.png"))
        }
    }

    /// The front window's whole frame, title bar and all, as it's drawn.
    private static func snap(to path: String) {
        guard let window = target,
              let view = window.contentView?.superview ?? window.contentView else {
            // No window to take: say what windows there are instead.
            let list = NSApp.windows.map { "\(type(of: $0)) '\($0.title)' visible=\($0.isVisible) frame=\($0.frame)" }
            let text = (["no visible window; \(NSApp.windows.count) in all:"] + list + ["events:"] + events).joined(separator: "\n")
            save(Data(text.utf8), as: path.replacingOccurrences(of: ".png", with: ".txt"))
            return
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { save(png, as: path) }
    }

    private static func save(_ data: Data, as path: String) {
        guard let sendTo else { try? data.write(to: URL(fileURLWithPath: path)); return }
        var request = URLRequest(url: sendTo.appendingPathComponent((path as NSString).lastPathComponent))
        request.httpMethod = "PUT"
        URLSession.shared.uploadTask(with: request, from: data).resume()
    }
}
#endif
