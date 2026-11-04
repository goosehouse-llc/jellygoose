#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The one connection to the server that it talks back over: Watch Together's
/// messages and the commands other devices send this one (`RemoteControl`)
/// both come down it. One, shared, because the server gives a device's
/// messages to one of its connections, not to each: a second of its own for
/// either would have left the other's messages going to the wrong place.
///
/// Held open while anything here wants it (`hold`), let go when nothing does;
/// opened again when it drops, and when the app comes back from the
/// background. Closed on going there, unless something wants it kept.
@MainActor
final class ServerLink {
    static let shared = ServerLink()

    private let socket = ServerSocket()
    private var client: (any MediaServer)?
    /// What wants it open, by name.
    private var holders: Set<String> = []
    /// Those that want it kept open in the background too.
    private var keptAway: Set<String> = []
    private var listeners: [String: (String, Any?) -> Void] = [:]
    /// Told when it opens afresh, and when it drops.
    private var openListeners: [String: () -> Void] = [:]
    private var dropListeners: [String: () -> Void] = [:]
    private var retrying: Task<Void, Never>?
    private var opening: Task<Bool, Never>?
    private var away = false

    var isOpen: Bool { socket.isOpen }

    private init() {
        socket.onMessage = { [weak self] type, data in
            self?.listeners.values.forEach { $0(type, data) }
        }
        socket.onDrop = { [weak self] in self?.dropped() }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
    }

    /// The account signed in. Another one, or another server: the old
    /// connection is the old session's.
    func use(_ client: any MediaServer) {
        guard client !== self.client else { return }
        close()
        self.client = client
        if !holders.isEmpty { Task { await open() } }
    }

    /// Signed out: nothing to be connected as.
    func forget() {
        close()
        client = nil
    }

    func listen(_ name: String, message: @escaping (String, Any?) -> Void,
                opened: (() -> Void)? = nil, dropped: (() -> Void)? = nil) {
        listeners[name] = message
        openListeners[name] = opened
        dropListeners[name] = dropped
    }

    /// Wanted open by `name`: opened if it isn't. Whether it's open.
    /// `inBackground`: not closed when the app goes there, where it may
    /// play on (a film in its own window on a phone).
    @discardableResult
    func hold(_ name: String, inBackground: Bool = false) async -> Bool {
        holders.insert(name)
        if inBackground { keptAway.insert(name) }
        return await open()
    }

    /// No longer wanted by `name`: closed once nothing wants it.
    func release(_ name: String) {
        holders.remove(name)
        keptAway.remove(name)
        if holders.isEmpty { close() }
    }

    /// Opens it if it isn't, and waits for that; one opening at a time.
    @discardableResult
    func open() async -> Bool {
        if socket.isOpen { return true }
        if let opening { return await opening.value }
        guard !away, let request = client?.socketRequest() else { return false }
        let task = Task { () -> Bool in
            await socket.open(request)
            return socket.isOpen
        }
        opening = task
        let open = await task.value
        opening = nil
        if open {
            retrying?.cancel()
            retrying = nil
            openListeners.values.forEach { $0() }
        }
        return open
    }

    private func close() {
        retrying?.cancel()
        retrying = nil
        socket.close()
    }

    /// Dropped, not closed from here: those listening are told, and while
    /// it's still wanted it's tried again, less often each time.
    private func dropped() {
        dropListeners.values.forEach { $0() }
        guard !holders.isEmpty, !away, retrying == nil else { return }
        retrying = Task { [weak self] in
            var wait: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, !self.holders.isEmpty, !self.away else { return }
                if await self.open() { return }
                wait = min(wait * 2, 60)
            }
        }
    }

    /// Closed, so the server stops offering this device to be sent films it
    /// can't play from the background. Not while Watch Together has it: a
    /// phone's film plays on in its own window, in the group; one the system
    /// suspends loses it as it always did.
    private func wentAway() {
        guard keptAway.isDisjoint(with: holders) else { return }
        away = true
        close()
        dropListeners.values.forEach { $0() }
    }

    private func cameBack() {
        away = false
        guard !holders.isEmpty else { return }
        Task { await open() }
    }
}
