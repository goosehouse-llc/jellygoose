import AVFoundation
import Combine
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Where the song playing is up to. Apart from the player, so the progress
/// bar is the only thing redrawn twice a second, not every screen that
/// shows what's playing.
@MainActor
/// GOOSETV_MUTE=1 in a Debug build: music and Live TV play without sound, for
/// test runs on a computer someone is using.
enum DebugSound {
    #if DEBUG
    static let muted = ProcessInfo.processInfo.environment["GOOSETV_MUTE"] == "1"
    #else
    static let muted = false
    #endif
}

final class MusicClock: ObservableObject {
    @Published fileprivate(set) var position: Double = 0
    @Published fileprivate(set) var duration: Double = 0
}

/// The app's music: one queue of songs, played through the app as it's
/// browsed and on with the screen locked or the app put away, shown on the
/// lock screen and in Control Center (the Apple TV's too) and worked from
/// there, and reported to the server as any player's are, so its plays are
/// counted.
///
/// A film or a channel coming on pauses it (`yield()`); the music waits,
/// paused, to be carried on from where it was.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    /// Posted as music starts, for a film or a channel to stop for it.
    static let willPlay = Notification.Name("jellygoose.music.willPlay")

    enum Repeat: Int, CaseIterable {
        case off, all, one
    }

    /// One place in the queue. The same song can be in it twice.
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let song: BaseItem
    }

    @Published private(set) var queue: [Entry] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    /// Asked for and not begun: the server's still answering.
    @Published private(set) var isWaiting = false
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode: Repeat = .off
    /// What the queue was made from ("Pond Life", "Shuffle All"), for Now Playing.
    @Published private(set) var source: String?
    /// The words of the song playing, where the server has them.
    @Published private(set) var lyrics: Lyrics?
    /// The Now Playing screen is up.
    @Published var showsNowPlaying = false
    static let bookSpeedKey = "goosetv.audiobook.speed"
    /// How fast an audiobook plays (music always plays as it is): kept from
    /// one book to the next.
    @Published private(set) var bookSpeed: Float = {
        let saved = UserDefaults.standard.float(forKey: MusicPlayer.bookSpeedKey)
        return saved > 0 ? saved : 1
    }()
    /// The speeds offered.
    static let bookSpeeds: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Whether what's playing is an audiobook: skips by the quarter minute,
    /// its own speed, chapters.
    var isBook: Bool { current?.isAudiobook == true }

    let clock = MusicClock()

    var current: BaseItem? { queue.indices.contains(index) ? queue[index].song : nil }
    /// Anything in the queue, playing or paused: the mini player shows.
    var isActive: Bool { current != nil }
    var upNext: ArraySlice<Entry> { queue.indices.contains(index) ? queue[(index + 1)...] : [] }

    private let player = AVQueuePlayer()
    private var client: (any MediaServer)?
    /// The queue in the order it was given, for shuffle to be turned off.
    private var original: [Entry] = []
    /// What each item the player holds is, by the item.
    private var loaded: [ObjectIdentifier: (entry: Entry, stream: PlaybackContext)] = [:]
    /// The song the server has been told is playing.
    private var reported: (item: AVPlayerItem, stream: PlaybackContext)?
    private let reports = PlaybackReportQueue()
    private var lastProgress = Date.distantPast
    /// The queue played to its end: Play starts its last song again.
    private var finished = false
    private var watching: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: (songId: String, art: MPMediaItemArtwork)?
    private var notes: [NSObjectProtocol] = []
    private var lyricsTask: Task<Void, Never>?
    private var itemStatus: NSKeyValueObservation?
    /// Where in the next song begun to start, in seconds (an audiobook
    /// carried on); used once.
    private var startingAt: Double = 0
    /// That place, waiting for the item it's in to be ready.
    private var pendingStart: (item: AVPlayerItem, seconds: Double)?

    private init() {
        player.actionAtItemEnd = .advance
        // The sleep timer pauses the music, as it stops a film.
        _ = SleepTimer.shared.register { [weak self] in self?.pause() }
        watching.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        watching.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.statusChanged(status) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        let center = NotificationCenter.default
        notes.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.reachedEnd(of: item) }
        })
        notes.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.failed(item) }
        })
        #if !os(macOS)
        notes.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.interrupted(info) }
        })
        #endif
    }

    // MARK: Choosing what plays

    /// Plays `songs` from `start`, or all of them in no order. `source` names
    /// them for Now Playing.
    /// `startAt` is where in the first to begin, in seconds: an audiobook
    /// carried on from where it was left.
    func play(_ songs: [BaseItem], from start: Int = 0, shuffled: Bool = false,
              source: String? = nil, startAt: Double = 0, client: any MediaServer) {
        let songs = songs.filter(\.isPlayableAudio)
        guard !songs.isEmpty else { return }
        // Playing needs the trial or the unlock, as a film does.
        guard Unlock.shared.mayPlay else {
            Unlock.shared.ask { [weak self] in
                self?.play(songs, from: start, shuffled: shuffled, source: source, startAt: startAt, client: client)
            }
            return
        }
        startingAt = startAt
        self.client = client
        self.source = source
        #if os(tvOS)
        // On a television the music is the screen while it starts: Now
        // Playing comes up, and Back goes on browsing with it playing.
        showsNowPlaying = true
        #endif
        let entries = songs.map { Entry(song: $0) }
        original = entries
        isShuffled = shuffled
        if shuffled {
            queue = entries.shuffled()
            begin(at: 0)
        } else {
            queue = entries
            begin(at: min(max(start, 0), entries.count - 1))
        }
    }

    /// Fetches the songs first: an album's, an artist's, a mix.
    func play(source: String? = nil, shuffled: Bool = false, client: any MediaServer,
              songs: @escaping () async throws -> [BaseItem]) {
        isWaiting = true
        Task {
            let found = (try? await songs()) ?? []
            isWaiting = false
            play(found, shuffled: shuffled, source: source, client: client)
        }
    }

    /// Straight after the song playing.
    func playNext(_ songs: [BaseItem], client: any MediaServer) {
        insert(songs, at: isActive ? index + 1 : 0, client: client)
    }

    /// At the end of the queue.
    func addToQueue(_ songs: [BaseItem], client: any MediaServer) {
        insert(songs, at: queue.count, client: client)
    }

    private func insert(_ songs: [BaseItem], at place: Int, client: any MediaServer) {
        let entries = songs.filter(\.isPlayableAudio).map { Entry(song: $0) }
        guard !entries.isEmpty else { return }
        guard isActive else { return play(songs, client: client) }
        queue.insert(contentsOf: entries, at: min(place, queue.count))
        original.append(contentsOf: entries)
        refillNext()
    }

    /// Plays the queue's song at `place`.
    func jump(to place: Int) {
        guard queue.indices.contains(place) else { return }
        begin(at: place)
    }

    func remove(_ entry: Entry) {
        guard let place = queue.firstIndex(of: entry), place != index else { return }
        queue.remove(at: place)
        original.removeAll { $0 == entry }
        if place < index { index -= 1 }
        refillNext()
    }

    /// Moves a song in what's to come.
    func move(from source: IndexSet, to destination: Int) {
        // Offsets within Up Next, after the song playing.
        let base = index + 1
        var upcoming = Array(queue[base...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(base..., with: upcoming)
        refillNext()
    }

    // MARK: Controls

    func togglePause() {
        isPlaying || isWaiting ? pause() : resume()
    }

    func pause() {
        player.pause()
        reportProgress(force: true)
        publishNowPlaying()
    }

    func resume() {
        guard isActive else { return }
        guard Unlock.shared.mayPlay else { return Unlock.shared.ask { [weak self] in self?.resume() } }
        if finished || player.currentItem == nil { return begin(at: index) }
        takeOver()
        player.play()
        publishNowPlaying()
    }

    func next() {
        guard isActive else { return }
        if index + 1 < queue.count { begin(at: index + 1) }
        else if repeatMode == .all { begin(at: 0) }
        else { endOfQueue() }
    }

    /// Back to the song's start, or, near it, the song before.
    func previous() {
        guard isActive else { return }
        if clock.position > 3 || (index == 0 && repeatMode != .all) {
            seek(to: 0)
            if !isPlaying { resume() }
        } else {
            begin(at: index > 0 ? index - 1 : queue.count - 1)
        }
    }

    func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        let target = max(0, seconds)
        clock.position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.reportProgress(force: true)
                self?.publishNowPlaying()
            }
        }
    }

    func toggleShuffle() {
        guard isActive else { return }
        let playing = queue[index]
        if isShuffled {
            queue = original
            index = queue.firstIndex(of: playing) ?? 0
        } else {
            original = queue
            var rest = queue
            rest.remove(at: index)
            queue = [playing] + rest.shuffled()
            index = 0
        }
        isShuffled.toggle()
        refillNext()
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
    }

    func cycleRepeat() {
        setRepeat(Repeat(rawValue: (repeatMode.rawValue + 1) % Repeat.allCases.count) ?? .off)
    }

    func setRepeat(_ mode: Repeat) {
        repeatMode = mode
        player.actionAtItemEnd = mode == .one ? .none : .advance
        refillNext()
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType =
            mode == .one ? .one : mode == .all ? .all : .off
    }

    /// A film or a channel is coming on: the music pauses for it and lets
    /// go of the remote's buttons and the lock screen, which are the film's
    /// now. Carried on later by Play, from where it was.
    func yield() {
        guard isActive else { return }
        player.pause()
        reportProgress(force: true)
        letGo()
    }

    /// Everything stops and the queue is emptied (signing out, Close in Now Playing).
    func stop() {
        guard isActive || player.currentItem != nil else { return }
        reportStopped()
        player.removeAllItems()
        loaded = [:]
        queue = []
        original = []
        index = 0
        source = nil
        lyrics = nil
        showsNowPlaying = false
        isWaiting = false
        clock.position = 0
        clock.duration = 0
        letGo()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: The player

    /// Starts the queue's song at `place` from its beginning, with the one
    /// after it ready behind it.
    private func begin(at place: Int) {
        reportStopped()
        player.removeAllItems()
        loaded = [:]
        finished = false
        index = place
        clock.position = 0
        clock.duration = Double(current?.runTimeTicks ?? 0) / 10_000_000
        guard let entry = queue.indices.contains(place) ? queue[place] : nil, let item = makeItem(entry) else { return }
        takeOver()
        player.insert(item, after: nil)
        refillNext()
        if startingAt > 0 {
            // Sought once it can be: a seek before then goes nowhere.
            pendingStart = (item, startingAt)
            clock.position = startingAt
            startingAt = 0
        } else {
            pendingStart = nil
        }
        isWaiting = true
        player.defaultRate = rate(for: entry.song)
        player.isMuted = DebugSound.muted
        player.play()
        songChanged()
    }

    #if DEBUG
    /// Where the song on now is read from: "file" or "server", for a script's check.
    var debugSource: String {
        guard let asset = player.currentItem?.asset as? AVURLAsset else { return "-" }
        return asset.url.isFileURL ? "file \(asset.url.lastPathComponent)" : "server"
    }
    #endif

    private func makeItem(_ entry: Entry) -> AVPlayerItem? {
        guard let stream = client?.songStream(entry.song) else { return nil }
        // Kept on the device: from the file, with or without the server. The
        // stream still names it to the server, which hears where it got to
        // when it can (and the download keeps that place when it can't).
        #if !os(tvOS)
        let url = Downloads.shared.fileURL(entry.song.id) ?? stream.url
        #else
        let url = stream.url
        #endif
        let item = AVPlayerItem(url: url)
        loaded[ObjectIdentifier(item)] = (entry, stream)
        return item
    }

    /// The song after the one playing, loaded behind it so it follows without
    /// a gap; done again whenever the queue or the repeat changes.
    private func refillNext() {
        let items = player.items()
        for extra in items.dropFirst() {
            player.remove(extra)
            loaded[ObjectIdentifier(extra)] = nil
        }
        guard repeatMode != .one, let playing = items.first else { return }
        let following = index + 1 < queue.count ? index + 1 : repeatMode == .all ? 0 : nil
        guard let following, let item = makeItem(queue[following]) else { return }
        player.insert(item, after: playing)
    }

    /// The player moved on to the next item by itself, or ran out.
    private func currentItemChanged() {
        guard let item = player.currentItem else {
            // Played to the end of the queue (not emptied to start another song,
            // which has its item by the time this is heard).
            if !queue.isEmpty, !finished { endOfQueue() }
            return
        }
        // Only what the player still holds.
        let held = Set(player.items().map(ObjectIdentifier.init))
        loaded = loaded.filter { held.contains($0.key) }
        // An item the server hasn't been told of yet came on by itself: the
        // one before it played to its end. (One begun by `begin` is told as
        // it's put in.) It may be the same song again, a queue of one on repeat.
        guard let (entry, _) = loaded[ObjectIdentifier(item)], reported?.item !== item else { return }
        guard let place = queue.firstIndex(of: entry) else { return }
        reportStopped(atEnd: true)
        // The sleep timer was waiting for that song to end: no more.
        if SleepTimer.shared.endsWithThis() { player.pause() }
        index = place
        clock.position = 0
        clock.duration = Double(entry.song.runTimeTicks ?? 0) / 10_000_000
        refillNext()
        songChanged()
    }

    private func reachedEnd(of item: AVPlayerItem?) {
        guard let item, item === player.currentItem, loaded[ObjectIdentifier(item)] != nil else { return }
        if repeatMode == .one, SleepTimer.shared.endsWithThis() {
            reportStopped(atEnd: true)
            player.pause()
            player.seek(to: .zero)
        } else if repeatMode == .one {
            // Again, as a new play of it.
            reportStopped(atEnd: true)
            player.seek(to: .zero) { [weak self] _ in
                Task { @MainActor in
                    self?.player.play()
                    self?.songChanged()
                }
            }
        } else if player.items().count == 1 {
            // The last: nothing behind it to advance to.
            reportStopped(atEnd: true)
        }
    }

    private func failed(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem, !finished else { return }
        // A song the server couldn't give: on to the next rather than stopping.
        next()
    }

    private func endOfQueue() {
        reportStopped(atEnd: true)
        player.pause()
        finished = true
        isPlaying = false
        isWaiting = false
        clock.position = 0
        publishNowPlaying()
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status != .paused
        if status == .playing { isWaiting = false }
        publishNowPlaying()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        clock.position = seconds
        if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0, abs(length - clock.duration) > 0.5 {
            clock.duration = length
        }
        reportProgress(force: false)
    }

    #if !os(macOS)
    private func interrupted(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
              isActive, !finished else { return }
        player.play()
    }
    #endif

    /// A new song came on: its words, its picture, the lock screen.
    private func songChanged() {
        guard let item = player.currentItem, let (_, stream) = loaded[ObjectIdentifier(item)] else { return }
        reported = (item, stream)
        lastProgress = Date()
        // A song the server can't give: on to the next rather than stopping there.
        itemStatus = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                if status == .failed { self?.failed(item) }
                if status == .readyToPlay { self?.startWhereAsked(item) }
            }
        }
        // An audiobook's skips on the lock screen and the remote; a song's are next and back.
        let book = stream.item.isAudiobook
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = book
        center.skipBackwardCommand.isEnabled = book
        if let client { reports.send { await client.reportStart(stream) } }
        publishNowPlaying()
        loadArtwork()
        lyrics = nil
        lyricsTask?.cancel()
        let song = stream.item
        if song.hasLyrics == true, let client {
            lyricsTask = Task {
                let words = await client.lyrics(of: song.id)
                guard !Task.isCancelled, current?.id == song.id else { return }
                lyrics = words
            }
        }
    }

    /// The item is ready: to the place it was to start from.
    private func startWhereAsked(_ item: AVPlayerItem) {
        guard let pending = pendingStart, pending.item === item else { return }
        pendingStart = nil
        seek(to: pending.seconds)
        // The server heard it start at the beginning: told the place now, or
        // an app closed in the next few seconds loses a book's place.
        reportProgress(force: true, at: pending.seconds)
    }

    // MARK: Audiobooks

    private func rate(for item: BaseItem) -> Float { item.isAudiobook ? bookSpeed : 1 }

    func setBookSpeed(_ speed: Float) {
        bookSpeed = speed
        UserDefaults.standard.set(speed, forKey: Self.bookSpeedKey)
        guard isBook else { return }
        player.defaultRate = speed
        if isPlaying { player.rate = speed }
        publishNowPlaying()
    }

    /// Back or on by so many seconds: within the part playing, or into the
    /// one after it.
    func skip(by seconds: Double) {
        guard isActive else { return }
        let target = clock.position + seconds
        if target >= clock.duration - 1, clock.duration > 0, index + 1 < queue.count {
            next()
        } else {
            seek(to: min(max(0, target), max(clock.duration - 1, 0)))
        }
    }

    // MARK: Telling the server

    private func reportProgress(force: Bool, at seconds: Double? = nil) {
        guard let (_, stream) = reported, let client, force || Date().timeIntervalSince(lastProgress) >= 10 else { return }
        lastProgress = Date()
        let ticks = Int64((seconds ?? clock.position) * 10_000_000)
        let paused = !isPlaying
        reports.send { await client.reportProgress(stream, positionTicks: ticks, paused: paused, audioIndex: nil, subtitleIndex: nil) }
    }

    /// The song playing has stopped: where it got to, or its end.
    private func reportStopped(atEnd: Bool = false) {
        guard let (_, stream) = reported, let client else { return }
        reported = nil
        let ticks = atEnd ? (stream.item.runTimeTicks ?? Int64(clock.duration * 10_000_000)) : Int64(clock.position * 10_000_000)
        PlaybackReports.shared.track(reports.send { await client.reportStopped(stream, positionTicks: ticks) })
    }

    // MARK: The lock screen and the remote

    /// The sound and the system's controls are the music's: a film's player
    /// may have had them since it last played.
    private func takeOver() {
        NotificationCenter.default.post(name: Self.willPlay, object: nil)
        ThemeMusic.shared.stop()
        #if os(iOS)
        if CarPlayPlayer.shared.current != nil || CarPlayPlayer.shared.channel != nil {
            Task { await CarPlayPlayer.shared.stop() }
        }
        #endif
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ handle: @escaping (MPRemoteCommandEvent) -> Bool) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { handle(event) } ? .success : .commandFailed
            }
            remoteTargets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in self?.resume(); return true }
        on(center.pauseCommand) { [weak self] _ in self?.pause(); return true }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePause(); return true }
        on(center.nextTrackCommand) { [weak self] _ in self?.next(); return true }
        on(center.previousTrackCommand) { [weak self] _ in self?.previous(); return true }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return false }
            self?.seek(to: event.positionTime)
            return true
        }
        on(center.changeShuffleModeCommand) { [weak self] event in
            guard let self, let event = event as? MPChangeShuffleModeCommandEvent else { return false }
            if (event.shuffleType != .off) != isShuffled { toggleShuffle() }
            return true
        }
        on(center.changeRepeatModeCommand) { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return false }
            self?.setRepeat(event.repeatType == .one ? .one : event.repeatType == .all ? .all : .off)
            return true
        }
        // An audiobook's: a quarter minute back, half a minute on. Switched
        // on only while one plays (see `songChanged`): a song's are next and back.
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { [weak self] _ in self?.skip(by: 30); return true }
        on(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -15); return true }
        center.skipForwardCommand.isEnabled = isBook
        center.skipBackwardCommand.isEnabled = isBook
    }

    private func letGo() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func publishNowPlaying() {
        guard let song = current, !remoteTargets.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate(for: song)) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate(for: song)),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if clock.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = clock.duration }
        if let artist = song.byLine { info[MPMediaItemPropertyArtist] = artist }
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork, artwork.songId == song.id || artwork.songId == song.albumId { info[MPMediaItemPropertyArtwork] = artwork.art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if !os(tvOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func loadArtwork() {
        #if !os(tvOS)
        let kept = current.flatMap { Downloads.shared.imageURL($0.id) }
        #else
        let kept: URL? = nil
        #endif
        guard let song = current, let client, let url = kept ?? client.imageURL(for: song, type: "Primary", maxWidth: 600) else { return }
        let key = song.albumId ?? song.id
        if artwork?.songId == key { return publishNowPlaying() }
        Task {
            guard let image = await ImagePipeline.load(url), current?.id == song.id else { return }
            artwork = (key, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
            publishNowPlaying()
        }
    }
}
