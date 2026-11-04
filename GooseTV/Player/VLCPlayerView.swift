import SwiftUI
import AVFoundation
import MediaPlayer
import VLCKitSPM

/// Plays through VLC what AVPlayer can't decode (AV1, VP9, MPEG-2, MPEG-4 Part 2, …),
/// as the original file, so the server doesn't have to transcode. VLC has no
/// playback UI of its own; the app's controls (`PlayerChrome`) go over it.
struct VLCPlayerView: View {
    let onClose: () -> Void
    private let chapters: [Chapter]
    private let breaks: [SkipSegment]
    private let trickplay: Trickplay?

    @StateObject private var playback: VLCPlayback
    /// A fold across the player (an iPhone Duo half-open on its side).
    @State private var fold: TabletopFold?

    init(context: PlaybackContext, client: (any MediaServer)?, segments: [SkipSegment] = [],
         chapters: [Chapter] = [],
         onCreditsReached: @escaping () -> Void = {},
         onFinished: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.chapters = chapters
        self.breaks = segments.filter { $0.kind == .commercial }
        self.trickplay = context.trickplay
        // Made inside the autoclosure, which SwiftUI runs only the first time:
        // built out here, every redraw of the screen behind (the credits card
        // arriving, the player closing) made a whole VLC player on the main
        // thread and threw it away.
        _playback = StateObject(wrappedValue: VLCPlayback(context: context, client: client, segments: segments,
                                                          onCreditsReached: onCreditsReached,
                                                          onFinished: onFinished))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VLCVideoSurface(player: playback.player)
                .ignoresSafeArea()
                .aboveTabletopFold(fold)

            if playback.failed {
                PlayerNotice(item: playback.item,
                             icon: "exclamationmark.triangle.fill",
                             title: String(localized: "Can't play this"),
                             message: String(localized: "VLC couldn't play this file."),
                             tint: Theme.palette[1].1) { playback.stop(); onClose() }
            } else if playback.stalled {
                StalledNotice(item: playback.item) { playback.stop(); onClose() }
            } else {
                PlayerChrome(engine: playback, chapters: chapters, breaks: breaks, trickplay: trickplay,
                             badge: "VLC") {
                    playback.stop()
                    onClose()
                }
                .belowTabletopFold(fold)
            }
        }
        .background(Color.black)
        .readsTabletopFold($fold)
        .onAppear { playback.start() }
        .onDisappear { playback.stop() }
    }
}

/// The view VLC draws video into.
private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> VLCSurfaceView {
        let view = VLCSurfaceView()
        view.backgroundColor = .black
        view.player = player
        #if os(iOS)
        view.fills = PlayerStage.shared.onCarScreen
        #endif
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: VLCSurfaceView, context: Context) {}
}

/// VLC's picture. On a car's screen, wider than a film, it fills the view:
/// the film is cropped to the view's shape, rather than shown with bars.
final class VLCSurfaceView: UIView {
    weak var player: VLCMediaPlayer?
    var fills = false
    private var cropped: String?

    #if os(macOS)
    override func layout() {
        super.layout()
        cropToShape()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        cropToShape()
    }
    #endif

    private func cropToShape() {
        guard fills, let player, bounds.width > 1, bounds.height > 1 else { return }
        let shape = "\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))"
        guard shape != cropped else { return }
        cropped = shape
        shape.withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
    }
}

extension VLCMediaPlayer {
    /// Done with for good: stopped, and let go of away from the main thread.
    ///
    /// VLC stops in the background and takes its time over it, and what it
    /// is stopping (the picture's view, the sound) needs the main thread to
    /// finish. Letting go of the player waits for all of that, on whichever
    /// thread held it last; on the main thread, each then waits for the
    /// other for good, and the app is dead (see `LiveTuner`, where it was
    /// met). So the player is held here until VLC says it has stopped,
    /// however long that is, then until the kit's own notices of it (each
    /// has a hold on the player, and lets go on the main thread) have been
    /// through, and released from a thread nothing else is waiting on.
    @MainActor
    func retire() {
        delegate = nil
        DispatchQueue.global(qos: .utility).async { [self] in
            stop()
            // The kit says "stopped" once VLC has closed the stream, and
            // not before. Up to a minute: one that won't stop isn't waited
            // on for ever.
            var tenths = 0
            while tenths < 600, state != .stopped { usleep(100_000); tenths += 1 }
            // Twice through the main thread's queue, behind anything of the
            // kit's that was waiting there or put there by the first.
            DispatchQueue.main.sync {}
            DispatchQueue.main.sync {}
        }
    }
}

/// Owns the VLC player: starts at the resume point, publishes time for the
/// overlay, and reports progress to Jellyfin like the AVPlayer path does.
@MainActor
final class VLCPlayback: NSObject, ObservableObject, VLCMediaPlayerDelegate, PlayerEngine {
    /// With a library of its own, so that its subtitles can be told how
    /// Settings wants them: VLC draws those itself.
    let player = VLCMediaPlayer(options: SubtitleAppearance.vlcOptions)
    let item: BaseItem

    /// Seconds into the film; see PlayerClockState for why it isn't published.
    private var clock = PlayerClockState()
    var position: Double { clock.seconds }
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false
    /// Playing, but the clock hasn't moved for 15s: it isn't going to.
    @Published private(set) var stalled = false
    /// The segment the film is inside now, if any.
    @Published private(set) var activeSkip: SkipSegment?
    @Published private(set) var rate: Float = 1
    /// VLC's own tracks, as the chooser wants them. Rebuilt when a track or
    /// the number of them changes, not read back from VLC on every redraw:
    /// the controls redraw four times a second, and each read crosses into
    /// VLC and copies its arrays.
    @Published private(set) var trackList = TrackList()
    @Published private(set) var audioDelay: Double?
    /// What's playing now. VLC numbers its own tracks and -1 means off, which
    /// is why these aren't positions in the lists above.
    private var audioTrackId: Int32 = -1
    private var subtitleTrackId: Int32 = -1
    private var trackCounts: (audio: Int32, subtitles: Int32) = (-1, -1)

    /// Intros and credits worth offering to skip, in film seconds. VLC plays the
    /// original file, so its clock is the film's and needs no offset.
    private let segments: [SkipSegment]
    private let context: PlaybackContext
    private let client: (any MediaServer)?
    private let onFinished: () -> Void
    private var progressTimer: Timer?
    private var watchdog: Timer?
    private var backgroundObserver: NSObjectProtocol?
    private var lastPosition: Double = -1
    private var stuckSince: Date?
    private var started = false
    private var stopped = false
    /// Whether the viewer has picked a track, after which VLC's own answer
    /// stops being read back over theirs.
    private var choseAudio = false
    /// The audio track to open on, by its place among the file's, until set.
    private var openingAudio: Int?
    private var appliedAudioDelay = false
    private var choseSubtitle = false
    private var reachedCredits = false
    /// A recording made off the air is a transport stream, which VLC,
    /// fetching it from a server, can't find its way about by time: asked
    /// for a time it goes to that fraction of the file, and a broadcast's
    /// bytes don't run evenly (an hour of news measured out by as much as
    /// 79 seconds), and asked to begin part-way it begins at the beginning.
    /// The place for a time is found by the stream's own clock instead
    /// (`TransportFile`), and the player sent to that byte.
    private var transport: TransportFile?
    /// How far the stream's clock at the file's first byte is ahead of the
    /// player's nought (its first picture comes a second or so in): learnt
    /// once the film is running.
    private var clockLead: Double?
    private var seeking: Task<Void, Never>?
    /// Where the film is to be taken up, until it has been: the player is
    /// asked to begin there, and where it begins at the beginning instead
    /// it's sent there, held silent and still called loading until it lands.
    private var resuming: Double?
    private var resumeAsked: Date?
    private var resumeDoubts = 0
    /// What was handed to the remote-command centre, to take back on stop.
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    /// Said once, when the credits start.
    private let onCreditsReached: () -> Void

    var soundModes: Bool { true }
    /// Keeps the reports in the order they were made.
    private let reports = PlaybackReportQueue()

    init(context: PlaybackContext, client: (any MediaServer)?, segments: [SkipSegment],
         onCreditsReached: @escaping () -> Void = {}, onFinished: @escaping () -> Void) {
        self.context = context
        self.client = client
        self.segments = segments
        self.onCreditsReached = onCreditsReached
        self.onFinished = onFinished
        item = context.item
        super.init()
        audioDelay = AudioSync.offset(for: context.item.id)

        let media = VLCMedia(url: context.url)
        if DebugSound.muted { media.addOption(":no-audio") }
        AudioClarity.shared.attach(player)
        // More in hand than the player's own second, where the sound is
        // going somewhere that takes longer than that over it (see
        // `PlaybackAudioSession.inHand`).
        let inHand = PlaybackAudioSession.inHand(atLeast: 1000)
        if inHand > 1000 {
            media.addOption(":network-caching=\(inHand)")
            media.addOption(":file-caching=\(inHand)")
        }
        if context.startTicks > 0 {
            media.addOption(":start-time=\(Double(context.startTicks) / 10_000_000)")
        }
        // The subtitle inside the file that was picked, or that the account
        // would pick. VLC counts a file's subtitles from zero in the order the
        // server lists them; left to itself it shows whichever the file flags.
        let inside = context.mediaStreams.filter { $0.type == "Subtitle" && $0.isExternal != true }
        if let wanted = context.defaultSubtitleIndex,
           let position = inside.firstIndex(where: { $0.index == wanted }) {
            media.addOption(":sub-track=\(position)")
        }
        // The same for sound: the track the server would pick (the account's
        // language, or the first), not whichever the file happens to flag,
        // which on a multi-language remux can be a dub.
        // Set once VLC has listed the file's tracks (see openingAudio): the
        // ":audio-track" option left TrueHD files silent.
        let audio = context.mediaStreams.filter { $0.type == "Audio" && $0.isExternal != true }
        if let wanted = context.audioIndex, audio.count > 1,
           let position = audio.firstIndex(where: { $0.index == wanted }) {
            openingAudio = position
        }
        player.media = media
        player.delegate = self
        if let ticks = context.item.runTimeTicks { duration = Double(ticks) / 10_000_000 }
        if context.startTicks > 0 { resuming = Double(context.startTicks) / 10_000_000 }
        let sources = context.item.mediaSources ?? []
        let container = (sources.first { $0.id == context.mediaSourceId } ?? sources.first)?.container?.lowercased() ?? ""
        if context.isDirect, ["ts", "mpegts"].contains(where: { container.split(separator: ",").contains(Substring($0)) }),
           let request = client?.fileRequest(itemId: context.item.id) {
            transport = TransportFile(file: request)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        player.play()
        // Subtitle files beside the film aren't in its stream; VLC fetches them
        // and lists them with the film's own. The one the account would pick is
        // switched on.
        for file in context.subtitleFiles {
            player.addPlaybackSlave(file.url, type: .subtitle, enforce: file.index == context.defaultSubtitleIndex)
        }
        let (client, context) = (client, context)
        reports.send { await client?.reportStart(context) }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            #if os(iOS)
            // VLC has no picture-in-picture, and the app may play on in the
            // background (for the system player's), so it would carry on as
            // sound alone: pause instead. Not on the car's screen, where
            // sound alone is what's wanted when the app's put behind another.
            MainActor.assumeIsolated {
                if self?.player.isPlaying == true, !PlayerStage.shared.onCarScreen { self?.player.pause() }
            }
            #endif
            // Delivered on the main queue.
            MainActor.assumeIsolated { self?.reportProgress() }
        }

        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reportProgress()
                self?.publishNowPlaying()
            }
        }
        becomeNowPlaying()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForStall() }
        }
    }

    private func checkForStall() {
        guard !stopped else { return }
        if position != lastPosition {
            lastPosition = position
            stuckSince = nil
            if stalled { stalled = false }
            return
        }
        // Paused on purpose. The count starts again on resuming: carried over,
        // a stall that began before the pause was reported on the first check
        // after it.
        guard player.isPlaying else { stuckSince = nil; return }
        let since = stuckSince ?? Date()
        stuckSince = since
        if Date().timeIntervalSince(since) >= 15 { stalled = true }
    }

    // MARK: Tracks

    /// Reads VLC's tracks, numbered its way with -1 for off, into the list.
    private func refreshTracks() {
        var list = TrackList()
        // VLC's "Disabled" entry is dropped from audio, where it would sit above
        // the track being looked for, and kept in subtitles, where it is how they
        // get turned off.
        list.audio = tracks(names: player.audioTrackNames, ids: player.audioTrackIndexes)
            .filter { $0.id != "-1" }
        let subtitles = tracks(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes)
        list.subtitles = subtitles.map {
            $0.id == "-1" ? PlayerTrack(id: TrackList.subtitlesOff, name: String(localized: "Off", comment: "Subtitles turned off")) : $0
        }
        list.currentAudio = "\(audioTrackId)"
        list.currentSubtitle = subtitleTrackId == -1 ? TrackList.subtitlesOff : "\(subtitleTrackId)"
        if list != trackList { trackList = list }
        if started, reportedTracks != [list.currentAudio, list.currentSubtitle] { reportProgress() }
    }

    func selectAudio(_ id: String) {
        guard let index = Int32(id) else { return }
        player.currentAudioTrackIndex = index
        audioTrackId = index
        choseAudio = true
        refreshTracks()
    }

    func selectSubtitle(_ id: String) {
        let index = id == TrackList.subtitlesOff ? -1 : (Int32(id) ?? -1)
        player.currentVideoSubTitleIndex = index
        subtitleTrackId = index
        choseSubtitle = true
        refreshTracks()
    }

    var mediaSourceId: String? { context.mediaSourceId }
    var takesFoundSubtitles: Bool { !context.url.isFileURL }
    var playbackContext: PlaybackContext? { context }

    /// VLC counts its rates in bytes a microsecond.
    func liveStats() -> LiveStats {
        var stats = LiveStats()
        if let numbers = player.media?.statistics {
            if numbers.demuxBitrate > 0 { stats.bitrate = Double(numbers.demuxBitrate) * 8_000_000 }
            if numbers.inputBitrate > 0 { stats.throughput = Double(numbers.inputBitrate) * 8_000_000 }
            stats.droppedFrames = Int(numbers.lostPictures)
        }
        return stats
    }

    /// VLC fetches the file, lists it a moment later and, told to, turns it
    /// on. Its answer is read back again until it has, as at the start.
    func show(_ found: FoundSubtitle) {
        choseSubtitle = false
        player.addPlaybackSlave(found.file, type: .subtitle, enforce: true)
    }

    /// The two arrays run in step: a name and the id to set to get it.
    private func tracks(names: [Any]?, ids: [Any]?) -> [PlayerTrack] {
        guard let names, let ids else { return [] }
        return zip(names, ids).compactMap { name, id in
            guard let name = name as? String, let id = (id as? NSNumber)?.int32Value else { return nil }
            return PlayerTrack(id: "\(id)", name: name)
        }
    }

    /// VLC draws its own subtitles, on time; there's nothing to shift.
    var subtitleDelay: Double? { nil }
    func setSubtitleDelay(_ seconds: Double) {}

    /// Working it out from the subtitles needs the sound and the subtitles'
    /// times, and VLC keeps both to itself.
    var audioSyncDetection: AudioSyncDetection? { nil }
    func detectAudioSync() {}

    /// VLC counts the sound's delay in millionths of a second, later being
    /// positive as here.
    func setAudioDelay(_ seconds: Double) {
        player.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
        audioDelay = seconds
        AudioSync.set(seconds, for: item.id)
    }

    func setRate(_ rate: Float) {
        player.rate = rate
        self.rate = rate
        publishNowPlaying()
    }

    func togglePause() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    /// Jumps to a point in the film.
    ///
    /// Playing first, because VLC drops a seek made while it is paused — which
    /// is exactly the state scrubbing leaves it in, so the mark was landing
    /// nowhere. Position is set in preference to time: given a length, a
    /// fraction is what VLC honours most reliably.
    func seek(toFilmSeconds seconds: Double) {
        let target = max(seconds, 0)
        seeking?.cancel()
        if let transport, duration > 0 {
            // By the stream's clock: the byte the moment is at, found on
            // the server (two or three small reads), and the player sent
            // there. The controls show the moment at once; another press
            // before it lands starts from there.
            let lead = clockLead ?? 0
            move(to: target)
            activeSkip = nil
            seeking = Task { [weak self] in
                let place = await Task.detached { transport.place(atSeconds: target + lead) }.value
                guard let self, !Task.isCancelled else { return }
                if !player.isPlaying { player.play() }
                if let place, place.size > 0 {
                    player.position = Float(min(Double(place.offset) / Double(place.size), 0.9995))
                } else {
                    player.position = Float(min(target / duration, 0.999))
                }
                publishNowPlaying()
                reportProgress()
            }
            return
        }
        if !player.isPlaying { player.play() }
        if duration > 0 {
            player.position = Float(min(target / duration, 0.999))
        } else {
            player.time = VLCTime(int: Int32(target * 1000))
        }
        move(to: target)
        activeSkip = nil
        publishNowPlaying()
        reportProgress()
    }

    func controlsShown(_ shown: Bool) {
        if clock.show(shown) { objectWillChange.send() }
    }

    private func move(to seconds: Double) {
        if clock.move(to: seconds) { objectWillChange.send() }
    }

    /// Through seek, which plays first: VLC's own jumps are dropped while it's
    /// paused, as a seek is, so a skip from the paused controls did nothing.
    func skip(_ seconds: Int32) {
        seek(toFilmSeconds: position + Double(seconds))
    }

    // Not let go on the main thread, where a player still stopping can
    // hold the app up for good (see `retire`).
    deinit {
        let player = player
        Task { @MainActor in player.retire() }
    }

    func stop(finished: Bool = false) {
        guard started, !stopped else { return }
        stopped = true
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        progressTimer?.invalidate()
        watchdog?.invalidate()
        stopBeingNowPlaying()
        let ticks = finished ? (context.item.runTimeTicks ?? currentTicks) : currentTicks
        player.stop()
        PlaybackAudioSession.release()
        let (client, context) = (client, context)
        PlaybackReports.shared.track(reports.send { _ = await client?.reportStopped(context, positionTicks: ticks) })
    }

    private var currentTicks: Int64 {
        position > 0 ? Int64(position * 10_000_000) : context.startTicks
    }

    private func reportProgress() {
        guard !stopped else { return }
        let (client, context, ticks, paused) = (client, context, currentTicks, !player.isPlaying)
        let tracks = trackList
        reportedTracks = [tracks.currentAudio, tracks.currentSubtitle]
        let audio = context.serverIndex(forTrackId: tracks.currentAudio, in: tracks.audio, kind: "Audio")
        let subtitle = context.serverIndex(forTrackId: tracks.currentSubtitle, in: tracks.subtitles, kind: "Subtitle")
        reports.send {
            await client?.reportProgress(context, positionTicks: ticks, paused: paused, audioIndex: audio, subtitleIndex: subtitle)
        }
    }
    /// The tracks the server was last told were on.
    private var reportedTracks: [String?] = []

    // MARK: Now playing

    /// What the iPhone remote and Control Center show and control. The system
    /// player does all of this itself; VLC knows nothing of it, so without this
    /// a film played here was invisible to both.
    private func becomeNowPlaying() {
        // Playback, so the system treats this as the app that's playing.
        PlaybackAudioSession.take()

        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ handle: @escaping (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { handle(event) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in if self?.player.isPlaying == false { self?.player.play() } }
        on(center.pauseCommand) { [weak self] _ in if self?.player.isPlaying == true { self?.player.pause() } }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePause() }
        center.skipForwardCommand.preferredIntervals = [30]
        on(center.skipForwardCommand) { [weak self] _ in self?.skip(30) }
        center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipBackwardCommand) { [weak self] _ in self?.skip(-10) }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            self?.seek(toFilmSeconds: event.positionTime)
        }

        publishNowPlaying()
        if let url = client?.imageURL(for: item, type: "Primary", maxWidth: 600) {
            Task { [weak self] in
                guard let image = await ImagePipeline.load(url) else { return }
                self?.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self?.publishNowPlaying()
            }
        }
    }

    private func publishNowPlaying() {
        guard started, !stopped else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if item.isEpisode, let series = item.seriesName { info[MPMediaItemPropertyArtist] = series }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func stopBeingNowPlaying() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: VLCMediaPlayerDelegate (called on the main thread)

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            let reported = Double(player.time.intValue) / 1000
            if let transport, clockLead == nil, reported > 0 {
                // Where the player's nought is on the stream's clock, by one
                // reading of that clock where the player says it is.
                clockLead = 0
                let through = Double(player.position)
                Task { [weak self] in
                    let lead = await Task.detached { () -> Double? in
                        guard let size = transport.measure()?.size,
                              let clock = transport.seconds(atOffset: Int64(through * Double(size))) else { return nil }
                        return clock - reported
                    }.value
                    // A second or two, where it's anything: more is a
                    // reading that went wrong.
                    if let self, let lead, lead > -1, lead < 15 { self.clockLead = lead }
                }
            }
            if let wanted = resuming {
                if reported >= wanted - 6 {
                    // Taken up where it was left.
                    resuming = nil
                    player.audio?.isMuted = false
                } else if seeking == nil, resumeAsked == nil {
                    // Asked to begin there, and begun at the beginning: sent,
                    // once it has said so twice (a player may give a first
                    // reading before it has gone where it was told). Sent the
                    // once: where there's no reading the file's clock (an
                    // Emby server, a file of another kind) the move is a
                    // guess by its share of the file, and a guess short of the
                    // place was sent again on every tick, for good.
                    resumeDoubts += 1
                    guard resumeDoubts >= 2 else { return }
                    player.audio?.isMuted = true
                    resumeAsked = Date()
                    seek(toFilmSeconds: wanted)
                    return
                } else {
                    // On its way: nothing of the beginning is shown as where
                    // the film is, or reported as where it got to.
                    if resumeAsked == nil { resumeAsked = Date() }
                    if let since = resumeAsked, Date().timeIntervalSince(since) > 12 {
                        // It isn't going to: played from where it is.
                        resuming = nil
                        player.audio?.isMuted = false
                    }
                    return
                }
            }
            move(to: reported)
            // Set only on a change: setting a published value announces it
            // whether it changed or not, which was four redraws a second.
            if let length = player.media?.length.intValue, length > 0, Double(length) / 1000 != duration {
                duration = Double(length) / 1000
            }
            if isLoading { isLoading = false }
            // What was set for this title before, once the film is running:
            // set any sooner, VLC starts the film without it.
            if !appliedAudioDelay {
                appliedAudioDelay = true
                if let audioDelay, audioDelay != 0 { player.currentAudioPlaybackDelay = Int(audioDelay * 1_000_000) }
            }
            // VLC picks the opening tracks itself, and only once the file is
            // parsed, so they are read back until the viewer picks for
            // themselves — after which they are not, because VLC applies a
            // change a moment after being asked and would otherwise report the
            // old track back over the new one, four times a second, until it
            // caught up. Nothing but this app changes them.
            // The counts are cheap to ask for, and change as the file is parsed
            // and as subtitle files beside it arrive.
            let counts = (audio: player.numberOfAudioTracks, subtitles: player.numberOfSubtitlesTracks)
            var tracksChanged = counts != trackCounts
            trackCounts = counts
            // VLC numbers tracks its own way; its list leads with "Disable".
            if let position = openingAudio, !choseAudio {
                let ids = (player.audioTrackIndexes as? [NSNumber] ?? []).map(\.int32Value).filter { $0 != -1 }
                if ids.indices.contains(position) {
                    openingAudio = nil
                    if player.currentAudioTrackIndex != ids[position] { player.currentAudioTrackIndex = ids[position] }
                }
            }
            if !choseAudio, audioTrackId != player.currentAudioTrackIndex {
                audioTrackId = player.currentAudioTrackIndex
                tracksChanged = true
            }
            if !choseSubtitle, subtitleTrackId != player.currentVideoSubTitleIndex {
                subtitleTrackId = player.currentVideoSubTitleIndex
                tracksChanged = true
            }
            if tracksChanged { refreshTracks() }
            let inSegment = segments.first { $0.contains(position) }
            if inSegment != activeSkip { activeSkip = inSegment }
            // The credits, as marked, or the last minute when nothing marked
            // them — which is what makes this work on a server with no plugin.
            if !reachedCredits {
                let marked = inSegment?.kind == .outro
                let nearEnd = duration > 180 && position >= duration - 20
                    && segments.allSatisfy { $0.kind != .outro }
                if marked || nearEnd {
                    reachedCredits = true
                    onCreditsReached()
                }
            }
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            if isPlaying != player.isPlaying {
                isPlaying = player.isPlaying
                publishNowPlaying()
                // Told now rather than at the next report, for a remote showing it.
                if started { reportProgress() }
            }
            switch player.state {
            case .ended:
                stop(finished: true)
                onFinished()
            case .error:
                isLoading = false
                failed = true
            default:
                break
            }
        }
    }
}
