import SwiftUI

/// Played from another device: what a phone (or Jellyfin's own web app)
/// asks of this Apple TV through the server, and what does it. The server
/// is told this device takes commands and plays video, and passes them on
/// over its connection (`ServerLink`): play this from there; pause, play,
/// seek, stop; this audio track, these subtitles.
///
/// Only on an Apple TV, only on Jellyfin, and only while it's allowed
/// (Settings, Play on TV). Not while watching together: the group says
/// what plays there.
@MainActor
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    /// A film asked for from elsewhere, for the app to open (and to close
    /// whatever's on the screen for).
    struct Launch: Equatable {
        let itemId: String
        let startTicks: Int64?
        let audioIndex: Int?
        let subtitleIndex: Int?
        let mediaSourceId: String?
        /// Shuffle rather than Play, for a show or anything holding more.
        var shuffled = false
        let asked = UUID()
    }

    /// What the commands work, while a film player is open.
    struct Player {
        let itemId: String
        let play: () -> Void
        let pause: () -> Void
        let togglePause: () -> Void
        /// To a moment of the film, in seconds.
        let seek: (Double) -> Void
        /// Back or on by so many seconds.
        let skip: (Double) -> Void
        let stop: () -> Void
        /// A track by the server's numbering of the film's streams; -1 for
        /// subtitles off.
        let audio: (Int) -> Void
        let subtitle: (Int) -> Void
    }

    @Published var launch: Launch?

    static let allowedKey = "goosetv.remote.allowed"
    /// On unless turned off, as every Jellyfin app that can be played on is.
    static var allowed: Bool { UserDefaults.standard.object(forKey: allowedKey) as? Bool ?? true }

    /// Sent to whatever's on the screen when a film is asked for: Live TV
    /// closes its channel for it.
    static let takingOver = Notification.Name("goosetv.remote.takingOver")

    private var client: (any MediaServer)?
    private var player: (id: UUID, controls: Player)?
    /// Where the player of the film last asked for is to start, as it was
    /// asked: for half a minute, in case it never opens (a channel being
    /// recorded opens elsewhere), so it can't start the film there later.
    private var start: (launch: Launch, at: Date)?

    private init() {
        ServerLink.shared.listen("remote", message: { [weak self] type, data in self?.read(type, data) },
                                 opened: { [weak self] in self?.say() })
    }

    /// Signed in: told to the server, and the connection held open for it.
    func use(_ client: any MediaServer) async {
        #if os(tvOS)
        guard client.flavor == .jellyfin else { return }
        self.client = client
        await apply()
        #endif
    }

    /// Signed out, or another server.
    func forget() {
        ServerLink.shared.release("remote")
        client = nil
        launch = nil
        start = nil
    }

    /// Allowed or not, as Settings now has it.
    func apply() async {
        guard let client else { return }
        if Self.allowed {
            await ServerLink.shared.hold("remote")
        } else {
            ServerLink.shared.release("remote")
        }
        await client.reportCapabilities(controllable: Self.allowed)
    }

    /// The connection opened afresh: the server's told again, in case it
    /// forgot this device (restarted, say).
    private func say() {
        guard let client, Self.allowed else { return }
        Task { await client.reportCapabilities(controllable: true) }
    }

    // MARK: The player

    /// The player open now; given back with the id it's to be let go by.
    func attach(_ controls: Player) -> UUID {
        let id = UUID()
        player = (id, controls)
        return id
    }

    func detach(_ id: UUID) {
        if player?.id == id { player = nil }
    }

    /// The open film closed, for another asked for from elsewhere.
    func stopPlayer() {
        player?.controls.stop()
    }

    /// What an item sent here plays. Jellyfin's web app sends what was on
    /// its screen as it was, a show or a season among them: for a show its
    /// next episode, and for anything holding films or episodes (a season, a
    /// collection, a playlist, a folder) the first, with the rest after it.
    /// Shuffled, a mix of them.
    func playable(_ item: BaseItem, shuffled: Bool) async -> (first: BaseItem, queue: [BaseItem])? {
        guard let client else { return nil }
        guard item.isSeries || item.isContainer || item.type == "Season" || item.type == "Folder" else { return (item, []) }
        if item.isSeries, !shuffled, let next = await client.nextEpisode(seriesId: item.id) { return (next, []) }
        guard let items = try? await client.playQueue(for: item, shuffled: shuffled), let first = items.first else { return nil }
        // A show's episodes follow on by themselves.
        return (first, item.isSeries && !shuffled ? [] : Array(items.dropFirst()))
    }

    /// Where a film asked for from elsewhere is to start, once: the player
    /// asks as it loads it.
    func takeStart(for itemId: String) -> Launch? {
        guard let start, start.launch.itemId == itemId, Date().timeIntervalSince(start.at) < 30 else { return nil }
        self.start = nil
        return start.launch
    }

    // MARK: Commands

    private func read(_ type: String, _ data: Any?) {
        guard client != nil, Self.allowed, !SyncPlay.shared.isInGroup,
              let data = data as? [String: Any] else { return }
        switch type {
        case "Play": play(data)
        case "Playstate": playstate(data)
        case "GeneralCommand": general(data)
        default: break
        }
    }

    private func play(_ data: [String: Any]) {
        let ids = (data["ItemIds"] as? [String]) ?? []
        let first = (data["StartIndex"] as? Int).flatMap { ids.indices.contains($0) ? ids[$0] : nil } ?? ids.first
        guard let first else { return }
        // Played now; added to a queue there isn't, played now too.
        let asked = Launch(itemId: first, startTicks: Self.ticks(data["StartPositionTicks"]),
                           audioIndex: data["AudioStreamIndex"] as? Int, subtitleIndex: data["SubtitleStreamIndex"] as? Int,
                           mediaSourceId: data["MediaSourceId"] as? String,
                           shuffled: data["PlayCommand"] as? String == "PlayShuffle")
        start = (asked, Date())
        NotificationCenter.default.post(name: Self.takingOver, object: nil)
        launch = asked
    }

    private func playstate(_ data: [String: Any]) {
        guard let player = player?.controls, let command = data["Command"] as? String else { return }
        switch command {
        case "Pause": player.pause()
        case "Unpause": player.play()
        case "PlayPause": player.togglePause()
        case "Stop": player.stop()
        case "Seek":
            if let ticks = Self.ticks(data["SeekPositionTicks"]) { player.seek(Double(ticks) / 10_000_000) }
        case "Rewind": player.skip(-10)
        case "FastForward": player.skip(30)
        default: break
        }
    }

    private func general(_ data: [String: Any]) {
        guard let player = player?.controls, let name = data["Name"] as? String else { return }
        let arguments = data["Arguments"] as? [String: Any]
        let index = (arguments?["Index"] as? String).flatMap(Int.init) ?? arguments?["Index"] as? Int
        switch name {
        case "SetAudioStreamIndex": if let index { player.audio(index) }
        case "SetSubtitleStreamIndex": if let index { player.subtitle(index) }
        default: break
        }
    }

    /// The server's ticks come as a number, or now and then as a string.
    private static func ticks(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}
