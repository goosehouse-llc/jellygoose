import SwiftUI
import Combine
import MediaPlayer
import AetherEngine

/// Plays the original file through AetherEngine, which reads it on the device
/// and hands Apple's own player what it can play: an MKV starts at once,
/// without the server converting it first, and Dolby Vision, Atmos and the
/// TV's mode switch stay Apple's. The app's controls go over it as over the
/// other two players. See OnDevicePlayback for which films come here.
struct AetherPlayerView: View {
    let onClose: () -> Void
    private let chapters: [Chapter]
    private let breaks: [SkipSegment]
    private let trickplay: Trickplay?

    @StateObject private var playback: AetherPlayback
    /// A fold across the player (an iPhone Duo half-open on its side).
    @State private var fold: TabletopFold?

    init(context: PlaybackContext, client: (any MediaServer)?, segments: [SkipSegment] = [],
         chapters: [Chapter] = [],
         onCreditsReached: @escaping () -> Void = {},
         onRefused: @escaping (Int64) -> Void,
         onFinished: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.chapters = chapters
        self.breaks = segments.filter { $0.kind == .commercial }
        self.trickplay = context.trickplay
        _playback = StateObject(wrappedValue: AetherPlayback(context: context, client: client, segments: segments,
                                                             onCreditsReached: onCreditsReached,
                                                             onRefused: onRefused, onFinished: onFinished))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let engine = playback.engine {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
                    .aboveTabletopFold(fold)
                AetherSubtitles(lines: playback.lines)
                    .ignoresSafeArea()
                    .aboveTabletopFold(fold)
            }

            if playback.stalled {
                StalledNotice(item: playback.item) { playback.stop(); onClose() }
            } else {
                PlayerChrome(engine: playback, chapters: chapters, breaks: breaks, trickplay: trickplay) {
                    playback.stop()
                    onClose()
                }
                .belowTabletopFold(fold)
            }
        }
        .background(Color.black)
        .readsTabletopFold($fold)
        .task { await playback.start() }
        .onDisappear { playback.stop() }
    }
}

// MARK: - Subtitles

/// The subtitle on screen now, drawn over the picture as the app draws the
/// other players' (see DrawnSubtitles): its size, its shadows, and clear of
/// the controls while they're up. Watched on its own, so a line coming and
/// going redraws this and nothing else.
private struct AetherSubtitles: View {
    @ObservedObject var lines: AetherLines

    var body: some View {
        GeometryReader { screen in
            ZStack(alignment: .bottom) {
                ForEach(lines.images, id: \.id) { cue in
                    if case .image(let image) = cue.body {
                        placed(image, on: screen.size)
                    }
                }
                if !lines.text.isEmpty {
                    // The plate reaches a little below the words; they sit
                    // where Settings puts them with or without it.
                    SubtitleLine(text: lines.text)
                        .frame(maxWidth: screen.size.width * 0.8)
                        .padding(.bottom, SubtitleAppearance.place.rise(onScreen: min(screen.size.width, screen.size.height),
                                                                        controlsUp: lines.raised) - SubtitleLine.inset.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .animation(.easeOut(duration: 0.25), value: lines.raised)
        }
        .allowsHitTesting(false)
    }

    /// A picture subtitle (Blu-ray, DVD) where the disc put it. Its rectangle
    /// is a fraction of the disc's canvas, and the canvas sits on the picture
    /// as wide as it and centred on it (a rip cropped to the film can have a
    /// canvas taller than its picture, with the subtitles in the bar below).
    private func placed(_ image: SubtitleImage, on screen: CGSize) -> some View {
        let picture = lines.pictureRect(on: screen)
        let canvas = image.canvasSize.width > 0 && image.canvasSize.height > 0
            ? CGSize(width: picture.width, height: picture.width * image.canvasSize.height / image.canvasSize.width)
            : picture.size
        let origin = CGPoint(x: picture.midX - canvas.width / 2, y: picture.midY - canvas.height / 2)
        let rect = image.position
        return Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .frame(width: rect.width * canvas.width, height: rect.height * canvas.height)
            .position(x: origin.x + rect.midX * canvas.width, y: origin.y + rect.midY * canvas.height)
            // Clear of the controls only if it's down where they are: one the
            // disc put at the top, above a caption, would go off the screen.
            .offset(y: lines.raised && rect.midY > 0.5 ? -170 : 0)
    }
}

/// Which of the engine's cues cover the frame on screen, shifted by the
/// viewer's timing.
@MainActor
final class AetherLines: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var images: [SubtitleCue] = []
    @Published var raised = false
    /// Seconds later (negative: earlier) to show each line.
    var delay: Double = 0
    /// The film's picture as shown, width over height; nil until known.
    var aspect: CGFloat?

    /// Where the picture sits on the screen, fitted as the player fits it.
    func pictureRect(on screen: CGSize) -> CGRect {
        guard let aspect, aspect > 0 else { return CGRect(origin: .zero, size: screen) }
        let size = screen.width / screen.height > aspect
            ? CGSize(width: screen.height * aspect, height: screen.height)
            : CGSize(width: screen.width, height: screen.width / aspect)
        return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
    private var ids: [Int] = []

    func show(_ cues: [SubtitleCue], at seconds: Double) {
        let time = seconds - delay
        let now = cues.filter { $0.startTime <= time && time < $0.endTime }
        let nowIDs = now.map(\.id)
        // Only on a change: the clock moves ten times a second.
        guard nowIDs != ids else { return }
        ids = nowIDs
        text = now.compactMap { cue -> String? in
            switch cue.body {
            case .text(let line): line
            case .richText(let runs): runs.map(\.text).joined()
            default: nil
            }
        }.joined(separator: "\n")
        images = now.filter { if case .image = $0.body { true } else { false } }
    }
}

// MARK: - Playback

/// Owns the engine for one film: starts it at the resume point, turns its
/// state into what the controls read, and reports to the server as the other
/// two players do.
@MainActor
final class AetherPlayback: ObservableObject, PlayerEngine {
    private(set) var engine: AetherEngine?
    let item: BaseItem
    let lines = AetherLines()

    /// Seconds into the film; see PlayerClockState for why it isn't published.
    private var clock = PlayerClockState()
    var position: Double { clock.seconds }
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = true
    @Published private(set) var stalled = false
    @Published private(set) var activeSkip: SkipSegment?
    @Published private(set) var rate: Float = 1
    @Published private(set) var trackList = TrackList()
    @Published private(set) var subtitleDelay: Double?
    @Published private(set) var audioDelay: Double?
    @Published private(set) var audioSyncDetection: AudioSyncDetection?
    private var detector = AudioSyncDetector()
    private var detecting: Task<Void, Never>?
    /// What the sound was set to before it was taken off to be listened to,
    /// to put back if listening settles nothing.
    private var offsetBeforeDetecting: Double?
    /// The subtitle asked for, by the engine's number. The engine lets go of
    /// its subtitle while it builds a session again (the sound moved, a
    /// track changed) and takes it back after; off is what the viewer chose,
    /// not what the engine says in between.
    private var wantedSubtitle: Int?

    private let segments: [SkipSegment]
    private let context: PlaybackContext
    private let client: (any MediaServer)?
    private let onCreditsReached: () -> Void
    private let onRefused: (Int64) -> Void
    private let onFinished: () -> Void
    private let reports = PlaybackReportQueue()
    private var watching: Set<AnyCancellable> = []
    private var progressTimer: Timer?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var started = false
    private var reportedStart = false
    private var stopped = false
    private var reachedCredits = false
    private var stalledSince: Date?
    /// Subtitle files beside the film: the engine's number for each, and the
    /// server's.
    private var fileSubtitles: [Int: Int] = [:]
    /// The film's streams as the server numbers them, which is not as the
    /// engine does: it counts the streams inside the file from nought, and
    /// the server counts the subtitle files beside the film first. One file
    /// beside it and every name in the menus was the stream before's, and
    /// the sound asked for was the next one along.
    private var streams: [MediaStream]

    init(context: PlaybackContext, client: (any MediaServer)?, segments: [SkipSegment],
         onCreditsReached: @escaping () -> Void, onRefused: @escaping (Int64) -> Void,
         onFinished: @escaping () -> Void) {
        self.context = context
        streams = context.mediaStreams
        self.client = client
        self.segments = segments
        self.onCreditsReached = onCreditsReached
        self.onRefused = onRefused
        self.onFinished = onFinished
        item = context.item
        audioDelay = AudioSync.offset(for: context.item.id)
        engine = try? AetherEngine()
        #if os(iOS)
        // A car's screen is wider than a film: filled, not barred.
        if PlayerStage.shared.onCarScreen { engine?.videoGravity = .resizeAspectFill }
        #endif
        if let ticks = context.item.runTimeTicks { duration = Double(ticks) / 10_000_000 }
    }

    func start() async {
        guard !started else { return }
        started = true
        guard let engine else { return refuse() }
        // The engine sets the TV's mode itself, so what the app last asked for
        // no longer says what the TV is in. Not for a film kept in HDR: the
        // app has asked for that, and the engine is told to leave it be.
        let keepsHDR = DisplayCriteria.keepsHDR(streams.first { $0.type == "Video" })
        if !keepsHDR { DisplayCriteria.forget() }
        watch(engine)
        var options = LoadOptions()
        options.suppressDisplayCriteria = keepsHDR
        // TrueHD and DTS as lossless 7.1, as the server's conversion gives them.
        options.audioBridgeMode = .lossless
        // What was set for this title the last time it was played.
        options.audioDelaySeconds = audioDelay ?? 0
        let start = Double(context.startTicks) / 10_000_000
        do {
            try await engine.load(url: context.url, startPosition: start > 0 ? start : nil,
                                  options: options,
                                  audioSourceStreamIndex: context.audioIndex
                                      .flatMap { streams.fileStream(forServerIndex: $0) }.map { Int32($0) })
        } catch is CancellationError {
            return
        } catch {
            return refuse()
        }
        guard !stopped else { return }
        if engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            lines.aspect = CGFloat(Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio)
                / CGFloat(engine.sourceVideoHeight)
        }
        addSubtitleFiles(to: engine)
        selectOpeningSubtitle(engine)
        reportedStart = true
        let (client, context) = (client, context)
        reports.send { await client?.reportStart(context) }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reportProgress()
                self?.publishNowPlaying()
            }
        }
        becomeNowPlaying()
    }

    /// The engine couldn't play it: handed back to be played the usual way,
    /// from where it got to.
    private func refuse() {
        let ticks = currentTicks
        stop()
        onRefused(ticks)
    }

    private func watch(_ engine: AetherEngine) {
        engine.clock.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in self?.moved(to: seconds) }
            .store(in: &watching)
        engine.clock.$sourceTime
            .combineLatest(engine.$subtitleCues)
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds, cues in self?.lines.show(cues, at: seconds) }
            .store(in: &watching)
        // Every subtitle's times, for working the sound's place out from them.
        engine.$subtitleCues
            .receive(on: RunLoop.main)
            .sink { [weak self] cues in
                self?.detector.note(cues: cues.map { (start: $0.startTime, end: $0.endTime) })
            }
            .store(in: &watching)
        engine.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self, seconds > 0, seconds != duration else { return }
                duration = seconds
            }
            .store(in: &watching)
        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &watching)
        engine.$playbackPhase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &watching)
        engine.$audioTracks.combineLatest(engine.$activeAudioTrackIndex, engine.$subtitleTracks, engine.$activeSubtitleTrackIndex)
            .receive(on: RunLoop.main)
            .sink { [weak self] audio, activeAudio, subtitles, activeSubtitle in
                self?.tracksChanged(audio: audio, activeAudio: activeAudio,
                                    subtitles: subtitles, activeSubtitle: activeSubtitle)
            }
            .store(in: &watching)
        #if os(iOS)
        // The picture, for the picture-in-picture window, whichever way the
        // engine is playing the film: through Apple's player, a layer of
        // that; decoding it itself, the frames it puts on screen. It's told
        // while the window is up, and keeps the picture coming for it.
        engine.$videoRoute.combineLatest(engine.$softwarePiPSource)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak engine] _, frames in
                guard let self, let engine else { return }
                let told: (Bool) -> Void = { [weak engine] up in engine?.pictureInPictureActive = up }
                if let frames {
                    PlayerPiP.shared.attach(sampleBuffer: frames, owner: self, onActive: told)
                } else if let layer = engine.nativePlayerLayer {
                    PlayerPiP.shared.attach(playerLayer: layer, owner: self, onActive: told)
                } else {
                    PlayerPiP.shared.detach(owner: self)
                }
            }
            .store(in: &watching)
        #endif
    }

    private func moved(to seconds: Double) {
        if clock.move(to: seconds) { objectWillChange.send() }
        let inSegment = segments.first { $0.contains(seconds) }
        if inSegment != activeSkip { activeSkip = inSegment }
        // The credits, as marked, or the last twenty seconds when nothing
        // marked them, as the other players judge it.
        if !reachedCredits {
            let marked = inSegment?.kind == .outro
            let nearEnd = duration > 180 && seconds >= duration - 20
                && segments.allSatisfy { $0.kind != .outro }
            if marked || nearEnd {
                reachedCredits = true
                onCreditsReached()
            }
        }
    }

    private func stateChanged(_ state: PlaybackState) {
        let playing = state == .playing
        if playing != isPlaying {
            isPlaying = playing
            publishNowPlaying()
            // Told now rather than at the next report, for a remote showing it.
            reportProgress()
        }
        switch state {
        case .ended:
            stop(finished: true)
            onFinished()
        case .error:
            if !stopped { refuse() }
        default:
            break
        }
    }

    /// Loading while the engine is, and stalled once a source it was reading
    /// has stayed down for the fifteen seconds the other players allow.
    private func phaseChanged(_ phase: PlaybackPhase) {
        let loading = phase == .loading || phase == .rebuffering
        if loading != isLoading { isLoading = loading }
        if case .stalled = phase {
            let since = stalledSince ?? Date()
            stalledSince = since
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.stalledSince == since else { return }
                self.stalled = true
            }
        } else {
            stalledSince = nil
            if stalled { stalled = false }
        }
    }

    // MARK: Tracks

    private func tracksChanged(audio: [TrackInfo], activeAudio: Int?,
                               subtitles: [TrackInfo], activeSubtitle: Int?) {
        // Named as the server names them, as the other players' are: the
        // engine's names come from the file ("Portuguese - S_TEXTUTF8").
        let streams = streams
        func name(_ track: TrackInfo) -> String {
            let stream = fileSubtitles[track.id].map { index in streams.first { $0.index == index } }
                ?? streams.stream(atFileStream: track.id)
            return stream?.trackName ?? track.name
        }
        var list = TrackList()
        list.audio = audio.map { PlayerTrack(id: "\($0.id)", name: name($0)) }
        list.subtitles = [PlayerTrack(id: TrackList.subtitlesOff, name: String(localized: "Off", comment: "Subtitles turned off"))]
            + subtitles.map { PlayerTrack(id: "\($0.id)", name: name($0)) }
        let shown = activeSubtitle ?? wantedSubtitle
        list.currentAudio = activeAudio.map { "\($0)" }
        list.currentSubtitle = shown.map { "\($0)" } ?? TrackList.subtitlesOff
        if list != trackList { trackList = list }
        if reportedTracks != [list.currentAudio, list.currentSubtitle] { reportProgress() }
        if shown == nil, subtitleDelay != nil {
            subtitleDelay = nil
        } else if shown != nil, subtitleDelay == nil {
            subtitleDelay = lines.delay
        }
        // The sound's place can be worked out while a subtitle is on to go by.
        if shown != nil, audioSyncDetection == nil {
            audioSyncDetection = .idle
        } else if shown == nil, audioSyncDetection != nil {
            endDetection(.idle)
            audioSyncDetection = nil
        }
    }

    /// Subtitle files kept beside the film, which aren't inside it, listed
    /// with the film's own.
    private func addSubtitleFiles(to engine: AetherEngine) {
        for file in context.subtitleFiles {
            let track = engine.addExternalSubtitleTrack(
                ExternalSubtitleTrack(url: file.url, name: file.name, formatHint: file.url.pathExtension))
            fileSubtitles[track.id] = file.index
        }
    }

    /// The subtitle the account would pick, by the server's number: for one
    /// inside the file, the file's own stream number, which is the engine's.
    private func selectOpeningSubtitle(_ engine: AetherEngine) {
        guard let wanted = context.defaultSubtitleIndex, wanted != PlaybackContext.subtitlesOff else { return }
        guard let id = fileSubtitles.first(where: { $0.value == wanted })?.key
                ?? streams.fileStream(forServerIndex: wanted),
              engine.subtitleTracks.contains(where: { $0.id == id }) else { return }
        wantedSubtitle = id
        engine.selectSubtitleTrack(index: id)
        subtitleDelay = 0
    }

    func selectAudio(_ id: String) {
        guard let index = Int(id) else { return }
        let at = position
        engine?.selectAudioTrack(index: index)
        // The engine starts the new language at the start of the stretch of
        // film it works in: a few seconds in, that was back near the start,
        // dark meanwhile. Back to where it was, once it's taken.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, at > 1, abs(self.position - at) > 1.5 else { return }
            self.seek(toFilmSeconds: at)
        }
    }

    func selectSubtitle(_ id: String) {
        if id == TrackList.subtitlesOff {
            wantedSubtitle = nil
            engine?.clearSubtitle()
            subtitleDelay = nil
        } else if let index = Int(id) {
            wantedSubtitle = index
            engine?.selectSubtitleTrack(index: index)
            subtitleDelay = lines.delay
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        lines.delay = seconds
        subtitleDelay = seconds
    }

    var mediaSourceId: String? { context.mediaSourceId }
    var takesFoundSubtitles: Bool { !context.url.isFileURL }
    var playbackContext: PlaybackContext? { context }

    /// The engine keeps its own account of a session, and names its decoders
    /// for reading.
    func liveStats() -> LiveStats {
        var stats = LiveStats()
        guard let engine else { return stats }
        stats.decoder = engine.activeVideoDecoder
        stats.sound = engine.activeAudioDecoder
        stats.output = switch engine.videoFormat {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .dolbyVision: "Dolby Vision"
        case .hlg: "HLG"
        }
        if let live = engine.liveTelemetry {
            stats.bitrate = live.instantBitrateMbps.map { $0 * 1_000_000 }
            stats.throughput = live.networkThroughputMbps.map { $0 * 1_000_000 }
            stats.buffered = live.forwardBufferSeconds
            stats.droppedFrames = live.droppedFrameCount
            stats.frameRate = live.observedFps
        }
        return stats
    }

    /// Given to the engine as the files beside the film were at the start,
    /// and turned on. The server's numbers for the others have moved with
    /// this one among them, so they're taken again.
    func show(_ found: FoundSubtitle) {
        guard let engine else { return }
        let moved = found.streams.renumbering(of: streams)
        fileSubtitles = fileSubtitles.mapValues { moved[$0] ?? $0 }
        streams = found.streams
        let track = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: found.file, name: found.name, formatHint: found.file.pathExtension))
        fileSubtitles[track.id] = found.index
        wantedSubtitle = track.id
        engine.selectSubtitleTrack(index: track.id)
        subtitleDelay = lines.delay
    }

    /// The engine moves the sound where it still holds its timestamps, and
    /// brings the change to where the film is: a held frame, a third of a
    /// second or so, each time.
    func setAudioDelay(_ seconds: Double) {
        // Set by hand while it's being listened to: the viewer has taken it
        // over, and what's heard from here on isn't the file as it is.
        if case .listening = audioSyncDetection {
            offsetBeforeDetecting = nil
            endDetection(.idle)
        }
        move(audioTo: seconds)
        // What was found has been used, or passed over for something else.
        if case .found = audioSyncDetection { audioSyncDetection = .idle }
    }

    private func move(audioTo seconds: Double) {
        engine?.setAudioDelay(seconds)
        audioDelay = seconds
        AudioSync.set(seconds, for: item.id)
    }

    /// Listens to the film as it plays and works out, from when its lines are
    /// said against when their subtitles are up, how far the sound is out
    /// (see `AudioSyncDetector`). A minute and a half at the least. Asked for
    /// while it's listening, it stops.
    func detectAudioSync() {
        if case .listening = audioSyncDetection { return endDetection(.idle) }
        guard audioSyncDetection != nil, let engine, detecting == nil else { return }
        // The file as it is: anything set comes off while it's listened to,
        // so that what's found is the whole of what's wrong with it, and goes
        // back on if nothing is.
        offsetBeforeDetecting = nil
        if let set = audioDelay, set != 0 {
            offsetBeforeDetecting = set
            move(audioTo: 0)
        }
        detector.startOver()
        audioSyncDetection = .listening(0)
        detecting = Task { [weak self] in
            // The sound stops coming when the engine rebuilds its session (a
            // track changed, the sound was moved): asked for again then, a
            // few times over.
            for _ in 0..<40 {
                let sound = engine.installAudioTap()
                guard engine.audioTapHasDeliverySource else { break }
                for await buffer in sound {
                    guard !Task.isCancelled, let self else { return }
                    if await self.heard(buffer) { return }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(600))
            }
            if !Task.isCancelled { self?.endDetection(.unsure) }
        }
    }

    /// Takes in a stretch of the film's sound; true once that settles it.
    private func heard(_ sound: AudioTapBuffer) async -> Bool {
        guard let samples = sound.buffer.floatChannelData?[0] else { return false }
        detector.add(UnsafeBufferPointer(start: samples, count: Int(sound.buffer.frameLength)), at: sound.sourceTime)
        // Said five seconds at a time: each change redraws the controls.
        let listened = (detector.seconds / 5).rounded(.down) * 5
        if case .listening(let said) = audioSyncDetection, said != listened { audioSyncDetection = .listening(listened) }
        guard detector.due() else { return false }
        let snapshot = detector.snapshot()
        let lag = await Task.detached(priority: .utility) { AudioSyncDetector.lag(in: snapshot) }.value
        guard !Task.isCancelled else { return true }
        if let lag {
            let fix = AudioSyncDetector.correction(for: lag)
            endDetection(fix == 0 ? .inSync : .found(fix))
            return true
        }
        guard detector.seconds >= AudioSyncDetector.most else { return false }
        endDetection(.unsure)
        return true
    }

    private func endDetection(_ outcome: AudioSyncDetection) {
        detecting?.cancel()
        detecting = nil
        engine?.removeAudioTap()
        if audioSyncDetection != nil { audioSyncDetection = outcome }
        // Nothing settled (stopped, or it couldn't tell): the sound goes back
        // to where it had been put.
        if let before = offsetBeforeDetecting {
            offsetBeforeDetecting = nil
            switch outcome {
            case .idle, .unsure: move(audioTo: before)
            default: break
            }
        }
    }

    // MARK: Transport

    func setRate(_ rate: Float) {
        engine?.setRate(rate)
        self.rate = rate
        publishNowPlaying()
    }

    func togglePause() { engine?.togglePlayPause() }

    /// Jumps there and plays on, paused or not, as the other players do.
    func seek(toFilmSeconds seconds: Double) {
        // Short of the very end. Sent to the end itself (the credits skipped,
        // or thirty seconds on from just before it), the engine began the
        // film again from the top; its last second plays out and ends it.
        let last = duration > 1 ? duration - 1 : .infinity
        let target = min(max(seconds, 0), last)
        if clock.move(to: target) { objectWillChange.send() }
        activeSkip = nil
        Task { [weak self] in
            await self?.engine?.seek(to: target)
            if self?.isPlaying == false { self?.engine?.play() }
            // Where it landed, for a remote following it.
            self?.reportProgress()
        }
        publishNowPlaying()
    }

    func skip(_ seconds: Int32) {
        seek(toFilmSeconds: position + Double(seconds))
    }

    func controlsShown(_ shown: Bool) {
        if clock.show(shown) { objectWillChange.send() }
        if lines.raised != shown { lines.raised = shown }
    }

    func stop(finished: Bool = false) {
        guard started, !stopped else { return }
        stopped = true
        progressTimer?.invalidate()
        detecting?.cancel()
        // Closed while it was listening: what the sound had been set to is
        // what's kept for the next time.
        if let before = offsetBeforeDetecting {
            offsetBeforeDetecting = nil
            AudioSync.set(before, for: item.id)
        }
        watching.removeAll()
        #if os(iOS)
        PlayerPiP.shared.detach(owner: self)
        #endif
        stopBeingNowPlaying()
        let ticks = finished ? (context.item.runTimeTicks ?? currentTicks) : currentTicks
        // The TV keeps its mode, as it does after the other players: handing
        // it back blanks the screen for two seconds while HDMI renegotiates.
        engine?.stop(resetDisplayCriteria: false)
        guard reportedStart else { return }
        let (client, context) = (client, context)
        PlaybackReports.shared.track(reports.send { _ = await client?.reportStopped(context, positionTicks: ticks) })
    }

    private var currentTicks: Int64 {
        position > 0 ? Int64(position * 10_000_000) : context.startTicks
    }

    private func reportProgress() {
        guard reportedStart, !stopped else { return }
        let (client, context, ticks, paused) = (client, context, currentTicks, !isPlaying)
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

    /// What the iPhone remote and Control Center show and control: the engine
    /// leaves it to the app, as VLC does.
    private func becomeNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ handle: @escaping (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { handle(event) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        on(center.playCommand) { [weak self] _ in self?.engine?.play() }
        on(center.pauseCommand) { [weak self] _ in self?.engine?.pause() }
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
}
