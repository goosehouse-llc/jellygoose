import SwiftUI

/// A player taking part in watching together. It plays what the group's
/// queue says, and does what the server says when the server says it:
/// held still until every member is ready, set going at a moment by the
/// server's clock, paused and moved where it's told. The viewer's presses
/// are asked of the server rather than done (`togglePause`, `seek`), so
/// they reach this player the way they reach everyone else's. While it
/// plays it's kept to where the group is, moved there when it strays.
@MainActor
final class SyncPlayDriver {
    /// What it needs of the player.
    struct Controls {
        /// The film the player has open.
        let item: BaseItem
        /// Whether an episode goes on to the next, as the account has it.
        let onward: Bool
        let position: () -> Double
        let isPlaying: () -> Bool
        let isLoading: () -> Bool
        let play: () -> Void
        let pause: () -> Void
        let seek: (Double) -> Void
        /// Another film is the group's now: the player goes to it.
        let switchTo: (String) -> Void
        /// The group was stopped: the player closes.
        let stop: () -> Void
    }

    private let sync: SyncPlay
    private let controls: Controls
    /// The film's place in the group's queue, once the queue has it.
    private(set) var playlistItemId: String?
    /// Kept still until the server says to go.
    private var holding = true
    /// Whether the group means to play, which is said with each report.
    private var groupPlays = false
    /// The server's to be told this player is ready, once it has loaded
    /// and got to where it was sent.
    private var readyOwed = false
    private var bufferingSaid = false
    /// Where it was last sent, and when.
    private var sentTo: Double?
    private var lastMove = Date.distantPast
    /// Where the film should be, by the server's last word to go: from a
    /// moment by this device's clock, at a place in the film.
    private var reference: (at: Date, seconds: Double)?
    private var scheduled: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    /// The film is to be asked for, for the group, once it's loaded here.
    private var asking = false
    private let opened = Date()

    init(sync: SyncPlay, controls: Controls) {
        self.sync = sync
        self.controls = controls
    }

    /// The player has opened in a group: on the film the group is playing,
    /// it joins in; on any other, that film is asked for, for everyone,
    /// from where it is here.
    func start() {
        sync.driver = self
        if let current = sync.queue?.current, current.itemId == controls.item.id,
           let group = sync.position(of: current.itemId) {
            begin(current, at: group.seconds, plays: group.playing)
        } else if let current = sync.playingItemId.flatMap({ _ in sync.queue?.current }) {
            // Joined from the player: the group's film, not this one.
            controls.switchTo(current.itemId)
        } else {
            // From where it opens, once it has: a film resumed starts at the
            // top until it's loaded.
            asking = true
        }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                self?.tick()
            }
        }
    }

    /// The player is going (closed, or built again): it lets go of the group.
    func detach() {
        scheduled?.cancel()
        watching?.cancel()
        if sync.driver === self { sync.driver = nil }
    }

    /// Out of the group (left, or the group ended): the film plays on here alone.
    func groupEnded() {
        scheduled?.cancel()
        asking = false
        playlistItemId = nil
        holding = false
        reference = nil
        readyOwed = false
    }

    // MARK: The group's queue and commands

    func queueChanged(_ queue: SyncPlay.Queue) {
        guard let current = queue.current else { return }
        guard current.itemId == controls.item.id else { return controls.switchTo(current.itemId) }
        // Films added after it, or the way it repeats: nothing to do here.
        // Told again which it is, the film is begun again.
        if current.playlistItemId == playlistItemId, queue.reason != "SetCurrentItem" { return }
        asking = false
        begin(current, at: Double(queue.startTicks) / 10_000_000, plays: queue.isPlaying)
    }

    private func begin(_ entry: SyncPlay.Entry, at seconds: Double, plays: Bool) {
        scheduled?.cancel()
        playlistItemId = entry.playlistItemId
        holding = true
        groupPlays = plays
        reference = nil
        controls.pause()
        if abs(controls.position() - seconds) > 1 { move(to: seconds) }
        readyOwed = true
        sync.report(ready: false, at: seconds, playing: plays, item: entry.playlistItemId)
    }

    func apply(_ command: SyncPlay.Command) {
        if command.name == "Stop" {
            // The group stopped what it was playing (said once as anyone
            // joins too, before anything is playing: nothing to stop then).
            if playlistItemId != nil, command.playlistItemId == playlistItemId { controls.stop() }
            return
        }
        guard command.playlistItemId == playlistItemId else { return }
        scheduled?.cancel()
        switch command.name {
        case "Unpause":
            groupPlays = true
            let at = sync.local(command.when)
            scheduled = Task { [weak self] in
                let wait = at.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled else { return }
                // Late (the word arrived after its moment): on as far as
                // the others have got.
                let target = command.seconds + max(Date().timeIntervalSince(at), 0)
                if abs(self.controls.position() - target) > 0.5 { self.move(to: target) }
                self.holding = false
                self.reference = (at, command.seconds)
                self.controls.play()
            }
        case "Pause":
            groupPlays = false
            holding = true
            reference = nil
            controls.pause()
            if abs(controls.position() - command.seconds) > 0.5 { move(to: command.seconds) }
        case "Seek":
            holding = true
            reference = nil
            controls.pause()
            move(to: command.seconds)
            readyOwed = true
        default:
            break
        }
    }

    // MARK: Kept in step

    #if DEBUG
    private var traced = Date.distantPast
    #endif

    private func tick() {
        #if DEBUG
        // Where it is by the server's clock, once a second, to compare
        // two simulators' players.
        if Date().timeIntervalSince(traced) >= 1 {
            traced = Date()
            print(String(format: "SyncPlayTrace %.3f pos=%.3f playing=%d loading=%d holding=%d",
                         sync.serverNow.timeIntervalSince1970, controls.position(),
                         controls.isPlaying() ? 1 : 0, controls.isLoading() ? 1 : 0, holding ? 1 : 0))
        }
        #endif
        if asking, !controls.isLoading() || Date().timeIntervalSince(opened) > 8 {
            asking = false
            let from = Int64((max(controls.position(), 0) * 10_000_000).rounded())
            let item = controls.item, onward = controls.onward
            Task { [sync] in await sync.play(item, from: from, onward: onward) }
        }
        guard let item = playlistItemId else { return }
        let loading = controls.isLoading()
        // A player sets itself going once it's loaded, and after a move.
        if holding, !loading, controls.isPlaying() { controls.pause() }
        if readyOwed, !loading, Date().timeIntervalSince(lastMove) > 0.6 {
            // Where it was sent, before saying it's there (a move takes a moment).
            let arrived = sentTo.map { abs(controls.position() - $0) < 1.5 } ?? true
            if arrived || Date().timeIntervalSince(lastMove) > 4 {
                readyOwed = false
                bufferingSaid = false
                sync.report(ready: true, at: controls.position(), playing: groupPlays, item: item)
            }
            return
        }
        // Stalled while playing: the group waits for this one.
        if !holding, loading, !bufferingSaid {
            bufferingSaid = true
            readyOwed = true
            sync.report(ready: false, at: controls.position(), playing: true, item: item)
            return
        }
        // Strayed from where the group is: back there, a little ahead for the move.
        if !holding, !loading, let reference, Date().timeIntervalSince(lastMove) > 4 {
            let expected = reference.seconds + Date().timeIntervalSince(reference.at)
            if abs(controls.position() - expected) > 1 { move(to: expected + 0.3) }
        }
    }

    private func move(to seconds: Double) {
        lastMove = Date()
        sentTo = seconds
        controls.seek(seconds)
    }

    // MARK: The viewer's presses, asked of the group

    func togglePause() {
        sync.ask(holding || !controls.isPlaying() ? "Unpause" : "Pause")
    }

    func seek(to seconds: Double) {
        sync.ask("Seek", ["PositionTicks": Int64((max(seconds, 0) * 10_000_000).rounded())])
    }

    /// The film has ended here: the group's next, where it has one.
    func finished() {
        guard let item = playlistItemId else { return }
        sync.ask("NextItem", ["PlaylistItemId": item])
    }
}

/// What the film player lets its controls do for the group: open another
/// film in its place, and close as the group stops. Set only by the film
/// player, so a channel's full screen takes no part.
struct WatchTogetherHooks {
    /// Whether an episode goes on to the next, as the account has it.
    let onward: Bool
    let switchTo: (String) -> Void
    let stop: () -> Void
}

private struct WatchTogetherKey: EnvironmentKey {
    static let defaultValue: WatchTogetherHooks? = nil
}

extension EnvironmentValues {
    var watchTogether: WatchTogetherHooks? {
        get { self[WatchTogetherKey.self] }
        set { self[WatchTogetherKey.self] = newValue }
    }
}
