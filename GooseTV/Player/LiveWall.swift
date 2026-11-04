import SwiftUI
import VLCKitSPM

/// Several channels on the screen at once: two side by side, or four in a
/// square, the sound from the one that's lit. For a few games at once.
///
/// Each channel is a tuner, as any channel is: the server's, taken and let
/// go of by the rules the full screen keeps (see `LiveTuner`). One asked for
/// at a time; one with sound nothing here plays (AC-4) never asked for; let
/// go of by the stop report and that alone; written down while it's open,
/// so that one a killed app left is given back the next time.
///
/// Each has a player of its own, from four made once and never let go of
/// (a VLC player can't safely be, see `LiveTuner.shared`). They weave an
/// interlaced picture the cheap way: a quarter of the screen doesn't show
/// the difference, and four pictures at once is four times the work.
@MainActor
final class LiveWall: ObservableObject {
    /// The most channels on the wall.
    static let most = 4

    /// The channels on it, in their places: two side by side, or the
    /// square's four in reading order.
    @Published private(set) var tiles: [Tile] = []
    /// The place that's lit, whose sound is heard: an empty place after the
    /// last tile, where there's room, is one more than the tiles.
    @Published private(set) var lit = 0

    private let client: any MediaServer
    /// The players not in use, by their place in the pool: shared by every
    /// wall, since a wall left behind may still hold one for a while (see
    /// `close(keeping:until:)`) as the next is put up.
    private static var free = Array(0..<LiveWall.most)
    private var free: [Int] {
        get { Self.free }
        set { Self.free = newValue }
    }
    private(set) var closed = false

    init(client: any MediaServer) {
        self.client = client
    }

    /// How many places are drawn: two side by side for one channel (the
    /// other empty, to add to) or two, the square of four for three or
    /// four (with three, one empty).
    var places: Int { tiles.count <= 2 ? 2 : 4 }

    /// Puts a channel up in a place: a new one where the place is empty,
    /// another in the place of the one that was there.
    func put(_ channel: LiveChannel, at place: Int) {
        guard !closed else { return }
        // Playing needs the trial or the unlock (see `Unlock`).
        guard Unlock.shared.mayPlay else {
            Unlock.shared.ask { [weak self] in self?.put(channel, at: place) }
            return
        }
        if tiles.indices.contains(place) {
            tiles[place].tune(to: channel, on: client)
        } else if tiles.count < Self.most, let slot = free.first {
            free.removeFirst()
            let tile = Tile(slot: slot, channel: channel)
            tiles.append(tile)
            tile.tune(to: channel, on: client)
            light(tiles.count - 1)
        }
        hush()
    }

    /// Takes a channel down: its tuner let go, the places after it moved up.
    func remove(at place: Int) {
        guard tiles.indices.contains(place) else { return }
        let tile = tiles.remove(at: place)
        tile.stop()
        free.append(tile.slot)
        light(min(lit, max(tiles.count - 1, 0)))
    }

    /// Lights a place, and its channel is the one heard.
    func light(_ place: Int) {
        lit = min(max(place, 0), max(places - 1, 0))
        hush()
    }

    /// Every channel let go: the wall's done with.
    func close() {
        closed = true
        for tile in tiles {
            tile.stop()
            free.append(tile.slot)
        }
        tiles = []
    }

    /// Lets go of every channel but `keeping`'s, whose tuner the full screen
    /// is about to share (the server has one stream for a channel, however
    /// many are on it): held until `then` says it may go.
    func close(keeping channel: String?, until then: @escaping () async -> Void) {
        closed = true
        let kept = tiles.first { $0.channel.id == channel }
        for tile in tiles where tile !== kept {
            tile.stop()
            free.append(tile.slot)
        }
        tiles = kept.map { [$0] } ?? []
        kept?.hush(true)
        guard let kept else { return }
        Task {
            await then()
            kept.stop()
            self.free.append(kept.slot)
            self.tiles = []
        }
    }

    private func hush() {
        for (place, tile) in tiles.enumerated() { tile.hush(place != lit) }
    }

    // MARK: The players

    /// The four players and the views they draw in, made the first time a
    /// wall is put up and kept for as long as the app runs.
    fileprivate static let players: [VLCMediaPlayer] = views.map { view in
        let player = VLCMediaPlayer(options: ["--deinterlace=-1", "--deinterlace-mode=linear"])
        player.drawable = view
        return player
    }
    fileprivate static let views: [UIView] = (0..<most).map { _ in
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    /// One channel on the wall.
    @MainActor
    final class Tile: NSObject, ObservableObject, Identifiable, VLCMediaPlayerDelegate {
        enum Phase: Equatable {
            case tuning, playing
            /// The server had no stream to give: every tuner in use, most often.
            case refused
            /// It came and stopped, or never showed a picture.
            case lost
            /// Its sound is of a kind nothing here plays (AC-4).
            case unplayable
        }

        /// Which of the four players it plays in.
        let slot: Int
        @Published private(set) var channel: LiveChannel
        @Published private(set) var phase: Phase = .tuning
        private var stream: LiveStream?
        private var client: (any MediaServer)?
        private var heartbeat: Timer?
        private var patience: Task<Void, Never>?
        /// Counts the asks, so an answer that comes after the next ask is
        /// known for what it is and given straight back.
        private var asks = 0
        private var hushed = true

        var id: Int { slot }
        var surface: UIView { LiveWall.views[slot] }
        private var player: VLCMediaPlayer { LiveWall.players[slot] }

        init(slot: Int, channel: LiveChannel) {
            self.slot = slot
            self.channel = channel
        }

        func tune(to channel: LiveChannel, on client: any MediaServer) {
            asks += 1
            let mine = asks
            self.channel = channel
            self.client = client
            phase = .tuning
            let left = release()
            Task { [weak self] in
                // The last let go of before the next is asked for: it may
                // need that very tuner.
                if left { try? await Task.sleep(for: .milliseconds(150)) }
                guard let self, mine == self.asks else { return }
                await LiveTuner.giveBackLeftover(on: client)
                guard mine == self.asks else { return }
                if await client.livePlayable(channelId: channel.id) == false {
                    if mine == self.asks { self.phase = .unplayable }
                    return
                }
                // Asked in turn, and only if still wanted when the turn
                // comes: a place taken down or given another channel while
                // it waited takes no tuner.
                let stream: LiveStream? = await LiveOpenLine.run { [weak self] in
                    guard let self, mine == self.asks else { return nil }
                    return try? await client.openLiveStream(channelId: channel.id)
                }
                guard let stream else {
                    if mine == self.asks { self.phase = .refused }
                    return
                }
                guard mine == self.asks else {
                    // Answered after it stopped being wanted: given straight back.
                    LiveTuner.note(stream, on: client)
                    LiveTuner.letGo(stream)
                    if await client.reportLive(stream, .stopped) { LiveTuner.forget(stream) } else { LiveTuner.stopUnheard(stream) }
                    return
                }
                self.play(stream, on: client)
            }
        }

        private func play(_ stream: LiveStream, on client: any MediaServer) {
            self.stream = stream
            LiveTuner.note(stream, on: client)
            MusicPlayer.shared.yield()
            PlaybackAudioSession.take()
            player.delegate = self
            let media = VLCMedia(url: stream.url)
            media.addOption(":network-caching=1500")
            player.media = media
            player.play()
            Task { await client.reportLive(stream, .started) }
            heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let stream = self.stream, let client = self.client else { return }
                    await client.reportLive(stream, .playing)
                }
            }
            // A tuner with no signal hands over a stream with nothing in it.
            let mine = asks
            patience = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled, mine == self.asks, self.phase == .tuning else { return }
                self.release()
                self.phase = .lost
            }
        }

        /// The sound off, or on: only the lit channel is heard.
        func hush(_ off: Bool) {
            hushed = off
            if stream != nil { applySound() }
        }

        /// The player's sound as it's wanted. Its sound isn't there to set
        /// until the stream has started (set before, it was forgotten, and
        /// every channel on the wall was heard at once), so this is said
        /// again whenever the player is found otherwise.
        private func applySound() {
            guard let audio = player.audio else { return }
            let volume: Int32 = hushed ? 0 : 100
            guard audio.isMuted != hushed || audio.volume != volume else { return }
            audio.isMuted = hushed
            audio.volume = volume
        }

        /// Let go of for good.
        func stop() {
            asks += 1
            release()
        }

        /// The stream let go of, by the stop report; false if there was none.
        @discardableResult
        private func release() -> Bool {
            heartbeat?.invalidate()
            heartbeat = nil
            patience?.cancel()
            guard let stream, let client else { return false }
            self.stream = nil
            LiveTuner.letGo(stream)
            if player.delegate === self { player.delegate = nil }
            player.stop()
            // In a task of its own: a change of channel isn't to drop it unsent.
            Task {
                if await client.reportLive(stream, .stopped) { LiveTuner.forget(stream) } else { LiveTuner.stopUnheard(stream) }
            }
            return true
        }

        nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
            MainActor.assumeIsolated {
                guard stream != nil else { return }
                applySound()
                // The clock moving is the picture come.
                guard phase == .tuning else { return }
                patience?.cancel()
                phase = .playing
            }
        }

        nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
            MainActor.assumeIsolated {
                guard stream != nil, phase == .tuning || phase == .playing else { return }
                if player.state == .error || player.state == .ended {
                    release()
                    phase = .lost
                }
            }
        }
    }
}

/// The server is asked for one channel at a time, by every player that asks:
/// it opens streams one after the other, and a second asking while it's at
/// the first is a second tuner taken until the first is answered. Each runs
/// in a task of its own, which a change of mind doesn't cancel: cancelled
/// part-way, the request was dropped with the server already tuning, and
/// the tuner held for a stream nobody had the name of.
@MainActor
enum LiveOpenLine {
    private static var last: Task<Void, Never>?

    /// Runs `ask` once every open asked before it has had its answer.
    static func run<Answer>(_ ask: @escaping @MainActor () async -> Answer) async -> Answer {
        let before = last
        let mine = Task { @MainActor () -> Answer in
            await before?.value
            return await ask()
        }
        last = Task { _ = await mine.value }
        return await mine.value
    }
}

/// Where a wall's channel is drawn: its player's view, taken into the place.
struct LiveWallSurface: UIViewRepresentable {
    let tile: LiveWall.Tile

    func makeUIView(context: Context) -> LiveSurfaceHost {
        let host = LiveSurfaceHost()
        host.backgroundColor = .black
        return host
    }

    func updateUIView(_ host: LiveSurfaceHost, context: Context) {
        host.adopt(tile.surface)
    }
}
