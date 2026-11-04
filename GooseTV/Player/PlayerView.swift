import SwiftUI
import AVKit

/// Full-screen playback. Resolves the stream via PlaybackInfo (direct play when the
/// Apple TV can handle the file natively, HLS transcode otherwise), resumes from the
/// saved position, and reports progress back to Jellyfin so Continue Watching stays in sync.
/// When an episode ends it moves on to the next one, if the account allows auto-play;
/// given a queue (Play All, Shuffle), it works through that instead.
struct PlayerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// Set where the player is on a stage of its own rather than a cover
    /// (iPhone and iPad): what closes it there.
    @Environment(\.playerClose) private var closeStage
    let item: BaseItem
    /// Which version to play, when the film is kept in more than one. Nil takes
    /// whichever the server lists first.
    var mediaSourceId: String?
    /// Start at the top rather than at the saved position.
    var fromBeginning = false
    /// What to play after `item`, in order, for Play All and Shuffle. Empty
    /// for everything else, where an episode is followed by the next one.
    var queue: [BaseItem] = []

    /// What's playing: `item`, then each episode auto-play moves on to.
    @State private var current: BaseItem?
    @State private var context: PlaybackContext?
    @State private var errorMessage: String?
    /// Set when playback hasn't advanced for a while: usually a damaged file.
    @State private var stalled = false
    /// Tracks chosen from the panel, by the server's numbering. A transcode
    /// carries the tracks it was asked for, so changing one means resolving the
    /// stream again — hence the token, which is what makes the task re-run.
    @State private var chosenAudio: Int?
    @State private var chosenSubtitle: Int?
    @State private var resumeFrom: Int64?
    @State private var reloadToken = 0
    /// Intros and credits the server has marked for what's playing.
    @State private var segments: [SkipSegment] = []
    /// The film's chapters, which arrive with the item rather than the stream.
    @State private var chapters: [Chapter] = []
    /// The episode after this one, waiting on the card while the countdown runs.
    /// When the player opened, for ReviewPrompt's count of real watching.
    @State private var openedAt = Date()
    @State private var upNext: BaseItem?
    /// Whether that card is riding over the credits rather than standing in for
    /// a finished episode: smaller, in the corner, with the film still playing.
    @State private var upNextOverCredits = false
    /// The credits of what's playing were skipped without asking.
    @State private var creditsSkipped = false
    /// What's been skipped in what's playing, and when the viewer last moved
    /// through it: kept here, where it outlasts a stream started again.
    @State private var skipMemory = SkipMemory()
    /// The films played here that were on the watchlist as they began: any
    /// of them watched through comes off it as the player closes.
    @State private var listedFilms: Set<String> = []
    /// Where `current` is in `[item] + queue`.
    @State private var queueIndex = 0
    /// Set as the player closes, so the system player files its stop report
    /// there and then rather than once the cover has animated away.
    @State private var closing = false
    /// How the sleep timer stops the film when it runs out.
    @State private var sleepToken: UUID?
    /// Watching together, the film ended or the group stopped it: the player
    /// closes with this device still in the group, for what it plays next.
    /// Closed any other way, it leaves.
    @State private var endedTogether = false

    var body: some View {
        Group {
            if let context {
                Group {
                    switch context.engine {
                    case .avPlayer:
                        SystemPlayerView(context: context, client: app.client, subtitles: app.preferences,
                                         segments: segments, chapters: chapters, closing: closing,
                                         onStalled: { stalled = true },
                                         onResumed: { stalled = false },
                                         onFailed: { reason in
                                             self.context = nil
                                             errorMessage = reason
                                         },
                                         onCreditsReached: { Task { await creditsReached(context.item) } },
                                         onSelectTracks: { audio, subtitle, ticks in
                                             chosenAudio = audio
                                             chosenSubtitle = subtitle
                                             resumeFrom = ticks
                                             self.context = nil
                                             reloadToken += 1
                                         },
                                         onFinished: { Task { await finished(context.item) } },
                                         onClose: { close() })
                    case .aether:
                        AetherPlayerView(context: context, client: app.client,
                                         segments: segments, chapters: chapters,
                                         onCreditsReached: { Task { await creditsReached(context.item) } },
                                         // Played the usual way instead, from where it got to,
                                         // and the usual way for as long as the app is open.
                                         onRefused: { ticks in
                                             OnDevicePlayback.refuse(context.item.id)
                                             resumeFrom = ticks
                                             self.context = nil
                                             reloadToken += 1
                                         },
                                         onFinished: { Task { await finished(context.item) } },
                                         onClose: { close() })
                    case .vlc:
                        VLCPlayerView(context: context, client: app.client,
                                      segments: segments, chapters: chapters,
                                      onCreditsReached: { Task { await creditsReached(context.item) } },
                                      onFinished: { Task { await finished(context.item) } },
                                      onClose: { close() })
                    }
                }
                .id(context.item.id)   // a fresh player per episode
                .environment(\.creditsSkipped, { creditsSkipped = true; upNext = nil; upNextOverCredits = false })
                .environment(\.skipMemory, skipMemory)
                .environment(\.watchTogether, WatchTogetherHooks(
                    onward: app.preferences?.autoPlayNextEpisode ?? true,
                    switchTo: { id in Task { await switchTogether(to: id) } },
                    stop: { endedTogether = true; close() }))
                .ignoresSafeArea()
                .overlay {
                    if stalled { StalledNotice(item: context.item) { close() } }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let upNext, upNextOverCredits, !stalled {
                        UpNextCard(next: upNext, compact: true,
                                   onPlay: { play(upNext) },
                                   onStop: { self.upNext = nil; upNextOverCredits = false })
                            .padding(.trailing, 60)
                            .padding(.bottom, 60)
                            .transition(.opacity)
                    }
                }
            } else if let upNext {
                UpNextCard(next: upNext,
                           onPlay: { play(upNext) },
                           onStop: { close() })
            } else if let errorMessage {
                PlayerNotice(item: current ?? item,
                             icon: "exclamationmark.triangle.fill",
                             title: String(localized: "Can't play this"),
                             message: errorMessage,
                             tint: Theme.palette[1].1) { close() }
            } else {
                PlayerNotice(item: current ?? item, title: (current ?? item).displayTitle,
                             message: String(localized: "Getting the stream ready…")) { close() }
            }
        }
        .appBackground()
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // One film at a time: the car's player starting closes this one, and
        // this one opening stops the car's.
        .onReceive(NotificationCenter.default.publisher(for: CarPlayPlayer.willPlay)) { _ in close() }
        // The film's picture-in-picture window was closed with the film in it.
        .onReceive(NotificationCenter.default.publisher(for: PlayerStage.closeAsked)) { _ in close() }
        .task { await CarPlayPlayer.shared.stop() }
        #endif
        #if os(macOS)
        // The player's window was closed (its button, ⌘W): closed as its own button does.
        .onReceive(NotificationCenter.default.publisher(for: MacPlayerStage.closeAsked)) { _ in close() }
        #endif
        // Another film sent from a phone: this closes for it, the controls
        // up or not (getting the stream ready, say, or Up Next's card).
        .onReceive(NotificationCenter.default.publisher(for: RemoteControl.takingOver)) { _ in
            if !closing { close() }
        }
        // The last minute of the sleep timer, said over the picture; and
        // when it runs out, the film closed as Back closes it.
        .overlay { SleepCountdown() }
        .onAppear { sleepToken = SleepTimer.shared.register { close() } }
        .onAppear { SyncPlay.shared.playersOpen += 1 }
        // A title's theme song under its page gives way to the film, and
        // music pauses for it.
        .onAppear { ThemeMusic.shared.stop(); MusicPlayer.shared.yield() }
        .onReceive(NotificationCenter.default.publisher(for: MusicPlayer.willPlay)) { _ in
            if !closing { close() }
        }
        .task(id: "\(current?.id ?? item.id)#\(reloadToken)") { await load(current ?? item) }
        // Tells every screen that shows progress, once the position just
        // watched has reached the server. Each screen used to refresh only
        // when a film it opened itself closed, so one played from its detail
        // page left Home's Continue Watching as it was.
        .onDisappear {
            SleepTimer.shared.forget(sleepToken)
            // Set to stop when this film ends, and the film's closed: it's
            // nothing to wait for anywhere else (Live TV would show it set).
            if SleepTimer.shared.atEnd { SleepTimer.shared.cancel() }
            SyncPlay.shared.playersOpen -= 1
            if !endedTogether { Task { await SyncPlay.shared.leave() } }
            ReviewPrompt.notePlay(lasting: Date().timeIntervalSince(openedAt))
            Task {
                await PlaybackReports.shared.settle()
                await app.leaveWatchlist(watched: listedFilms)
                app.userDataChanged()
                // A beat for the player's cover to finish going.
                try? await Task.sleep(for: .milliseconds(800))
                if ReviewPrompt.isDue { app.reviewDue = true }
            }
        }
    }

    private func load(_ target: BaseItem) async {
        guard let client = app.client else { return }
        errorMessage = nil
        stalled = false
        // Subtitle choices are applied as the player starts, so have them ready.
        // Tasks rather than async lets: those must be awaited on every path,
        // and a throw below leaves them unawaited.
        let preferencesReady = Task { await loadPreferencesIfNeeded() }
        var switching = false
        #if !os(tvOS)
        // Downloaded: played from the file, with or without the server.
        if let file = Downloads.shared.fileURL(target.id) {
            await playDownloaded(target, file: file, client: client)
            await preferencesReady.value
            return
        }
        #endif
        // The version chosen on the film's page is that film's. An episode
        // played on after it, or the next in a queue, has versions of its own,
        // and asked for one of the first film's, the server has none to offer.
        let sourceId = target.id == item.id ? mediaSourceId : nil
        // Worked out on the film's page already (see PlaybackPrep), when this
        // is the ordinary start: the saved position, the default tracks.
        // Watching together: where the group is in it, not where this
        // account left it.
        // Or asked for from another device, from where it said; saying
        // nowhere is the start (Jellyfin's web app leaves a start of 0 out).
        let together = SyncPlay.shared.position(of: target.id).map { Int64(($0.seconds * 10_000_000).rounded()) }
            ?? RemoteControl.shared.takeStart(for: target.id).map { $0.startTicks ?? 0 }
        // A show's tracks as the viewer last chose them in it, for its other
        // episodes: worked out from this one's streams below, so not the
        // ordinary start the film's page readied.
        let remembered = chosenAudio == nil && chosenSubtitle == nil && PlaybackPreferences.remembersTracks
            ? target.seriesId.flatMap(TrackMemory.choice(forShow:)) : nil
        let ordinary = together == nil && resumeFrom == nil && chosenAudio == nil && chosenSubtitle == nil
            && remembered == nil && !(fromBeginning && target.id == item.id)
        let prepared = ordinary ? await PlaybackPrep.shared.take(target.id, mediaSourceId: sourceId) : nil
        do {
            let fresh: BaseItem
            let resolved: PlaybackContext
            let marked: Task<[SkipSegment], Never>
            if let prepared {
                fresh = prepared.item
                // AetherEngine switches the TV itself, but for a film kept in
                // HDR, which the app asks for and the engine leaves alone.
                let source = fresh.source(prepared.context.mediaSourceId)
                switching = prepared.context.engine == .aether && !DisplayCriteria.keepsHDR(for: source)
                    ? false : DisplayCriteria.request(for: source)
                resolved = prepared.context
                marked = Task { prepared.segments }
            } else {
                // Refetch the item so the resume position is current; the one in
                // hand will do if the server is slow to say.
                let id = target.id
                fresh = await giveUp(after: 5) { try? await client.item(id: id) } ?? target
                // Alongside, since a server with nothing to say answers quickly and
                // one with nothing at all answers 404.
                // Skip buttons aren't worth holding the picture for.
                let freshId = fresh.id
                marked = Task { await giveUp(after: 4) { await client.skipSegments(for: freshId) } ?? [] }
                // Start the TV's mode switch now; it runs while the stream is
                // being resolved. For the version that will play, not whichever
                // the server lists first: a Dolby Vision remux chosen over an
                // SDR encode listed before it set the TV up for the encode.
                // Not for a film AetherEngine will play: it switches the TV
                // itself, unless the film is kept in HDR.
                let wanted = remembered.map { TrackMemory.indexes(for: $0, in: fresh.source(sourceId)?.mediaStreams ?? []) }
                let audioIndex = chosenAudio ?? wanted?.audio
                let subtitleIndex = chosenSubtitle ?? wanted?.subtitle
                let onDevice = OnDevicePlayback.wanted(fresh, source: fresh.source(sourceId), audioIndex: audioIndex,
                                                       subtitleIndex: subtitleIndex,
                                                       maxBitrate: PlaybackPreferences.maxBitrate)
                switching = onDevice && !DisplayCriteria.keepsHDR(for: fresh.source(sourceId))
                    ? false : DisplayCriteria.request(for: fresh.source(sourceId))
                // A track change resumes where it was, not where the server last
                // heard; anything else picks up the saved position.
                let start = resumeFrom ?? together ?? (fromBeginning && target.id == item.id ? 0 : fresh.resumeTicks)
                resolved = try await client.playbackContext(for: fresh, startTicks: start,
                                                            audioIndex: audioIndex,
                                                            subtitleIndex: subtitleIndex,
                                                            mediaSourceId: sourceId)
                // Left to AetherEngine, which in the end isn't playing it (the
                // server wouldn't hand the file over as it is).
                if onDevice, resolved.engine != .aether {
                    // Asked already, where it's kept in HDR: a switch under way still wants waiting for.
                    switching = DisplayCriteria.request(for: fresh.source(sourceId)) || switching
                }
            }
            // The server gets going while the rest is settled and the TV changes mode.
            let warm = Task { await client.warmUp(resolved) }
            resumeFrom = nil
            if fresh.onWatchlist { listedFilms.insert(fresh.id) }
            chapters = fresh.chapters ?? []
            // What the server marked, plus anything the chapter names give away
            // that it didn't. Merged rather than swapped: a server that reports
            // the credits and not the intro is ordinary, and reading its answer
            // as "nothing to infer" left the intro unskippable.
            // A mark over more than half of it isn't one: the server's detector
            // marks a whole two-minute short (Bluey's minisodes) as its recap,
            // and Skip Recap stayed up from start to end.
            let runtime = fresh.runTimeTicks.map { Double($0) / 10_000_000 }
            let reported = await marked.value.filter { mark in runtime.map { mark.end - mark.start <= $0 / 2 } ?? true }
            let inferred = chapters.inferredSkipSegments(
                runtimeSeconds: runtime, episode: fresh.isEpisode)
            segments = reported + inferred.filter { guess in
                !reported.contains { $0.kind == guess.kind }
            }
            await preferencesReady.value
            if switching { await DisplayCriteria.waitForSwitch() }
            await warm.value
            context = resolved
        } catch {
            // The mode was asked for before the stream was resolved; without this
            // the TV stays at the film's frame rate for a film that never plays.
            if switching { DisplayCriteria.reset() }
            errorMessage = error.localizedDescription
        }
    }

    #if !os(tvOS)
    /// A download, from the device. Online, the server says where to resume
    /// (it has heard about any other device too); offline, this device does.
    /// MP4s go to the system player; anything else, an MKV most often, to VLC,
    /// which plays any of them straight from the file.
    private func playDownloaded(_ target: BaseItem, file: URL, client: any MediaServer) async {
        let id = target.id
        let online = await giveUp(after: 3) { try? await client.item(id: id) }
        let item = online ?? Downloads.shared.item(id) ?? target
        let local = Downloads.shared.record(id)?.positionTicks ?? 0
        let together = SyncPlay.shared.position(of: id).map { Int64(($0.seconds * 10_000_000).rounded()) }
        let start = resumeFrom ?? together ?? (fromBeginning && target.id == self.item.id ? 0 : (online?.resumeTicks ?? local))
        resumeFrom = nil
        let source = item.mediaSources?.first
        let video = source?.mediaStreams?.first { $0.type == "Video" }?.codec?.lowercased() ?? ""
        // A smaller copy the server made is H.264 and AAC whatever the source was.
        let converted = Downloads.shared.quality(id) != nil
        let systemPlays = ["mp4", "mov"].contains(file.pathExtension.lowercased())
            && (converted || PlaybackPreferences.nativeVideoCodecs.contains(video))
            && !PlaybackPreferences.alwaysVLC
        let kept = Downloads.shared.subtitleURLs(id)
        let streams = converted ? Self.convertedStreams(source, subtitles: kept) : source?.mediaStreams ?? []
        chapters = item.chapters ?? []
        segments = chapters.inferredSkipSegments(runtimeSeconds: item.runTimeTicks.map { Double($0) / 10_000_000 },
                                                 episode: item.isEpisode)
        context = PlaybackContext(url: file, item: item, mediaSourceId: source?.id, playSessionId: nil,
                                  isDirect: true, startTicks: start, streamStartsAtZero: true,
                                  engine: systemPlays ? .avPlayer : .vlc,
                                  mediaStreams: streams,
                                  defaultSubtitleIndex: source?.defaultSubtitleStreamIndex)
        if converted { context?.drawableSubtitles = kept }
    }

    /// A smaller copy's tracks, as the server numbers the source's: its
    /// picture, the one sound it was made with (the source's default), and
    /// the subtitles kept beside it.
    private static func convertedStreams(_ source: MediaSource?, subtitles: [Int: URL]) -> [MediaStream] {
        let streams = source?.mediaStreams ?? []
        let audio = source?.defaultAudioStreamIndex ?? streams.first { $0.type == "Audio" }?.index
        return streams.filter { stream in
            switch stream.type {
            case "Video": stream.index == streams.first { $0.type == "Video" }?.index
            case "Audio": stream.index == audio
            case "Subtitle": stream.index.map { subtitles[$0] != nil } ?? false
            default: false
            }
        }
    }
    #endif

    private func loadPreferencesIfNeeded() async {
        if app.preferences == nil { await app.loadPreferences() }
    }

    /// The credits have started. What's next goes in the corner while the film
    /// plays on, so the choice is there before the screen goes black — and is
    /// only asked once, however many times the segment is reported.
    private func creditsReached(_ ending: BaseItem) async {
        // Set to sleep when this ends: nothing's next. Watching together,
        // the group's queue says what's next.
        guard !SleepTimer.shared.atEnd, !SyncPlay.shared.isInGroup, upNext == nil,
              let next = await following(ending) else { return }
        // Still the same episode, and its credits still being watched: skipped
        // without asking, what's next begins as this ends, with no card.
        guard upNext == nil, !creditsSkipped, context?.item.id == ending.id else { return }
        upNextOverCredits = true
        upNext = next
    }

    /// What comes after this: the queue's next item when there is a queue,
    /// which the viewer asked for and so plays whatever the auto-play setting;
    /// otherwise an episode's next episode, when the account auto-plays.
    private func following(_ ended: BaseItem) async -> BaseItem? {
        if !queue.isEmpty {
            let all = [item] + queue
            return queueIndex + 1 < all.count ? all[queueIndex + 1] : nil
        }
        guard ended.isEpisode, app.preferences?.autoPlayNextEpisode ?? true else { return nil }
        return try? await app.client?.nextEpisode(after: ended)
    }

    private func finished(_ ended: BaseItem) async {
        // The sleep timer was waiting for this: it stops here.
        if SleepTimer.shared.endsWithThis() { return close() }
        if SyncPlay.shared.isInGroup { return await finishedTogether(ended) }
        // The card counts down rather than the next episode simply beginning:
        // an episode that ends while nobody is watching should stop, and one
        // that ends while somebody is should be escapable.
        // Already offered over the credits and not taken up: the viewer has had
        // their say, so go straight on rather than asking twice.
        if let waiting = upNext, upNextOverCredits {
            play(waiting)
        } else if let next = await following(ended) {
            // The credits weren't waited for, and nor is this.
            if creditsSkipped { return play(next) }
            context = nil
            upNextOverCredits = false
            upNext = next
        } else {
            close()
        }
    }

    /// Watching together: the group's next, which the server sends every
    /// member to at once (asked by all of them, it goes on the once); with
    /// nothing next, the player closes with the group kept for what's
    /// chosen after.
    private func finishedTogether(_ ended: BaseItem) async {
        let sync = SyncPlay.shared
        if sync.hasNext {
            sync.driver?.finished()
            // Gone on to it by now, unless the server didn't answer.
            try? await Task.sleep(for: .seconds(6))
            guard (current ?? item).id == ended.id else { return }
        }
        // Nothing more: the group stops, for the server to say so to anyone
        // who joins, until something else is chosen.
        sync.ask("Stop")
        endedTogether = true
        close()
    }

    /// The group has gone on to another film: this player plays it, from
    /// where the group is in it.
    private func switchTogether(to id: String) async {
        guard id != (current ?? item).id, let next = try? await app.client?.item(id: id) else { return }
        play(next)
    }

    /// Every way out of the player. The screens behind refresh once the stop
    /// report has landed (see onDisappear), and the system player only filed
    /// it as it was torn down, after the cover's animation; by then they had
    /// already asked the server, and got the position from before.
    private func close() {
        closing = true
        if let closeStage { closeStage() } else { dismiss() }
    }

    /// Moves on to what the card offers: the next episode, or the queue's next item.
    private func play(_ next: BaseItem) {
        if !queue.isEmpty { queueIndex += 1 }
        upNext = nil
        upNextOverCredits = false
        creditsSkipped = false
        skipMemory = SkipMemory()
        context = nil
        // The next episode's tracks, chapters and segments are its own.
        chosenAudio = nil
        chosenSubtitle = nil
        resumeFrom = nil
        segments = []
        chapters = []
        current = next
    }
}

private extension BaseItem {
    /// The version with this id, or the server's first when none was chosen.
    func source(_ id: String?) -> MediaSource? {
        id.flatMap { id in mediaSources?.first { $0.id == id } } ?? mediaSources?.first
    }
}

// MARK: - AVPlayer with the app's controls

/// The system player's picture, frame-rate matching and HDR, under the app's
/// own controls: the same ones VLC plays under, with the chapters on the
/// timeline, a preview of where a scrub lands, and when the film will end,
/// none of which AVKit's own bar can show.
struct SystemPlayerView: View {
    let context: PlaybackContext
    let client: (any MediaServer)?
    let subtitles: UserPreferences?
    var segments: [SkipSegment] = []
    var chapters: [Chapter] = []
    /// The player is closing: stop and report now.
    var closing = false
    var onStalled: () -> Void = {}
    var onResumed: () -> Void = {}
    var onFailed: (String) -> Void = { _ in }
    var onCreditsReached: () -> Void = {}
    var onSelectTracks: (Int?, Int?, Int64) -> Void = { _, _, _ in }
    let onFinished: () -> Void
    let onClose: () -> Void

    @StateObject private var engine: SystemPlayback
    /// A fold across the player (an iPhone Duo half-open on its side).
    @State private var fold: TabletopFold?

    init(context: PlaybackContext, client: (any MediaServer)?, subtitles: UserPreferences?,
         segments: [SkipSegment] = [], chapters: [Chapter] = [], closing: Bool = false,
         onStalled: @escaping () -> Void = {}, onResumed: @escaping () -> Void = {},
         onFailed: @escaping (String) -> Void = { _ in },
         onCreditsReached: @escaping () -> Void = {},
         onSelectTracks: @escaping (Int?, Int?, Int64) -> Void = { _, _, _ in },
         onFinished: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.context = context
        self.client = client
        self.subtitles = subtitles
        self.segments = segments
        self.chapters = chapters
        self.closing = closing
        self.onStalled = onStalled
        self.onResumed = onResumed
        self.onFailed = onFailed
        self.onCreditsReached = onCreditsReached
        self.onSelectTracks = onSelectTracks
        self.onFinished = onFinished
        self.onClose = onClose
        _engine = StateObject(wrappedValue: SystemPlayback(item: context.item))
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            if let player = engine.avPlayer {
                PiPLayerSurface(player: player, owner: engine)
                    .ignoresSafeArea()
                    .aboveTabletopFold(fold)
            }
            #endif
            VideoPlayerController(context: context, client: client, subtitles: subtitles,
                                  engine: engine, segments: segments,
                                  onStalled: onStalled, onResumed: onResumed, onFailed: onFailed,
                                  onCreditsReached: onCreditsReached, onSelectTracks: onSelectTracks,
                                  onFinished: onFinished)
                .ignoresSafeArea()
                .aboveTabletopFold(fold)
            PlayerChrome(engine: engine, chapters: chapters, breaks: segments.filter { $0.kind == .commercial },
                         trickplay: context.trickplay, onClose: onClose)
                .belowTabletopFold(fold)
        }
        .background(Color.black)
        .readsTabletopFold($fold)
        .onChange(of: closing) { _, closing in
            if closing { engine.stop() }
        }
    }
}

/// What the controls read from the system player, and where their presses go.
/// The coordinator below keeps it up to date and does the work.
@MainActor
final class SystemPlayback: ObservableObject, PlayerEngine {
    let item: BaseItem
    private var clock = PlayerClockState()
    var position: Double { clock.seconds }
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isLoading = true
    @Published var activeSkip: SkipSegment?
    @Published var rate: Float = 1
    @Published var trackList = TrackList()
    @Published var subtitleDelay: Double?
    weak var driver: VideoPlayerController.Coordinator?
    #if os(iOS)
    /// Apple's player itself, once there is one: the picture-in-picture
    /// window is started from a layer of it (see `PiPLayerSurface`).
    @Published var avPlayer: AVPlayer?
    #endif

    init(item: BaseItem) {
        self.item = item
        if let ticks = item.runTimeTicks { duration = Double(ticks) / 10_000_000 }
    }

    func togglePause() { driver?.togglePause() }
    func seek(toFilmSeconds seconds: Double) { driver?.seek(toFilmSeconds: seconds, play: true) }
    func skip(_ seconds: Int32) { driver?.seek(toFilmSeconds: position + Double(seconds), play: false) }
    func setRate(_ rate: Float) { driver?.setRate(rate) }
    func selectAudio(_ id: String) { driver?.selectAudio(id) }
    func selectSubtitle(_ id: String) { driver?.selectSubtitle(id) }
    func selectTracks(audio: String, subtitle: String) { driver?.selectTracks(audio: audio, subtitle: subtitle) }
    func setSubtitleDelay(_ seconds: Double) { driver?.setSubtitleDelay(seconds) }
    var mediaSourceId: String? { driver?.mediaSourceId }
    var takesFoundSubtitles: Bool { driver?.takesFoundSubtitles ?? false }
    func show(_ found: FoundSubtitle) { driver?.show(found) }
    var playbackContext: PlaybackContext? { driver?.playbackContext }
    func liveStats() -> LiveStats { driver?.liveStats() ?? LiveStats() }
    /// Apple's player gives nothing to move its sound with.
    var audioDelay: Double? { nil }
    func setAudioDelay(_ seconds: Double) {}
    var audioSyncDetection: AudioSyncDetection? { nil }
    func detectAudioSync() {}
    func controlsShown(_ shown: Bool) {
        if clock.show(shown) { objectWillChange.send() }
        driver?.controlsShown(shown)
    }

    func move(to seconds: Double) {
        if clock.move(to: seconds) { objectWillChange.send() }
    }
    /// Stops and files the stop report; tearing the player down later is then a no-op.
    func stop() { driver?.stop() }
}

struct VideoPlayerController: UIViewControllerRepresentable {
    let context: PlaybackContext
    let client: (any MediaServer)?
    let subtitles: UserPreferences?
    let engine: SystemPlayback
    var segments: [SkipSegment] = []
    var onStalled: () -> Void = {}
    var onResumed: () -> Void = {}
    var onFailed: (String) -> Void = { _ in }
    /// The credits have started, which is when what's next is worth showing.
    var onCreditsReached: () -> Void = {}
    /// Chosen audio and subtitle index by the server's numbering, plus where in
    /// the film to pick up. Nil keeps the server's default;
    /// `PlaybackContext.subtitlesOff` turns subtitles off.
    var onSelectTracks: (Int?, Int?, Int64) -> Void = { _, _, _ in }
    let onFinished: () -> Void

    func makeUIViewController(context representableContext: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // Under the same name as the warm-up (see MediaBrowserClient.warmUp),
        // so the server treats its requests as the same stream.
        let asset = AVURLAsset(url: context.url,
                               options: [AVURLAssetHTTPUserAgentKey: MediaBrowserClient.streamUserAgent])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = true
        player.isMuted = DebugSound.muted
        #if os(iOS)
        PlaybackAudioSession.take()
        // On the car's screen, the film goes on as sound when the app is put
        // behind another (the car's map, say) with the phone locked.
        if PlayerStage.shared.onCarScreen {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            // A car's screen is wider than a film: filled, not barred.
            controller.videoGravity = .resizeAspectFill
        }
        #endif
        controller.player = player
        // The app draws the controls (PlayerChrome). AVKit's stay away, and
        // so does its view from focus, so every press reaches the app's.
        controller.showsPlaybackControls = false
        controller.view.isUserInteractionEnabled = false
        // The app sets the TV mode itself (DisplayCriteria); AVKit would clear it for
        // streams that don't describe their own frame rate and dynamic range.
        #if os(tvOS)
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        #endif
        #if os(iOS)
        // The small window is the app's to start (`PlayerPiP`), from a button
        // of its own and on leaving the app: AVKit's, started only by leaving,
        // would be a second one for the same film.
        controller.allowsPictureInPicturePlayback = false
        #endif

        // The title, for the now-playing screen and the iPhone remote.
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = (context.item.isEpisode
            ? "\(context.item.seriesName ?? "") · \(context.item.displayTitle)"
            : context.item.displayTitle) as NSString
        #if !os(macOS)
        player.currentItem?.externalMetadata = [titleItem]
        #endif

        let coordinator = representableContext.coordinator
        coordinator.attach(controller, engine: engine, segments: segments,
                           preferences: subtitles, onSelectTracks: onSelectTracks)
        coordinator.start(player: player)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: context, client: client, onStalled: onStalled,
                    onResumed: onResumed, onFailed: onFailed,
                    onCreditsReached: onCreditsReached, onFinished: onFinished)
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
        uiViewController.player?.pause()
        uiViewController.player = nil
        PlaybackAudioSession.release()
    }

    final class Coordinator: NSObject {
        /// Its streams, and which of them are on, are the server's numbers:
        /// changed when a subtitle is added to the film as it plays.
        private var playback: PlaybackContext
        private let client: (any MediaServer)?
        private let onStalled: () -> Void
        private let onResumed: () -> Void
        private let onFailed: (String) -> Void
        private let onCreditsReached: () -> Void
        private let onFinished: () -> Void
        private weak var player: AVPlayer?
        private weak var engine: SystemPlayback?
        private var progressTimer: Timer?
        private var watchdog: Timer?
        private var backgroundObserver: NSObjectProtocol?
        private var lastTicks: Int64 = -1
        private var stuckSince: Date?
        private var reportedStall = false
        private var endObserver: NSObjectProtocol?
        private var failureObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var timeControlObservation: NSKeyValueObservation?
        private var stopped = false
        private weak var viewController: AVPlayerViewController?
        private var segments: [SkipSegment] = []
        private var offered: SkipSegment?
        private var timeObserver: Any?
        private var subtitleObserver: Any?
        /// Keeps the reports in the order they were made.
        private let reports = PlaybackReportQueue()
        private var drawnSubtitles: DrawnSubtitles?
        /// The server's index of the subtitle being drawn.
        private var drawnIndex: Int?
        /// Seconds later (negative: earlier) to draw each line, from Timing.
        private var subtitleDelay: Double = 0
        private var onSelectTracks: (Int?, Int?, Int64) -> Void = { _, _, _ in }
        /// What a direct-played file carries inside it, for the track lists.
        private var audibleGroup: AVMediaSelectionGroup?
        private var legibleGroup: AVMediaSelectionGroup?
        /// Said once. What's next is worth showing from the credits, and the
        /// credits are wherever the server marked them — or, when it marked
        /// nothing, the last minute, which is near enough for a television.
        private var announcedCredits = false

        init(playback: PlaybackContext, client: (any MediaServer)?,
             onStalled: @escaping () -> Void, onResumed: @escaping () -> Void,
             onFailed: @escaping (String) -> Void,
             onCreditsReached: @escaping () -> Void = {},
             onFinished: @escaping () -> Void) {
            self.playback = playback
            self.client = client
            self.onStalled = onStalled
            self.onResumed = onResumed
            self.onFailed = onFailed
            self.onCreditsReached = onCreditsReached
            self.onFinished = onFinished
        }

        func attach(_ controller: AVPlayerViewController, engine: SystemPlayback, segments: [SkipSegment],
                    preferences: UserPreferences?,
                    onSelectTracks: @escaping (Int?, Int?, Int64) -> Void) {
            viewController = controller
            self.engine = engine
            MainActor.assumeIsolated { engine.driver = self }
            self.segments = segments
            self.onSelectTracks = onSelectTracks
            draw(playback.subtitleIndex)

            // AVPlayer's own tracks are only a direct-played file's. The
            // account's preference picks among its subtitles, unless the app
            // is drawing one of the files beside it instead.
            guard playback.isDirect, let playerItem = controller.player?.currentItem else { return }
            let drawing = playback.subtitleIndex != nil
            Task { @MainActor [weak self] in
                let asset = playerItem.asset
                let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
                let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
                // The audio asked for (one remembered for the show), by its
                // language; otherwise the player's own pick stands.
                if let self, let index = self.playback.audioIndex, let audible,
                   let spoken = self.playback.mediaStreams.first(where: { $0.type == "Audio" && $0.index == index })?.language,
                   let option = audible.options.first(where: { Language.same($0.extendedLanguageTag ?? $0.locale?.identifier, spoken) }) {
                    playerItem.select(option, in: audible)
                }
                if drawing {
                    if let legible { playerItem.select(nil, in: legible) }
                } else {
                    await SubtitleSelection.apply(preferences, to: playerItem)
                }
                self?.audibleGroup = audible
                self?.legibleGroup = legible
                self?.publishTracks()
            }
        }

        /// Hands the engine a change, on the main actor where it lives.
        private func publish(_ change: @escaping @MainActor (SystemPlayback) -> Void) {
            guard let engine else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { change(engine) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { change(engine) } }
            }
        }

        // MARK: Tracks

        /// Starts drawing the subtitle with this server index, or stops drawing
        /// for nil or one the app can't draw.
        private func draw(_ index: Int?) {
            drawnSubtitles?.remove()
            drawnSubtitles = nil
            drawnIndex = nil
            if let index, let url = playback.drawableSubtitles[index], let overlay = viewController?.contentOverlayView {
                drawnSubtitles = DrawnSubtitles(url: url, over: overlay)
                drawnSubtitles?.delay = subtitleDelay
                drawnSubtitles?.makeRoom(controlsUp)
                drawnIndex = index
                if let player { drawnSubtitles?.show(atFilmSeconds: filmSeconds(atPlayerTime: player.currentTime().seconds)) }
            }
            followSubtitleClock()
            publishTracks()
        }

        /// Lines are drawn on a finer clock than the rest: a tenth of a second,
        /// and only while a subtitle is being drawn. It ran for every film with
        /// a file the app could draw, subtitles on or off, ten times a second
        /// for nothing.
        private func followSubtitleClock() {
            let wanted = drawnSubtitles != nil && !stopped
            guard let player, wanted != (subtitleObserver != nil) else { return }
            if wanted {
                subtitleObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
                ) { [weak self] time in
                    guard let self else { return }
                    let seconds = CMTimeGetSeconds(time)
                    guard seconds.isFinite else { return }
                    self.drawnSubtitles?.show(atFilmSeconds: self.filmSeconds(atPlayerTime: seconds))
                }
            } else if let subtitleObserver {
                player.removeTimeObserver(subtitleObserver)
                self.subtitleObserver = nil
            }
        }

        /// The track lists, by id: "s" and the server's index for a track the
        /// server numbers, "m" and a position for one inside a direct-played
        /// file, which AVPlayer switches itself.
        ///
        /// A transcode carries one audio track and no subtitles, so everything
        /// on it comes from the server's list. A direct-played file offers what
        /// is inside it, plus the subtitle files beside it, which are drawn.
        private func publishTracks() {
            let streams = playback.mediaStreams
            var list = TrackList()
            let off = PlayerTrack(id: TrackList.subtitlesOff, name: String(localized: "Off", comment: "Subtitles turned off"))
            if playback.isDirect {
                let selection = player?.currentItem?.currentMediaSelection
                // The file's own tracks, in its order, as the server numbers them.
                func inside(_ kind: String) -> [Int] {
                    streams.filter { $0.type == kind && $0.isExternal != true }.compactMap(\.index).sorted()
                }
                if let audible = audibleGroup {
                    let numbers = inside("Audio")
                    list.audio = audible.options.enumerated().map {
                        PlayerTrack(id: "m\($0.offset)", name: $0.element.displayName,
                                    serverIndex: numbers.indices.contains($0.offset) ? numbers[$0.offset] : nil)
                    }
                    if let chosen = selection?.selectedMediaOption(in: audible),
                       let at = audible.options.firstIndex(of: chosen) { list.currentAudio = "m\(at)" }
                }
                // AVFoundation lists a "Forced" option after each subtitle,
                // its forced lines only, which the server doesn't count.
                let numbers = inside("Subtitle")
                var counted = 0
                let inside = legibleGroup?.options.enumerated().map { offset, option -> PlayerTrack in
                    var number: Int?
                    if !option.hasMediaCharacteristic(.containsOnlyForcedSubtitles), option.mediaType != .closedCaption,
                       numbers.indices.contains(counted) {
                        number = numbers[counted]
                        counted += 1
                    }
                    return PlayerTrack(id: "m\(offset)", name: option.displayName, serverIndex: number)
                } ?? []
                let files = streams.filter { $0.type == "Subtitle" && playback.drawableSubtitles[$0.index ?? -1] != nil }
                    .map { PlayerTrack(id: "s\($0.index ?? -1)", name: $0.trackName) }
                list.subtitles = [off] + inside + files
                if let drawnIndex {
                    list.currentSubtitle = "s\(drawnIndex)"
                } else if let legible = legibleGroup, let chosen = selection?.selectedMediaOption(in: legible),
                          let at = legible.options.firstIndex(of: chosen) {
                    list.currentSubtitle = "m\(at)"
                } else {
                    list.currentSubtitle = TrackList.subtitlesOff
                }
            } else {
                list.audio = streams.filter { $0.type == "Audio" }.map { PlayerTrack(id: "s\($0.index ?? -1)", name: $0.trackName) }
                list.currentAudio = playback.audioIndex.map { "s\($0)" }
                list.subtitles = [off] + streams.filter { $0.type == "Subtitle" }
                    .map { PlayerTrack(id: "s\($0.index ?? -1)", name: $0.trackName) }
                list.currentSubtitle = (drawnIndex ?? burntInSubtitle).map { "s\($0)" } ?? TrackList.subtitlesOff
            }
            let delay: Double? = drawnIndex == nil ? nil : subtitleDelay
            publish { [weak self] engine in
                engine.trackList = list
                engine.subtitleDelay = delay
                // Another track on: told now, for a remote showing it.
                if let self, self.reportedPaused != nil, self.reportedTracks != [list.currentAudio, list.currentSubtitle] {
                    self.reportProgress()
                }
            }
        }

        func selectAudio(_ id: String) {
            if id.hasPrefix("m"), let at = Int(id.dropFirst()), let group = audibleGroup,
               group.options.indices.contains(at) {
                player?.currentItem?.select(group.options[at], in: group)
                publishTracks()
            } else if id.hasPrefix("s"), let index = Int(id.dropFirst()) {
                chooseAudio(index)
            }
        }

        /// Audio and subtitle together. Another audio track in a transcode is
        /// another stream: asked for once, with the subtitle in it, rather
        /// than the subtitle being lost to the stream the audio brings.
        func selectTracks(audio: String, subtitle: String) {
            if audio.hasPrefix("s"), let index = Int(audio.dropFirst()), index != playback.audioIndex {
                let wanted = subtitle == TrackList.subtitlesOff ? PlaybackContext.subtitlesOff
                    : subtitle.hasPrefix("s") ? Int(subtitle.dropFirst()) : drawnIndex ?? burntInSubtitle ?? PlaybackContext.subtitlesOff
                onSelectTracks(index, wanted, currentTicks())
                return
            }
            selectAudio(audio)
            selectSubtitle(subtitle)
        }

        func selectSubtitle(_ id: String) {
            if id == TrackList.subtitlesOff {
                if let legible = legibleGroup { player?.currentItem?.select(nil, in: legible) }
                chooseSubtitle(nil)
            } else if id.hasPrefix("m"), let at = Int(id.dropFirst()), let group = legibleGroup,
                      group.options.indices.contains(at) {
                // One inside the file replaces a drawn one.
                draw(nil)
                player?.currentItem?.select(group.options[at], in: group)
                publishTracks()
            } else if id.hasPrefix("s"), let index = Int(id.dropFirst()) {
                chooseSubtitle(index)
            }
        }

        /// A subtitle the server has just been given: drawn, as the files
        /// beside a film are. The server numbers such a file ahead of the
        /// streams inside the film, so everything known by number is looked
        /// up again first: the lists, the sound a transcode carries, the
        /// subtitle on show.
        func show(_ found: FoundSubtitle) {
            let moved = found.streams.renumbering(of: playback.mediaStreams)
            let direct = playback.isDirect
            playback.mediaStreams = found.streams
            // A direct-played file shows its own subtitles itself; only the
            // files beside it are drawn.
            playback.drawableSubtitles = found.drawable.filter { index, _ in
                !direct || found.streams.contains { $0.index == index && $0.isExternal == true }
            }
            playback.audioIndex = playback.audioIndex.map { moved[$0] ?? $0 }
            if let on = playback.subtitleIndex, on != PlaybackContext.subtitlesOff {
                playback.subtitleIndex = moved[on] ?? on
            }
            if direct, let legible = legibleGroup { player?.currentItem?.select(nil, in: legible) }
            draw(found.index)
        }

        var mediaSourceId: String? { playback.mediaSourceId }
        var takesFoundSubtitles: Bool { !playback.url.isFileURL }
        var playbackContext: PlaybackContext { playback }

        /// From AVPlayer's own log of the stream, summed where it starts a
        /// new entry (it does at every change of variant), and from how far
        /// ahead of the picture it has loaded.
        func liveStats() -> LiveStats {
            var stats = LiveStats()
            guard let item = player?.currentItem else { return stats }
            if let events = item.accessLog()?.events, let last = events.last {
                if last.indicatedBitrate > 0 { stats.bitrate = last.indicatedBitrate }
                if last.observedBitrate > 0 { stats.throughput = last.observedBitrate }
                stats.droppedFrames = events.reduce(0) { $0 + max($1.numberOfDroppedVideoFrames, 0) }
                stats.stalls = events.reduce(0) { $0 + max($1.numberOfStalls, 0) }
            }
            let now = item.currentTime()
            if let ahead = item.loadedTimeRanges.map(\.timeRangeValue).first(where: { $0.containsTime(now) }) {
                stats.buffered = max(ahead.end.seconds - now.seconds, 0)
            }
            if item.presentationSize.width > 0 { stats.size = item.presentationSize }
            return stats
        }

        /// A picture subtitle burnt into a transcode, which only happens to a
        /// film too big for VLC to be given instead.
        private var burntInSubtitle: Int? {
            guard !playback.isDirect, let index = playback.subtitleIndex,
                  playback.mediaStreams.contains(where: { $0.index == index && $0.isEmbeddedPictureSubtitle }) else { return nil }
            return index
        }

        private var controlsUp = false

        /// Drawn subtitles sit above the controls while they're up.
        func controlsShown(_ shown: Bool) {
            controlsUp = shown
            drawnSubtitles?.makeRoom(shown)
        }

        /// Moves every line of a drawn subtitle earlier or later, for one timed
        /// to a different cut of the film. Kept for this film only.
        func setSubtitleDelay(_ step: Double) {
            subtitleDelay = step
            drawnSubtitles?.delay = step
            if let player { drawnSubtitles?.show(atFilmSeconds: filmSeconds(atPlayerTime: player.currentTime().seconds)) }
            publishTracks()
        }

        /// A subtitle the app draws switches on the spot. Anything else is a
        /// different stream: a picture subtitle means VLC, and turning off one
        /// burnt into a transcode means asking again without it.
        private func chooseSubtitle(_ index: Int?) {
            if index.map({ playback.drawableSubtitles[$0] != nil }) ?? true, burntInSubtitle == nil {
                draw(index)
                if playback.isDirect, index != nil, let legible = legibleGroup {
                    // A file beside the film replaces any inside it.
                    player?.currentItem?.select(nil, in: legible)
                    publishTracks()
                }
                return
            }
            onSelectTracks(playback.audioIndex, index ?? PlaybackContext.subtitlesOff, currentTicks())
        }

        /// A transcode carries one audio track, so another means asking again,
        /// keeping whatever subtitle is on.
        private func chooseAudio(_ index: Int?) {
            guard index != playback.audioIndex else { return }
            onSelectTracks(index, drawnIndex ?? burntInSubtitle ?? PlaybackContext.subtitlesOff, currentTicks())
        }

        // MARK: Transport

        func togglePause() {
            guard let player else { return }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }

        /// Speeds are the player's default rate, which play() goes back to.
        func setRate(_ rate: Float) {
            guard let player else { return }
            player.defaultRate = rate
            if player.timeControlStatus != .paused { player.rate = rate }
            publish { $0.rate = rate }
        }

        /// Where the film has got to, from the player's clock: a transcode the
        /// server started at an offset counts from there.
        private func filmSeconds(atPlayerTime seconds: Double) -> Double {
            let offset = playback.streamStartsAtZero ? 0 : Double(playback.startTicks) / 10_000_000
            return offset + seconds
        }

        private func tick(atPlayerTime seconds: Double) {
            guard seconds.isFinite else { return }
            // The segments the server marked are in the film's own time.
            let film = filmSeconds(atPlayerTime: seconds)

            // Nothing marked the credits, so take the last minute as them. An
            // episode has to be long enough for that to mean anything.
            if !announcedCredits, segments.allSatisfy({ $0.kind != .outro }),
               let runtime = playback.item.runTimeTicks.map({ Double($0) / 10_000_000 }),
               runtime > 180, film >= runtime - 20 {
                announcedCredits = true
                onCreditsReached()
            }

            guard !segments.isEmpty else { return }
            let current = segments.first { $0.contains(film) }
            guard current != offered else { return }   // nothing changed
            offered = current
            publish { $0.activeSkip = current }
            if current?.kind == .outro, !announcedCredits {
                announcedCredits = true
                onCreditsReached()
            }
        }

        func start(player: AVPlayer) {
            self.player = player
            #if os(iOS)
            MainActor.assumeIsolated { engine?.avPlayer = player }
            #endif

            // A stream that begins at the top of the film is seeked into here.
            // (A transcode the server started at an offset is already there.)
            // Play waits for the seek to land. Started together, playback began
            // at the top and the seek arrived under it, and with the sound going
            // to a HomePod the Apple TV kept the delay it had worked out for the
            // start: a resumed film played with its sound late, one started from
            // the top didn't. Exact, too, so it starts on the frame it was left.
            if playback.streamStartsAtZero, playback.startTicks > 0 {
                let seconds = Double(playback.startTicks) / 10_000_000
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                    DispatchQueue.main.async { player?.play() }
                }
            } else {
                player.play()
            }
            let startSeconds = Double(playback.startTicks) / 10_000_000
            publish { $0.move(to: startSeconds) }

            let (client, playback) = (client, playback)
            reports.send { await client?.reportStart(playback) }
            reportedPaused = false

            progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.reportProgress()
            }

            // Twice a second moves the timeline smoothly, and is plenty for
            // offering a skip and noticing the end coming. An observer rather
            // than a timer, so it stops when the player does.
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                let film = filmSeconds(atPlayerTime: seconds)
                publish { $0.move(to: film) }
                tick(atPlayerTime: seconds)
            }
            timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                self?.publish { engine in
                    engine.isPlaying = status != .paused
                    engine.isLoading = status == .waitingToPlayAtSpecifiedRate
                }
                // Paused or playing again: told now rather than at the next
                // report, for a remote showing it.
                guard status != .waitingToPlayAtSpecifiedRate else { return }
                DispatchQueue.main.async { self?.reportIfPausedChanged(status == .paused) }
            }
            // A subtitle chosen before the player existed is drawn from here.
            followSubtitleClock()

            // A file whose audio or video simply runs out leaves AVPlayer waiting
            // forever with no error; say so instead of sitting on a frozen frame.
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkForStall()
            }

            // A stream that fails — a 404, a transcode the server gave up on, a
            // server that went away — leaves AVPlayer paused with no error of its
            // own to show. Without these the picture simply stays black.
            statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
                guard playerItem.status == .failed else { return }
                self?.failed(with: playerItem.error)
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] note in
                self?.failed(with: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            }

            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reportProgress()
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.stop(markFinished: true)
                self?.onFinished()
            }
        }

        /// Stops, files where it got to, and tells the screen what went wrong.
        private func failed(with error: Error?) {
            guard !stopped else { return }
            let reason = error?.localizedDescription
                ?? String(localized: "The server stopped sending this stream.")
            stop()
            onFailed(reason)
        }

        /// Playing, but the clock hasn't moved for 15s? Then it isn't going to.
        private func checkForStall() {
            guard let player, !stopped else { return }
            let ticks = currentTicks()
            let wantsToPlay = player.timeControlStatus != .paused
            if ticks != lastTicks {
                lastTicks = ticks
                stuckSince = nil
                if reportedStall {
                    reportedStall = false
                    onResumed()
                }
                return
            }
            if player.currentItem?.status == .failed {
                failed(with: player.currentItem?.error)
                return
            }
            // The viewer pressed pause. The count starts again on resuming:
            // carried over, a stall that began before the pause was reported
            // on the first check after it.
            guard wantsToPlay else { stuckSince = nil; return }
            let since = stuckSince ?? Date()
            stuckSince = since
            if !reportedStall, Date().timeIntervalSince(since) >= 15 {
                reportedStall = true
                onStalled()
            }
        }

        /// Jumps to a point in the film, undoing the offset a transcode the
        /// server started partway in counts from, and plays on if asked to.
        func seek(toFilmSeconds seconds: Double, play: Bool = false) {
            let offset = playback.streamStartsAtZero ? 0 : Double(playback.startTicks) / 10_000_000
            let runtime = playback.item.runTimeTicks.map { Double($0) / 10_000_000 } ?? .infinity
            let film = min(max(seconds, offset), runtime - 1)
            player?.seek(to: CMTime(seconds: max(film - offset, 0), preferredTimescale: 600)) { [weak self] done in
                // Where it landed, for a remote following it.
                if done { DispatchQueue.main.async { self?.reportProgress() } }
            }
            publish { $0.move(to: film); $0.activeSkip = nil }
            offered = nil
            if play { player?.play() }
        }

        func currentTicks() -> Int64 {
            guard let player else { return playback.startTicks }
            let seconds = player.currentTime().seconds
            guard seconds.isFinite, seconds > 0 else { return playback.startTicks }
            var ticks = Int64(seconds * 10_000_000)
            // A transcode the server started at an offset counts from there.
            if !playback.streamStartsAtZero { ticks += playback.startTicks }
            return ticks
        }

        /// Called on the main thread.
        private func reportProgress() {
            guard let player, !stopped else { return }
            let paused = player.timeControlStatus != .playing
            reportedPaused = paused
            let tracks = MainActor.assumeIsolated { engine?.trackList } ?? TrackList()
            reportedTracks = [tracks.currentAudio, tracks.currentSubtitle]
            let audio = playback.serverIndex(forTrackId: tracks.currentAudio, in: tracks.audio, kind: "Audio")
            let subtitle = playback.serverIndex(forTrackId: tracks.currentSubtitle, in: tracks.subtitles, kind: "Subtitle")
            let (client, playback, ticks) = (client, playback, currentTicks())
            reports.send {
                await client?.reportProgress(playback, positionTicks: ticks, paused: paused, audioIndex: audio, subtitleIndex: subtitle)
            }
        }

        /// What the server was last told of pausing, once it's been told the
        /// film has started.
        private var reportedPaused: Bool?
        /// And of the tracks on.
        private var reportedTracks: [String?] = []

        private func reportIfPausedChanged(_ paused: Bool) {
            guard let reportedPaused, reportedPaused != paused else { return }
            reportProgress()
        }

        func stop(markFinished: Bool = false) {
            guard !stopped else { return }
            stopped = true
            progressTimer?.invalidate()
            watchdog?.invalidate()
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            drawnSubtitles?.remove()
            drawnSubtitles = nil
            followSubtitleClock()
            let ticks = markFinished ? (playback.item.runTimeTicks ?? currentTicks()) : currentTicks()
            let (client, playback) = (client, playback)
            PlaybackReports.shared.track(reports.send { _ = await client?.reportStopped(playback, positionTicks: ticks) })
        }
    }
}

// MARK: - Sound

/// The app's hold on the sound while a film plays.
enum PlaybackAudioSession {
    /// On the iPhone and iPad the session is set off the main thread, in
    /// order: a player closing and the next episode's opening hand it over in
    /// turn.
    private static let queue = DispatchQueue(label: "PlaybackAudioSession", qos: .userInitiated)

    /// Sound with the silent switch on, as for any film. The Apple TV's
    /// default already plays; it's set there too, where VLC needs it.
    static func take() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        #endif
        #if os(iOS)
        queue.async { try? session.setActive(true) }
        #elseif os(tvOS)
        try? session.setActive(true)
        #endif
    }

    /// How much a VLC player has to keep in hand, in milliseconds, for the
    /// sound to come out on time where it's going: what it would keep
    /// anyway, or the delay the way out owns to and a second over, whichever
    /// is the more.
    ///
    /// The player hands sound over that delay ahead of when it's to be
    /// heard, and can't hand over what it hasn't got yet. A HomePod owns to
    /// two seconds; a player with a second and a half in hand played the
    /// picture on time and the sound as soon as it could, which was late,
    /// while a headset that owns to a sixth of a second was in step.
    static func inHand(atLeast usual: Int) -> Int {
        #if os(macOS)
        var delay = 0.0
        #else
        var delay = AVAudioSession.sharedInstance().outputLatency
        #endif
        // For trying it where no such loudspeaker is to be had.
        let pretended = UserDefaults.standard.double(forKey: "goosetv.sound.latencyTest")
        if pretended > 0 { delay = pretended }
        guard delay.isFinite, delay > 0 else { return usual }
        return min(max(usual, Int((delay + 1) * 1000)), 8000)
    }

    /// Hands the sound back once the film has stopped, so music it
    /// interrupted carries on. iPhone and iPad only: the Apple TV's is left
    /// as it was.
    static func release() {
        #if os(iOS)
        queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }
}

// MARK: - Subtitle selection

/// Applies the account's subtitle preference to the tracks AVPlayer can see:
/// those inside a direct-played file, or the one a transcode carries.
enum SubtitleSelection {
    @MainActor
    static func apply(_ preferences: UserPreferences?, to item: AVPlayerItem) async {
        guard let preferences, preferences.subtitleMode != .default,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        let wanted = SubtitleLanguage.shortCode(for: preferences.subtitleLanguage) ?? ""
        let forced = group.options.filter { $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let full = group.options.filter {
            !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                && (wanted.isEmpty || language(of: $0) == wanted)
        }

        let choice: AVMediaSelectionOption?
        switch preferences.subtitleMode {
        case .none:
            choice = nil
        case .always:
            choice = full.first
        case .onlyForced:
            choice = forced.first
        case .smart:
            // Full subtitles only when the audio isn't already in the wanted language.
            let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            let spoken = audio.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }.flatMap(language(of:))
            choice = (!wanted.isEmpty && spoken != nil && spoken != wanted) ? full.first : forced.first
        case .default:
            return
        }
        item.select(choice, in: group)
    }

    private static func language(of option: AVMediaSelectionOption) -> String? {
        option.locale?.language.languageCode?.identifier
    }
}

// MARK: - Loading, errors, and stalls

/// The screen between pressing Play and the picture arriving, and where playback
/// problems are explained: the item's own backdrop, dimmed, under a glass panel.
struct PlayerNotice: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    var icon: String? = nil
    let title: String
    let message: String
    var tint: Color = Theme.primary.1
    let onClose: () -> Void

    var body: some View {
        PanelBackdrop(onTapOutside: onClose) {
            VStack(spacing: 18) {
                if let icon {
                    Image(systemName: icon)
                        .font(.app(44, .bold))
                        .foregroundStyle(tint)
                } else {
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(.white)
                }
                if let label = item.episodeLabel {
                    Text("\(item.seriesName ?? "") · \(label)".uppercased())
                        .font(.app(13, .heavy))
                        .kerning(1.6)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.app(30, .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.app(18))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: CGFloat(680).scaled)
        }
        .background {
            // The item's own backdrop behind it all, well out of focus.
            RemoteImage(url: app?.client?.imageURL(for: item, type: "Backdrop", maxWidth: 960))
                .blur(radius: 40)
                .ignoresSafeArea()
        }
        // Nothing else here takes focus, and without focus back goes unheard.
        .focusable()
        .tvExitCommand(perform: onClose)
    }
}

/// Shown over the player when the picture has stopped moving for long enough
/// that it won't recover on its own (a truncated audio track, a dead stream).
/// Both players' own.
struct StalledNotice: View {
    let item: BaseItem
    let onClose: () -> Void

    var body: some View {
        PlayerNotice(item: item,
                     icon: "exclamationmark.triangle.fill",
                     title: String(localized: "Playback stalled"),
                     message: String(localized: "Nothing has arrived for a while. This file may be damaged, or the server may have stopped sending. Press back to leave."),
                     tint: Theme.palette[1].1,
                     onClose: onClose)
    }
}

// MARK: - Up next

/// Between one episode and the next: what's coming, how long until it starts,
/// and a way out.
///
/// The episode used to simply begin, which is right when somebody is watching
/// and wrong when the television has been left on. A countdown answers both —
/// carry on doing nothing and it plays, press back and the evening ends.
private struct UpNextCard: View {
    @Environment(\.appState) private var app
    let next: BaseItem
    /// Riding over the credits with the film still playing, rather than
    /// standing in for an episode that has ended.
    var compact = false
    let onPlay: () -> Void
    let onStop: () -> Void

    /// Long enough to read the title and reach for the remote, short enough
    /// not to feel like being asked permission. The card over the credits is
    /// the quicker: the episode is over, and the credits aren't the show.
    private var total: Double { compact ? 10 : 12 }

    /// Flipped once, on appearing. The bar is animated from it rather than
    /// driven by a ticking number: a quarter-second countdown in state redrew
    /// the whole card — blurred backdrop, material and all — four times a
    /// second, which on a television reads as a flicker.
    @State private var running = false
    @FocusState private var playFocused: Bool

    private var stillWidth: CGFloat { CGFloat(compact ? 210 : 320).scaled }

    var body: some View {
        Group {
            if compact { card } else { PanelBackdrop(onTapOutside: onStop) { card } }
        }
        .background {
            if !compact {
                RemoteImage(url: app?.client?.imageURL(for: next, type: "Backdrop", maxWidth: 960))
                    .blur(radius: 40)
                    .ignoresSafeArea()
            }
        }
        .tvExitCommand(perform: onStop)
        .task {
            playFocused = true
            withAnimation(.linear(duration: total)) { running = true }
            try? await Task.sleep(for: .seconds(total))
            if !Task.isCancelled { onPlay() }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: compact ? 20 : 28) {
            // A fixed 16:9 box, filled and clipped, so the still sits inside the
            // card instead of setting the card's height from its own.
            RemoteImage(url: app?.client?.imageURL(for: next, type: "Primary", maxWidth: 800))
                .frame(width: stillWidth, height: stillWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                Text("UP NEXT")
                    .font(.app(compact ? 11 : 13, .heavy))
                    .kerning(1.8)
                    .foregroundStyle(Theme.accent)

                if let label = next.episodeLabel {
                    Text("\(next.seriesName ?? "") · \(label)".uppercased())
                        .font(.app(compact ? 12 : 14, .heavy))
                        .kerning(1.2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Text(next.displayTitle)
                    .font(.app(compact ? 22 : 28, .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !compact, let overview = next.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.app(17))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The bar is the countdown: a number ticking down reads as a
                // deadline, a bar filling reads as something about to happen.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * (running ? 1 : 0))
                    }
                }
                .frame(height: 5)
                .padding(.top, 2)

                HStack(spacing: 12) {
                    Button("Play Now") { onPlay() }
                        .buttonStyle(.pill(selected: true))
                        .focused($playFocused)
                    Button(compact ? String(localized: "Not Now") : String(localized: "Stop")) { onStop() }
                        .buttonStyle(.pill(selected: false))
                }
                .padding(.top, 4)
            }
            .frame(width: CGFloat(compact ? 340 : 470).scaled, alignment: .leading)
        }
        .padding(compact ? 22 : 0)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.72))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
        }
        .tvFocusSection()
    }
}
