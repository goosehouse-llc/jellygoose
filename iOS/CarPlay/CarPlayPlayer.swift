import AVFoundation
import MediaPlayer
import UIKit

/// Plays what's chosen on the car's display. Apple's player only, since the
/// car takes its picture over AirPlay: a file Apple's player can't open as it
/// is comes from the server converted, as it did before the app had players
/// of its own, and a subtitle is burnt into the picture, there being nothing
/// in the car to draw one over it.
///
/// It has no screen: the car shows the picture, or Now Playing, and the
/// phone may be locked in a pocket.
///
/// In a car that can't show a picture at all, only the sound is fetched
/// (`audioOnly`): the soundtrack alone, a few per cent of a film's data over
/// a phone's connection, with nothing burnt into a picture nobody sees.
@MainActor
final class CarPlayPlayer {
    static let shared = CarPlayPlayer()

    /// Posted as something starts here, so the phone's own player closes: one
    /// film at a time.
    static let willPlay = Notification.Name("jellygoose.carplay.willPlay")
    /// Posted once something has started here or stopped: the car's own
    /// screen (`CarScreen`) puts up its picture or takes it down.
    static let didChange = Notification.Name("jellygoose.carplay.didChange")
    /// Posted when something ran to its end with nothing to follow it: the
    /// car's own screen closes its player.
    static let didFinish = Notification.Name("jellygoose.carplay.didFinish")

    /// The car's screen is the app's own window (a car that can't show an
    /// app's video, see `CarScreenSceneDelegate`): the picture is drawn there
    /// rather than sent to the car by AirPlay.
    var drawsOwnPicture = false

    /// A title's audio tracks and subtitles, and which of each is in use.
    struct Tracks {
        let audio: [MediaStream]
        let subtitles: [MediaStream]
        let chosenAudio: Int?
        /// `PlaybackContext.subtitlesOff` for none.
        let chosenSubtitle: Int
    }

    /// What's playing, in full (its file and tracks included).
    private(set) var current: BaseItem?
    /// Only the sound is being played: the car shows no picture.
    private(set) var audioOnly = false
    /// The television channel playing, where it's a channel.
    private(set) var channel: LiveChannel?
    /// Its stream: the server's, let go of by the stop report.
    private var liveStream: LiveStream?
    /// The channels in the order the car lists them, for channel up and down.
    private var channels: [LiveChannel] = []

    private var player: AVPlayer?
    private var context: PlaybackContext?
    private var client: MediaBrowserClient?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// A stream the server started part-way through runs from zero on its own
    /// clock: this is added to make the film's time.
    private var offsetSeconds: Double = 0
    private var commandsReady = false
    /// The tracks picked for a title, by its id: nil for the server's own
    /// choice. Kept while the app runs, so a choice made on a film's page
    /// holds when it's played, and one made while it plays holds if it's
    /// played again.
    private var choices: [String: (audio: Int?, subtitle: Int?)] = [:]

    /// Starts `item` where it was left, from its beginning, or from `ticks`.
    /// False if the server offered nothing playable.
    func play(_ item: BaseItem, client: MediaBrowserClient, fromBeginning: Bool = false,
              at ticks: Int64? = nil, audioOnly: Bool? = nil) async -> Bool {
        // Playing needs the trial or the unlock (see `Unlock`): it's asked
        // for on the phone, where a purchase is confirmed.
        guard Unlock.shared.mayPlay else { Unlock.shared.ask(); return false }
        // Carried on as it was when a track change starts it again.
        let audioOnly = audioOnly ?? self.audioOnly
        await stop()
        // The lists carry no file details; the item in full does.
        guard let full = try? await client.item(id: item.id) else { return false }
        let choice = choices[full.id]
        let from = ticks ?? (fromBeginning ? 0 : full.resumeTicks)
        let made: PlaybackContext?
        if audioOnly {
            made = client.audioOnlyContext(for: full, startTicks: from, audioIndex: choice?.audio)
        } else {
            made = try? await client.playbackContext(for: full, startTicks: from,
                                                     audioIndex: choice?.audio, subtitleIndex: choice?.subtitle,
                                                     mediaSourceId: nil, systemPlayerOnly: true)
        }
        guard let context = made else { return false }
        self.audioOnly = audioOnly

        NotificationCenter.default.post(name: Self.willPlay, object: nil)
        MusicPlayer.shared.yield()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: audioOnly ? .spokenAudio : .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let player = AVPlayer(url: context.url)
        player.allowsExternalPlayback = !drawsOwnPicture
        // The car's: on as sound when the app is put behind another.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        self.player = player
        self.context = context
        self.client = client
        current = full

        let start = Double(context.startTicks) / 10_000_000
        if context.streamStartsAtZero {
            offsetSeconds = 0
            if start > 0 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        } else {
            offsetSeconds = start
        }

        setUpCommands()
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = full.isEpisode
        publish(full)
        observe(player)
        player.play()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        await client.reportStart(context)
        return true
    }

    // MARK: Television

    /// Tunes a channel: the picture where the car shows one, otherwise the
    /// sound alone. False if the channel couldn't be had (every tuner in
    /// use, or a station whose sound nothing here plays).
    func playLive(_ channel: LiveChannel, among channels: [LiveChannel], client: MediaBrowserClient,
                  audioOnly: Bool) async -> Bool {
        guard Unlock.shared.mayPlay else { Unlock.shared.ask(); return false }
        await stop()
        // The newer broadcasts' sound (AC-4) can't be converted, and asking
        // for one held a tuner for nobody: asked about first.
        guard await client.livePlayable(channelId: channel.id) != false else { return false }
        // Anything left open by a player killed while it played, given back
        // first: it may be holding the tuner this needs.
        await LiveTuner.giveBackLeftover(on: client)
        let opened: LiveStream? = await LiveOpenLine.run { try? await client.openCarLiveStream(channelId: channel.id, audioOnly: audioOnly) }
        guard let stream = opened else { return false }
        // Written down until the server has heard it's let go (see LiveTuner).
        LiveTuner.note(stream, on: client)

        NotificationCenter.default.post(name: Self.willPlay, object: nil)
        MusicPlayer.shared.yield()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: audioOnly ? .spokenAudio : .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = AVPlayer(url: stream.url)
        player.allowsExternalPlayback = !drawsOwnPicture
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        self.player = player
        self.client = client
        self.audioOnly = audioOnly
        self.channel = channel
        self.channels = channels
        liveStream = stream
        offsetSeconds = 0

        setUpCommands()
        // What's on the air has no going back or on: the car's next and
        // previous buttons change channel instead.
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = channels.count > 1
        commands.previousTrackCommand.isEnabled = channels.count > 1
        publish(channel, client: client)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let stream = self.liveStream, let client = self.client else { return }
                await client.reportLive(stream, .playing)
            }
        }
        // A stream that stops coming (the tuner lost, the server gone) ends
        // here, the tuner let go.
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.stop() }
        }
        player.play()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        await client.reportLive(stream, .started)
        return true
    }

    /// Channel up or down, along the car's list.
    func changeChannel(by step: Int) async {
        guard let playing = channel, let client, let at = channels.firstIndex(where: { $0.id == playing.id }) else { return }
        let next = channels[(at + step + channels.count) % channels.count]
        _ = await playLive(next, among: channels, client: client, audioOnly: audioOnly)
    }

    var isLive: Bool { channel != nil }

    private func publish(_ channel: LiveChannel, client: MediaBrowserClient) {
        let station = [channel.number, channel.name].compactMap { $0 }.joined(separator: " ")
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: channel.now?.name ?? channel.name,
            MPMediaItemPropertyArtist: station,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: (audioOnly ? MPNowPlayingInfoMediaType.audio : .video).rawValue,
        ]
        if channel.now == nil { info[MPMediaItemPropertyArtist] = nil; info[MPMediaItemPropertyTitle] = station }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard let url = client.channelLogoURL(channel, maxWidth: 600) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data),
                  self.channel?.id == channel.id else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }

    /// Ends what's playing and tells the server where it got to; a channel's
    /// tuner is let go by the same report.
    func stop() async {
        if let stream = liveStream, let client {
            player?.pause()
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            timeObserver = nil
            endObserver = nil
            player = nil
            liveStream = nil
            channel = nil
            LiveTuner.letGo(stream)
            let commands = MPRemoteCommandCenter.shared()
            commands.skipBackwardCommand.isEnabled = true
            commands.skipForwardCommand.isEnabled = true
            commands.previousTrackCommand.isEnabled = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            if await client.reportLive(stream, .stopped) { LiveTuner.forget(stream) } else { LiveTuner.stopUnheard(stream) }
            return
        }
        guard let player, let context, let client else { return }
        let ticks = positionTicks
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        self.player = nil
        self.context = nil
        current = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        await client.reportStopped(context, positionTicks: ticks)
    }

    #if DEBUG
    /// Where it is, whether it's going, and what it fetched: for a test.
    var positionForTesting: Double { positionSeconds }
    var isPlayingForTesting: Bool { (player?.rate ?? 0) > 0 && player?.currentItem?.status == .readyToPlay }
    var streamForTesting: URL? { liveStream?.url ?? context?.url }
    var channelForTesting: String? { channel?.name }
    func pressNextForTesting() { Task { await changeChannel(by: 1) } }
    #endif

    // MARK: For the car's own screen

    /// The player, for the car's screen to draw its picture.
    var avPlayer: AVPlayer? { player }
    /// Where the film is, in its own time.
    var position: Double { positionSeconds }
    /// How long it runs; nil for a channel.
    var duration: Double? { isLive ? nil : current?.runTimeTicks.map { Double($0) / 10_000_000 } }
    var isPaused: Bool { (player?.rate ?? 0) == 0 }
    /// Something with an episode after it, for a Next button.
    var hasNext: Bool { isLive ? channels.count > 1 : current?.isEpisode == true }

    func togglePause() async {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
        updateElapsed()
        await report()
    }

    /// To `seconds` into the film. A stream the server began part-way
    /// through holds nothing before where it began: going back past that
    /// asks for a new one from there.
    func seek(to seconds: Double) async {
        guard let player, !isLive else { return }
        let target = max(0, seconds)
        if target < offsetSeconds, let current, let client {
            _ = await play(current, client: client, at: Int64(target * 10_000_000))
            return
        }
        await player.seek(to: CMTime(seconds: target - offsetSeconds, preferredTimescale: 600))
        updateElapsed()
    }

    /// The episode after this one, or the next channel.
    func next() async {
        if isLive { await changeChannel(by: 1) } else { await skipToNext() }
    }

    private var positionSeconds: Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return offsetSeconds }
        return seconds + offsetSeconds
    }

    private var positionTicks: Int64 { Int64(positionSeconds * 10_000_000) }

    private func observe(_ player: AVPlayer) {
        // The server hears every ten seconds, as it does from the app's own players.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.report() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.finished() }
        }
    }

    private func report() async {
        guard let player, let context, let client, !isLive else { return }
        updateElapsed()
        await client.reportProgress(context, positionTicks: positionTicks, paused: player.rate == 0)
    }

    // MARK: The next episode

    /// An episode ran to its end: on to the next, when the account's
    /// auto-play is on (as the app's own players do).
    private func finished() async {
        defer { if current == nil { NotificationCenter.default.post(name: Self.didFinish, object: nil) } }
        guard let ended = current, let client else { return await stop() }
        await stop()
        guard ended.isEpisode else { return }
        let configuration = (try? await client.userConfiguration()) ?? [:]
        guard configuration["EnableNextEpisodeAutoPlay"] as? Bool ?? true else { return }
        await playNext(after: ended, client: client)
    }

    /// The car's next-track button: the episode after this one, now.
    private func skipToNext() async {
        guard let playing = current, playing.isEpisode, let client else { return }
        await playNext(after: playing, client: client)
    }

    private func playNext(after episode: BaseItem, client: MediaBrowserClient) async {
        guard let next = try? await client.nextEpisode(after: episode) else { return }
        // From its start: a next episode that was once part-watched isn't
        // resumed half-way when it follows on.
        _ = await play(next, client: client, fromBeginning: true)
    }

    // MARK: Audio and subtitles

    /// The tracks `item` has and which are in use: the ones picked here, or
    /// the server's own choice for the account.
    func tracks(for item: BaseItem, client: MediaBrowserClient) async -> Tracks? {
        let full: BaseItem?
        if item.mediaSources?.first != nil {
            full = item
        } else if current?.id == item.id {
            full = current
        } else {
            full = try? await client.item(id: item.id)
        }
        guard let full, let source = full.mediaSources?.first else { return nil }
        let streams = source.mediaStreams ?? []
        let choice = choices[full.id]
        return Tracks(audio: streams.filter { $0.type == "Audio" },
                      subtitles: streams.filter { $0.type == "Subtitle" },
                      chosenAudio: choice?.audio ?? source.defaultAudioStreamIndex,
                      chosenSubtitle: choice?.subtitle ?? source.defaultSubtitleStreamIndex ?? PlaybackContext.subtitlesOff)
    }

    /// Picks an audio track or a subtitle for a title (nil leaves that one as
    /// it is). If the title is playing, it carries on from where it is with
    /// the new choice: the server makes a new stream, since the tracks are
    /// part of it.
    func choose(audio: Int? = nil, subtitle: Int? = nil, for itemId: String) async {
        var choice = choices[itemId] ?? (audio: nil, subtitle: nil)
        if let audio { choice.audio = audio }
        if let subtitle { choice.subtitle = subtitle }
        choices[itemId] = choice
        guard let playing = current, playing.id == itemId, let client else { return }
        _ = await play(playing, client: client, at: positionTicks)
    }

    // MARK: Now Playing

    private func publish(_ item: BaseItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: (audioOnly ? MPNowPlayingInfoMediaType.audio : .video).rawValue,
        ]
        if let show = item.seriesName { info[MPMediaItemPropertyArtist] = show }
        if let runtime = item.runTimeTicks { info[MPMediaItemPropertyPlaybackDuration] = Double(runtime) / 10_000_000 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard let url = client?.imageURL(for: item, type: "Primary", maxWidth: 600) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data),
                  self.context?.item.id == item.id else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
    }

    private func updateElapsed() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionSeconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = Double(player?.rate ?? 0)
    }

    /// Play, pause, the skips and the next episode, from the car's controls
    /// and the steering wheel.
    private func setUpCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.play(); await self?.report() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.pause(); await self?.report() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let player = self?.player else { return }
                if player.rate == 0 { player.play() } else { player.pause() }
                await self?.report()
            }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.skip(by: -10) }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [30]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.skip(by: 30) }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isLive == true { await self?.changeChannel(by: 1) } else { await self?.skipToNext() }
            }
            return .success
        }
        commands.previousTrackCommand.isEnabled = false
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.changeChannel(by: -1) }
            return .success
        }
    }

    func skip(by seconds: Double) async {
        guard player != nil else { return }
        await seek(to: positionSeconds + seconds)
    }
}
