import SwiftUI
import AVFoundation
import VLCKitSPM

/// Television, as it's broadcast. The server has the tuners; this asks it for
/// a channel, plays what comes, and tells it when the channel's done with so
/// the tuner is free again. One channel at a time: an HDHomeRun has two
/// tuners or four, and someone else in the house may be on the others.
///
/// VLC plays it. What a station sends over the air is MPEG-2 with Dolby
/// Digital sound, interlaced as often as not, and Apple's player has no
/// decoder for any of that. VLC takes the stream as it is and weaves the
/// fields itself, so the server converts nothing.
///
/// The stream is fetched here and kept as it comes (`LiveBuffer`), and VLC
/// is fed from what's kept: so the picture can be held, and taken back
/// through as much of the channel as has been watched.
@MainActor
final class LiveTuner: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    enum Phase: Equatable {
        case idle
        /// Asked for: the server is putting a tuner on it, or the first of
        /// the picture is on its way.
        case tuning
        case playing
        /// The server had no stream to give. Every tuner in use, most often:
        /// it doesn't say which.
        case refused
        /// The stream came and then stopped, or never showed a picture.
        case lost
        /// Not tuned at all: its sound is of a kind nothing here plays
        /// (AC-4, on the newer broadcasts).
        case unplayable
        /// The server never answered. It may well have taken a tuner for
        /// the asking and be holding it still, so the channel isn't asked
        /// for again until it's chosen.
        case unanswered
    }

    /// The channel wanted, from the moment it's asked for.
    @Published private(set) var channelId: String?
    @Published private(set) var phase: Phase = .idle

    /// What the picture is drawn in. The one view for as long as the tuner
    /// lasts: it's handed between the page's preview and the full screen
    /// (see `LiveSurface`), and the channel plays on through the move.
    var surface: UIView { Self.picture }

    /// One view and one player for television, for as long as the app runs,
    /// whichever page's tuner is using them.
    ///
    /// A VLC player can't safely be let go once it has played. Stopping it
    /// is done in the background and the last of it, the picture's view and
    /// the sound, needs the main thread; letting go of the player waits for
    /// all of that, on whichever thread held it last, and the kit's own
    /// notices see to it that this is the main thread as often as not. The
    /// two then wait for each other for good: on an iPhone and on the Apple
    /// TV alike, a moment after Live TV was left, Home was there and the app
    /// was dead (in the iPhone's crash reports, the main thread inside
    /// `-[VLCMediaPlayer dealloc]`). Holding the player a few seconds first
    /// (build 43) wasn't enough: a stream stops in its own time. So this
    /// one is never let go. It is stopped, which is safe, and used again.
    private static let picture: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()
    private static let shared: VLCMediaPlayer = {
        // Interlaced pictures are woven as they're found to be; a
        // progressive one (720p) is left alone.
        let player = VLCMediaPlayer(options: SubtitleAppearance.vlcOptions + ["--deinterlace=-1", "--deinterlace-mode=yadif"])
        player.drawable = picture
        MainActor.assumeIsolated { AudioClarity.shared.attach(player) }
        // The player's own account of what it's doing, when it's asked for.
        if ProcessInfo.processInfo.environment["GOOSETV_VLCLOG"] != nil {
            player.libraryInstance.debugLogging = true
            player.libraryInstance.debugLoggingLevel = 3
        }
        return player
    }()
    /// The tuner the player is playing for: the last to start a channel.
    /// One that has been left behind (its page gone, its channel let go)
    /// doesn't touch what another has on.
    private static weak var owner: LiveTuner?
    private var owns: Bool { Self.owner === self }

    private var player: VLCMediaPlayer { Self.shared }
    private var client: (any MediaServer)?
    /// The channel the server has a tuner on for this device, if any.
    private var stream: LiveStream?
    private var work: Task<Void, Never>?
    private var heartbeat: Timer?
    private var patience: Task<Void, Never>?
    /// Counts the asks, so an answer that comes back after the next ask is
    /// known for what it is.
    private var asks = 0
    #if os(iOS)
    /// Listening for the car's player starting.
    private var carWatch: NSObjectProtocol?
    #endif
    /// Listening for music starting.
    private var musicWatch: NSObjectProtocol?
    /// Whether a stream left open by an earlier run has been looked for.
    private var tidied = false
    /// How many channels the server has been asked for and hasn't answered
    /// about yet.
    private var asking = 0
    /// Whether the stream that's open has shown a picture yet.
    private var pictured = false
    /// What's been learnt of channels this run that settles them without a
    /// tuner: the ones that can't be played, the ones the server went
    /// silent on.
    private var verdicts: [String: Phase] = [:]
    /// The channels the server has described as something that plays.
    private var cleared: Set<String> = []
    private static let openKey = "goosetv.liveTV.openStream"

    /// What the channel has sent since it was tuned, and the player's end
    /// of it (see `LiveBuffer`): the picture can be taken back through it,
    /// and held. None for a stream the server is converting, which comes as
    /// a list of pieces the player fetches for itself.
    private var buffer: LiveBuffer?
    private var feed: LiveFeed?
    /// The server's own recording of what's on, where it is making one: the
    /// way back past the tuning, to the programme's beginning.
    private var recording: LiveRecording?
    /// The player is being fed from the recording, not from what's kept here.
    private var onRecording = false
    /// A recording to begin the channel from, in place of the broadcast as
    /// it goes out, once the channel's tuned.
    private var opening: LiveRecording?
    /// How far behind the broadcast the picture is, in seconds: nothing,
    /// watched as it goes out.
    @Published private(set) var behind: TimeInterval = 0
    /// Held still. The broadcast goes on being kept, so the picture is the
    /// further behind for every second of it.
    @Published private(set) var isPaused = false
    private var pausedAt: Date?
    /// A new feed's first picture is still to come: what's set on the
    /// player (the sound's delay, the captions) is set again for it.
    private var feedIsNew = false
    /// How much the player was told to keep in hand for what it's playing,
    /// in milliseconds.
    private var inHand = 1500
    /// Held, as far as the viewer's concerned, with the player not told yet:
    /// it has nothing to hold until a new feed's picture has come.
    private var pauseWanted = false

    /// A set of captions the channel carries, as the player names it.
    struct Caption: Identifiable, Equatable {
        let id: Int32
        let name: String
    }

    /// The captions of the channel that's playing, as far as the player has
    /// found them. A broadcast's are carried inside its picture, and aren't
    /// known of until some have gone by: a few seconds in, as a rule, and
    /// not at all on a programme that has none.
    @Published private(set) var captions: [Caption] = []
    /// The set being shown, if any.
    @Published private(set) var caption: Int32?
    /// The captions asked for, by name: kept from channel to channel and
    /// from one day to the next, as a television keeps them. Each channel
    /// numbers its own, so it's the name that's kept.
    private static let captionKey = "goosetv.liveTV.caption"
    private var captionsRead = Date.distantPast

    /// How much later than its picture the sound is played, in seconds
    /// (earlier, below nought): set by ear, for a loudspeaker that takes its
    /// own time over the sound, as a HomePod does. It's the way the sound
    /// leaves that's being put right, not a station, so it's kept for that:
    /// set with the sound going to a HomePod, it isn't applied to the
    /// television's own loudspeakers.
    @Published private(set) var soundDelay: Double = AudioSync.offset(for: LiveTuner.soundRoute)
    /// The way out the delay in force was read for.
    private var soundRouteApplied: String?
    private static let soundKey = "goosetv.liveTV.soundRoutes"


    /// Whether the picture on the surface is this channel's.
    func shows(_ id: String?) -> Bool { id != nil && id == channelId && phase == .playing }

    /// Tunes to a channel, after a pause if one is asked for: channel up
    /// pressed three times passes over two channels it isn't stopping at,
    /// and each tuned is a tuner taken and let go again. What was playing is
    /// hushed at once and its tuner let go before the next is asked for,
    /// since the next may need that very tuner.
    func tune(to id: String, on client: any MediaServer, after delay: Duration = .zero, from start: LiveRecording? = nil) {
        // Playing needs the trial or the unlock (see `Unlock`): the channel
        // is tuned once it's unlocked. Not insisted on, so the screen isn't
        // brought straight back by the next channel after it's put away.
        guard Unlock.shared.mayPlay else {
            Unlock.shared.ask(insist: false) { [weak self] in self?.tune(to: id, on: client, from: start) }
            return
        }
        if id == channelId, phase == .tuning || phase == .playing {
            // On already: taken back to the beginning where it stands.
            if let start {
                if phase == .playing { reach(into: start); go(behind: reach) } else { opening = start }
            }
            return
        }
        opening = start
        self.client = client
        channelId = id
        #if os(iOS)
        // One thing playing at a time: the car's player stops, and this
        // stops when the car starts something.
        Task { await CarPlayPlayer.shared.stop() }
        if carWatch == nil {
            carWatch = NotificationCenter.default.addObserver(forName: CarPlayPlayer.willPlay, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
        #endif
        // Music pauses for a channel, and a song started stops it.
        MusicPlayer.shared.yield()
        if musicWatch == nil {
            musicWatch = NotificationCenter.default.addObserver(forName: MusicPlayer.willPlay, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
        work?.cancel()
        patience?.cancel()
        asks += 1
        let mine = asks
        // Back on the channel that's still tuned, before the pause to let it
        // go was up: it plays on.
        if id == stream?.channelId, pictured, owns {
            player.audio?.isMuted = DebugSound.muted
            phase = .playing
            if let start = opening {
                opening = nil
                reach(into: start)
                go(behind: reach)
            }
            return
        }
        let known = verdicts[id]
        phase = known ?? .tuning
        quiet()
        work = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            await tidy(on: client)
            guard !Task.isCancelled, mine == asks else { return }
            if await release() {
                // A breath for the tuner to come free at the box itself: the
                // server has let go of it, and the next channel may need it.
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard known == nil, !Task.isCancelled, mine == asks else { return }
            if !cleared.contains(id) {
                let plays = await client.livePlayable(channelId: id)
                guard !Task.isCancelled, mine == asks else { return }
                if plays == false {
                    verdicts[id] = .unplayable
                    phase = .unplayable
                    return
                }
                if plays == true { cleared.insert(id) }
            }
            // One asking at a time. A second, sent while the server is
            // still about the first, is a second tuner taken until the first
            // is answered and given back, and a guide read at a row a second
            // was soon every tuner in the house. Not for ever, though: a
            // server stuck on one channel isn't to keep the rest waiting.
            var waited = 0
            while asking > 0, waited < 80 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
                guard !Task.isCancelled, mine == asks else { return }
            }
            // Asked in a task of its own, which a change of mind doesn't
            // cancel. Cancelled part-way, the request was abandoned with the
            // server already tuning: a tuner taken for a stream nobody had
            // the name of, to give back. Seen out, it can be.
            asking += 1
            let pass = UIApplication.shared.beginBackgroundTask(withName: "LiveTV tuning")
            await Task { [weak self] in
                // In turn with every other player's asking (a wall's, the car's).
                let answer: Result<LiveStream, Error> = await LiveOpenLine.run {
                    do { return .success(try await client.openLiveStream(channelId: id)) } catch { return .failure(error) }
                }
                if let self {
                    await self.answered(answer, for: id, ask: mine, on: client)
                } else if case .success(let stream) = answer {
                    await Self.giveBack(stream, to: client)
                }
                UIApplication.shared.endBackgroundTask(pass)
            }.value
        }
    }

    private func answered(_ answer: Result<LiveStream, Error>, for id: String, ask mine: Int, on client: any MediaServer) async {
        switch answer {
        case .success(let stream):
            if mine == asks {
                play(stream, on: client)
            } else {
                // Asked for and no longer wanted: the tuner goes straight back.
                await Self.giveBack(stream, to: client)
            }
        case .failure(let error):
            // Turned down is an answer. None at all, for as long as a
            // request is given, is a server stuck on the channel.
            let silent = (error as? URLError)?.code == .timedOut
            if silent { verdicts[id] = .unanswered }
            if mine == asks { phase = silent ? .unanswered : .refused }
        }
        asking -= 1
    }

    /// The channel again, after it was refused or lost, or the server never
    /// answered for it. Not one that can't be played: it still can't.
    func retry() {
        guard let id = channelId, let client, phase == .refused || phase == .lost || phase == .unanswered else { return }
        verdicts[id] = nil
        phase = .idle
        tune(to: id, on: client)
    }

    /// Done with television: the page left, the app put away.
    func stop() {
        work?.cancel()
        patience?.cancel()
        asks += 1
        channelId = nil
        if phase != .idle { phase = .idle }
        heartbeat?.invalidate()
        heartbeat = nil
        guard let stream, let client else { return }
        self.stream = nil
        Self.letGo(stream)
        pictured = false
        forgetCaptions()
        if owns {
            player.stop()
            PlaybackAudioSession.release()
        }
        endShift()
        let report = Task { [weak self] in
            // Struck out once the server's been told and not before: put
            // away and killed in the moment between, the app would leave a
            // stream open that nothing remembered to close. Nor if it
            // couldn't be told (the network gone as the device slept): it
            // stays written down, and is given back the next time
            // television is asked for.
            if await client.reportLive(stream, .stopped) {
                Self.forget(stream)
            } else {
                Self.stopUnheard(stream)
                self?.tidied = false
            }
        }
        PlaybackReports.shared.track(report)
        // Put away part-way through, the app is given the moment it takes
        // to say so: a tuner is somebody else's evening.
        let pass = UIApplication.shared.beginBackgroundTask(withName: "LiveTV")
        Task {
            await report.value
            UIApplication.shared.endBackgroundTask(pass)
        }
    }

    /// The stream this device has open, written down while it's open. An
    /// app that's killed, or a television unplugged, says nothing to the
    /// server, which keeps the tuner on the channel for nobody, and went on
    /// keeping it for as long as it was watched doing so; the next time
    /// television is asked for here, that one is given back first.
    ///
    /// Several may be open at once (the channels of a wall, the car's), so
    /// they're a list; and the ones this run still has open are known, and
    /// never given back as left over.
    static func note(_ stream: LiveStream, on client: any MediaServer) {
        guard let live = stream.liveStreamId else { return }
        var saved = ["server": client.baseURL.absoluteString, "channel": stream.channelId, "live": live]
        saved["source"] = stream.mediaSourceId
        saved["session"] = stream.playSessionId
        UserDefaults.standard.set(notes().filter { $0["session"] != stream.playSessionId } + [saved], forKey: openListKey)
        if let session = stream.playSessionId { held.insert(session) }
    }

    /// The stream's been given back: it needn't be remembered.
    static func forget(_ stream: LiveStream) {
        if let session = stream.playSessionId {
            held.remove(session)
            stopping.remove(session)
        }
        UserDefaults.standard.set(notes().filter { $0["session"] != stream.playSessionId }, forKey: openListKey)
    }

    /// Done with by this run, its stop report on the way: not given back as
    /// left over meanwhile (a second report for one stream takes a second
    /// viewer off the server's count of a channel others may be on).
    static func letGo(_ stream: LiveStream) {
        guard let session = stream.playSessionId else { return }
        held.remove(session)
        stopping.insert(session)
    }

    /// Its stop report wasn't heard: left over now, to be given back by the
    /// next player to tune.
    static func stopUnheard(_ stream: LiveStream) {
        if let session = stream.playSessionId { stopping.remove(session) }
    }

    /// The streams this run has open now, by play session.
    private static var held: Set<String> = []
    /// The streams this run has let go of whose stop report is on its way.
    private static var stopping: Set<String> = []
    private static let openListKey = "goosetv.liveTV.openStreams"

    /// What's written down, taking in the one an earlier version kept alone.
    private static func notes() -> [[String: String]] {
        var list = UserDefaults.standard.array(forKey: openListKey) as? [[String: String]] ?? []
        if let single = UserDefaults.standard.dictionary(forKey: openKey) as? [String: String] {
            list.append(single)
            UserDefaults.standard.removeObject(forKey: openKey)
            UserDefaults.standard.set(list, forKey: openListKey)
        }
        return list
    }

    private func tidy(on client: any MediaServer) async {
        guard !tidied else { return }
        tidied = true
        if !(await Self.giveBackLeftover(on: client)) { tidied = false }
    }

    /// Gives back the streams written down and never let go of, by this
    /// player or another (the car's, a wall's) in a run that ended without
    /// saying; false if the server couldn't be told of one.
    @discardableResult
    static func giveBackLeftover(on client: any MediaServer) async -> Bool {
        var heard = true
        for saved in notes() where saved["server"] == client.baseURL.absoluteString {
            if let session = saved["session"], held.contains(session) || stopping.contains(session) { continue }
            if await giveBack(saved, on: client) == false { heard = false }
        }
        return heard
    }

    private static func giveBack(_ saved: [String: String], on client: any MediaServer) async -> Bool {
        guard let live = saved["live"] else { return true }
        let left = LiveStream(channelId: saved["channel"] ?? "", url: client.baseURL, liveStreamId: live,
                              mediaSourceId: saved["source"], playSessionId: saved["session"], isDirect: true)
        // Only while the server still has this device on it. A channel's
        // stream goes by the one name whoever opens it, and the server lets
        // go of a player that's gone quiet (within minutes) by itself: a
        // stop sent after that ended whatever had opened the channel since —
        // a recording under way, another room's picture — since the server
        // counts a stop against the stream, not against the device.
        switch await client.stillWatching(liveStreamId: live, channelId: saved["channel"]) {
        case false?:
            forget(left)
            return true
        case nil:
            return false
        case true?:
            break
        }
        // Struck out when the server has heard, as everywhere else: one it
        // couldn't be told of is tried again at the next channel.
        guard await giveBack(left, to: client) else { return false }
        forget(left)
        return true
    }

    /// Tells the server a stream is done with, in a task of its own. The
    /// asking is mostly done from a change of channel, and a change of
    /// channel is cancelled by the next one: a request made from a cancelled
    /// task is dropped unsent, and the tuner it was to free stayed taken
    /// until the server noticed for itself, minutes later.
    @discardableResult
    private static func giveBack(_ stream: LiveStream, to client: any MediaServer) async -> Bool {
        await Task { await client.reportLive(stream, .stopped) }.value
    }

    /// Silences what's playing at once, ahead of a change of channel that
    /// waits a moment to be sure of itself: the sound of the last channel
    /// under the name of the next is nobody's idea of a guide.
    func quiet() {
        guard stream != nil else { return }
        if owns { player.audio?.isMuted = true }
        if phase == .playing { phase = .tuning }
    }

    /// Lets go of the channel that's tuned; false if none was.
    @discardableResult
    private func release() async -> Bool {
        heartbeat?.invalidate()
        heartbeat = nil
        guard let stream, let client else { return false }
        self.stream = nil
        Self.letGo(stream)
        pictured = false
        forgetCaptions()
        if owns { player.stop() }
        endShift()
        if await Self.giveBack(stream, to: client) {
            Self.forget(stream)
        } else {
            // Not heard: it stays written down, to be given back before the
            // next channel is asked for.
            Self.stopUnheard(stream)
            tidied = false
        }
        return true
    }

    private func play(_ stream: LiveStream, on client: any MediaServer) {
        self.stream = stream
        pictured = false
        forgetCaptions()
        Self.note(stream, on: client)
        Self.owner = self
        player.delegate = self
        endShift()
        // The station's own stream is fetched here and kept, and the player
        // fed from what's kept, so that it can be gone back through. One
        // the server is converting the player fetches itself, as before.
        if stream.isDirect, let buffer = LiveBuffer() {
            self.buffer = buffer
            buffer.onEnd = { [weak self, weak buffer] in
                Task { @MainActor in
                    guard let self, let buffer, self.buffer === buffer else { return }
                    self.dropped()
                }
            }
            buffer.onBroken = { [weak self, weak buffer] in
                Task { @MainActor in
                    guard let self, let buffer, self.buffer === buffer else { return }
                    self.playPlain()
                }
            }
            buffer.start(stream.url)
            feed = LiveFeed(buffer, from: nil)
        }
        // Asked for from the programme's beginning: the first picture is
        // the recording's, not the broadcast's (which, in a match, is the
        // score). The broadcast is kept all the same, to be caught up to.
        if let start = opening, stream.channelId == channelId, let began = start.began,
           let first = LiveFeed(reading: start.reader(behind: nil)) {
            feed?.cancel()
            feed = first
            adopt(start)
            onRecording = true
            behind = max(Date().timeIntervalSince(began), 0)
        }
        opening = nil
        PlaybackAudioSession.take()
        player.media = media(for: stream)
        feedIsNew = true
        player.audio?.isMuted = DebugSound.muted
        #if os(iOS)
        // One thing plays at a time: a film left in its small window is
        // closed, where it got to filed. Both sounded together, and
        // whichever stopped first took the sound from the other.
        PlayerStage.shared.askToClose()
        #elseif os(macOS)
        // The same for a film in its own window.
        NotificationCenter.default.post(name: MacPlayerStage.closeAsked, object: nil)
        #endif
        noteSound("latencyAtStart")
        // Television is shown in the TV's own mode, as its home screen is:
        // switched to each channel's rate, the screen went blank and came
        // back in another mode every time Live TV was opened. A mode a film
        // left behind is given back, though: a broadcast at 59.94 shown at
        // 24 Hz judders.
        DisplayCriteria.reset()
        player.play()
        Task { await client.reportLive(stream, .started) }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let stream = self.stream, let client = self.client else { return }
                await client.reportLive(stream, .playing)
            }
        }
        // A tuner with no signal on the channel hands over a stream with
        // nothing in it, and VLC waits on it for as long as it's let.
        let mine = asks
        patience = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, mine == asks, phase == .tuning else { return }
            await release()
            if mine == asks { phase = .lost }
        }
    }

    // MARK: Back through the broadcast

    /// What the player is playing for the stream that's open: its feed from
    /// what's kept, or the stream itself.
    private var playingURL: URL? { feed?.url ?? stream?.url }

    private func media(for stream: LiveStream) -> VLCMedia {
        let media = VLCMedia(url: feed?.url ?? stream.url)
        // A second and a half in hand: enough to ride out a hiccup on the
        // way from the tuner, and not so much that the channel is slow to
        // come. More where the sound is going somewhere slow (a HomePod
        // takes two seconds over it): the channel is that much longer
        // coming, and its voices are with its lips. Both names for it:
        // which one the player goes by depends on where it thinks the
        // stream is from.
        inHand = PlaybackAudioSession.inHand(atLeast: 1500)
        media.addOption(":network-caching=\(inHand)")
        media.addOption(":file-caching=\(inHand)")
        return media
    }

    /// The channel again from where it is, with what's kept in hand set
    /// for where the sound is going now: sent to a HomePod part-way
    /// through, it had only what a headset needs.
    private func reopen() {
        guard owns, let stream, phase == .playing else { return }
        if buffer != nil || onRecording {
            go(behind: isPaused ? behind(at: Date()) : behind)
        } else {
            feedIsNew = true
            player.media = media(for: stream)
            player.play()
        }
    }

    /// What's on the air doesn't end: the tuner dropped it, or the server
    /// let it go.
    private func dropped() {
        guard let stream, phase == .tuning || phase == .playing else { return }
        let mine = asks
        let wanted = stream.channelId == channelId
        patience?.cancel()
        Task { [weak self] in
            await self?.release()
            if let self, wanted, mine == self.asks { self.phase = .lost }
        }
    }

    /// The channel the plain way, the player fetching the stream itself:
    /// what came couldn't be kept (a device with no room), and a player fed
    /// from nothing shows nothing. The tuner is the same one; only the
    /// going back is lost.
    private func playPlain() {
        guard owns, let stream, phase == .tuning || phase == .playing else { return }
        buffer?.stop()
        buffer = nil
        // The picture is the server's recording, which needs nothing kept
        // here: it goes on.
        if onRecording { return }
        feed?.cancel()
        feed = nil
        pausedAt = nil
        pauseWanted = false
        if behind != 0 { behind = 0 }
        if isPaused { isPaused = false }
        feedIsNew = true
        player.media = media(for: stream)
        player.play()
    }

    /// Whether the picture can be taken back at all: not for a stream the
    /// server is converting, unless the server is recording the programme.
    var shifts: Bool { (buffer != nil || recording != nil) && phase == .playing }

    /// How far back there is to go, in seconds: as long as the channel has
    /// been on, up to what's kept; or to the beginning of the server's
    /// recording of what's on, where it's making one.
    var reach: TimeInterval { max(keptReach, recordedReach) }

    private var keptReach: TimeInterval {
        guard let kept = buffer?.kept else { return 0 }
        return max(Date().timeIntervalSince(kept.from), 0)
    }

    private var recordedReach: TimeInterval {
        guard let began = recording?.began else { return 0 }
        return max(Date().timeIntervalSince(began), 0)
    }

    /// The timer of the recording there is to go back through, past what's
    /// kept, if there's one.
    var recordingTimer: String? { recording?.began == nil ? nil : recording?.timerId }

    /// The recording the server is making of what's on, to go back
    /// through: it must have been measured. Nil when the programme's over,
    /// or was never being recorded.
    func reach(into recording: LiveRecording?) {
        guard recording !== self.recording else { return }
        if let recording {
            guard recording.began != nil, stream != nil else { return }
            // Being watched from the one before (the next programme is being
            // recorded too): that one is seen out to its end first. Taken
            // from under the picture, it ended the feed, and the channel was
            // let go with the viewer's place in it.
            guard !onRecording else { return }
            adopt(recording)
        } else if onRecording {
            // Being watched from: seen out to its end (see `recordingEnded`).
        } else {
            self.recording?.stop()
            self.recording = nil
            objectWillChange.send()
        }
    }

    private func adopt(_ recording: LiveRecording) {
        self.recording?.stop()
        self.recording = recording
        recording.onOver = { [weak self, weak recording] in
            Task { @MainActor in
                guard let self, let recording, self.recording === recording else { return }
                self.recordingEnded()
            }
        }
        objectWillChange.send()
    }

    /// The recording has run out under the picture: the programme ended,
    /// that long ago. What came after it is in what's kept here, as far
    /// back as that goes.
    private func recordingEnded() {
        let fed = onRecording
        recording?.stop()
        recording = nil
        onRecording = false
        guard fed, owns, stream != nil, phase == .playing else { return }
        let held = isPaused
        if buffer != nil {
            go(behind: behind(at: Date()))
        } else {
            behind = 0
            playPlain()
        }
        if held { pause() }
    }

    /// How far behind the picture is this moment, held or playing.
    func behind(at moment: Date = Date()) -> TimeInterval {
        min(behind + (pausedAt.map { moment.timeIntervalSince($0) } ?? 0), max(reach, behind))
    }

    /// Shows the broadcast of so many seconds ago, or as it goes out for
    /// anything under a few seconds: the player is given what's kept from
    /// that moment on, and plays on from there.
    func go(behind seconds: TimeInterval) {
        guard owns, let stream, buffer != nil || recording != nil, phase == .playing else { return }
        let back = min(seconds, reach - 2)
        let old = feed
        // As it goes out: from as far before the newest as the player keeps
        // in hand, so that it has that at once and isn't a while filling up.
        let lead = Double(PlaybackAudioSession.inHand(atLeast: 1500)) / 1000
        if let buffer, back < 4 || back <= keptReach - 2 {
            // From what's kept here, for as far back as that goes.
            guard let next = LiveFeed(buffer, from: buffer.place(at: Date().addingTimeInterval(-(back < 4 ? lead : back)))) else { return }
            feed = next
            behind = back < 4 ? 0 : back
            onRecording = false
        } else if let recording, recording.began != nil {
            // From the server's recording: further back than the tuning.
            // (And nearer than that, where nothing's kept here at all.)
            guard let next = LiveFeed(reading: recording.reader(behind: back < 4 ? lead + 1 : back)) else { return }
            feed = next
            behind = back < 4 ? 0 : back
            onRecording = true
        } else {
            return
        }
        pausedAt = nil
        pauseWanted = false
        if isPaused { isPaused = false }
        feedIsNew = true
        player.media = media(for: stream)
        player.play()
        old?.cancel()
    }

    func pause() {
        guard owns, buffer != nil || recording != nil, phase == .playing, !isPaused else { return }
        // Nothing fed from here to hold (nothing's kept, and the player has
        // the broadcast itself): from the recording, then, a moment back.
        if feed == nil {
            go(behind: 5)
            guard feed != nil else { return }
        }
        isPaused = true
        // Straight after a move the player is between one feed and the
        // next, with nothing to hold: told now, it took no notice and
        // played on under a bar that said it was held. It's told as the
        // new feed's picture comes.
        if feedIsNew {
            pauseWanted = true
        } else {
            player.pause()
            pausedAt = Date()
        }
    }

    func resume() {
        guard owns, isPaused else { return }
        isPaused = false
        if pauseWanted {
            // Never held at all.
            pauseWanted = false
            return
        }
        behind = behind(at: Date())
        pausedAt = nil
        player.play()
    }

    /// Back to the broadcast as it goes out, playing: for where the
    /// picture is shown with nothing to say it's behind (the corner of the
    /// guide).
    func catchUp() {
        if isPaused || behind > 0 { go(behind: 0) }
    }

    /// The channel's going: nothing of it is kept.
    private func endShift() {
        feed?.cancel()
        feed = nil
        buffer?.stop()
        buffer = nil
        recording?.stop()
        recording = nil
        onRecording = false
        pausedAt = nil
        pauseWanted = false
        if behind != 0 { behind = 0 }
        if isPaused { isPaused = false }
    }

    // MARK: Sound against picture

    /// The kind of thing the sound is going to (HDMI, AirPlay, a headset),
    /// as what's kept for it is filed.
    private static var soundRoute: String {
        #if os(macOS)
        // The Mac's sound goes where its Sound settings say; one entry serves.
        "live:mac"
        #else
        "live:" + (AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "")
        #endif
    }

    func set(soundDelay seconds: Double) {
        AudioSync.set(seconds, for: Self.soundRoute)
        applySoundDelay()
    }

    /// Puts in force what's kept for where the sound is going now: as a
    /// channel's picture comes, when it's changed, and when the sound is
    /// sent somewhere else.
    private func applySoundDelay() {
        let route = Self.soundRoute
        soundRouteApplied = route
        let seconds = AudioSync.offset(for: route)
        if soundDelay != seconds { soundDelay = seconds }
        guard owns, stream != nil else { return }
        player.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
        noteSound("latencyAtPicture")
    }

    /// Writes down what the system says of the way the sound is leaving,
    /// where it can be read back: a report of sound out of step is settled
    /// by these numbers. One entry for each way out (the last on AirPlay
    /// isn't lost to the next on a headset), with the delay it owns to at
    /// three moments: as the channel is started, as its picture comes, and
    /// a few seconds on. The player reads it once, as it starts.
    private func noteSound(_ moment: String) {
        let route = Self.soundRoute
        var all = UserDefaults.standard.dictionary(forKey: Self.soundKey) as? [String: [String: Any]] ?? [:]
        var entry = all[route] ?? [:]
        if moment == "latencyAtStart" { entry = [:] }
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        entry[moment] = session.outputLatency
        entry["buffer"] = session.ioBufferDuration
        entry["rate"] = session.sampleRate
        entry["channels"] = session.outputNumberOfChannels
        #endif
        entry["delay"] = AudioSync.offset(for: route)
        entry["inHand"] = inHand
        entry["at"] = Date().timeIntervalSince1970
        all[route] = entry
        UserDefaults.standard.set(all, forKey: Self.soundKey)
    }

    // MARK: Captions

    /// Shows a set of captions, or none. What's chosen is what the next
    /// channel shows too, where it carries a set of the same name, and the
    /// first it has where it doesn't.
    func show(caption id: Int32?) {
        guard owns, stream != nil else { return }
        let chosen = captions.first { $0.id == id }
        if let chosen {
            UserDefaults.standard.set(chosen.name, forKey: Self.captionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.captionKey)
        }
        player.currentVideoSubTitleIndex = chosen?.id ?? -1
        if caption != chosen?.id { caption = chosen?.id }
    }

    /// Reads what captions the player has found, every couple of seconds
    /// while the channel plays, and turns on the ones asked for once they're
    /// there to be turned on.
    private func readCaptions() {
        guard Date().timeIntervalSince(captionsRead) > 2 else { return }
        captionsRead = Date()
        if Self.soundRoute != soundRouteApplied {
            applySoundDelay()
            if PlaybackAudioSession.inHand(atLeast: 1500) > inHand { return reopen() }
        }
        // Still in force? A notice left over from the feed before can
        // arrive after a move and be taken for the new one's first, and
        // the delay was then set on a player with nothing playing.
        let wanted = Int(soundDelay * 1_000_000)
        if player.currentAudioPlaybackDelay != wanted { player.currentAudioPlaybackDelay = wanted }
        let names = player.videoSubTitlesNames as? [String] ?? []
        let ids = (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.int32Value)
        // The player's own first line is "none", numbered -1.
        let found = zip(ids, names).filter { $0.0 >= 0 }.map { Caption(id: $0.0, name: $0.1) }
        if found != captions { captions = found }
        let showing = player.currentVideoSubTitleIndex
        if showing < 0, let wanted = UserDefaults.standard.string(forKey: Self.captionKey),
           let match = found.first(where: { $0.name == wanted }) ?? found.first {
            player.currentVideoSubTitleIndex = match.id
            if caption != match.id { caption = match.id }
        } else {
            let now: Int32? = found.contains { $0.id == showing } ? showing : nil
            if caption != now { caption = now }
        }
    }

    private func forgetCaptions() {
        captionsRead = .distantPast
        if !captions.isEmpty { captions = [] }
        if caption != nil { caption = nil }
    }

    // MARK: VLCMediaPlayerDelegate (called on the main thread)

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            // The clock moving is the picture arriving: of the channel
            // that's wanted, that is. One being left plays on, hushed, for
            // the moment before its tuner is let go, and isn't the picture
            // for the next one's name.
            if owns, phase == .playing, stream?.channelId == channelId {
                if feedIsNew, player.media?.url == playingURL {
                    // The first of a picture from another moment: the
                    // player has forgotten what was set on the last.
                    feedIsNew = false
                    captionsRead = .distantPast
                    applySoundDelay()
                    if pauseWanted {
                        pauseWanted = false
                        player.pause()
                        pausedAt = Date()
                    }
                }
                readCaptions()
            }
            guard owns, phase == .tuning, let stream, stream.channelId == channelId, player.media?.url == playingURL else { return }
            patience?.cancel()
            pictured = true
            feedIsNew = false
            player.audio?.isMuted = DebugSound.muted
            phase = .playing
            applySoundDelay()
            let mine = asks
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if let self, mine == self.asks, self.phase == .playing { self.noteSound("latencyLater") }
            }
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            guard owns, stream != nil, player.media?.url == playingURL, phase == .tuning || phase == .playing else { return }
            switch player.state {
            case .error, .ended:
                dropped()
            default:
                break
            }
        }
    }
}

/// Where the tuner's picture is shown. There's one picture and may be two
/// places for it, the preview on the Live TV page and the full screen over
/// it; whichever is `showing` takes the tuner's view into itself, and the
/// channel plays on through the handover.
struct LiveSurface: UIViewRepresentable {
    let tuner: LiveTuner
    let showing: Bool

    func makeUIView(context: Context) -> LiveSurfaceHost {
        let host = LiveSurfaceHost()
        host.backgroundColor = .clear
        return host
    }

    func updateUIView(_ host: LiveSurfaceHost, context: Context) {
        if showing { host.adopt(tuner.surface) }
    }
}

final class LiveSurfaceHost: UIView {
    func adopt(_ surface: UIView) {
        guard surface.superview !== self else { return }
        surface.removeFromSuperview()
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }
}
