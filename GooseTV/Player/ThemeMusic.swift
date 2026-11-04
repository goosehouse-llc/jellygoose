import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A show's or film's theme song, played quietly while its page is up, where
/// the server keeps one (Jellyfin's Theme Songs plugin finds them; a
/// `theme.mp3` beside the title does too). Faded in, faded out as the page
/// goes or a film starts, and carried on, not started again, from a show's
/// page to its episodes', which share it.
@MainActor
final class ThemeMusic {
    static let shared = ThemeMusic()

    static let key = "goosetv.themeMusic"
    /// On unless turned off, as the other apps that play them have it.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// How loud it gets: under anything said over it, as background.
    private static let level: Float = 0.3

    private var player: AVPlayer?
    /// The song playing, and the page that last asked for it.
    private var song: String?
    private var page: String?
    private var fading: Task<Void, Never>?
    private var asking: Task<Void, Never>?
    /// The sound session as it was before a song made it background's:
    /// given back as the song goes, or a film after it would be played as
    /// background too (the Apple TV's system player sets none of its own).
    #if !os(macOS)
    private var before: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    #endif

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// The page for `item` is up: its theme, if it has one.
    func play(for item: BaseItem, client: any MediaServer) {
        page = item.id
        // Not over a film still open (in its own window on a phone, say),
        // nor over what the car is playing.
        guard Self.enabled, SyncPlay.shared.playersOpen == 0, !MusicPlayer.shared.isPlaying else { return }
        #if os(iOS)
        guard CarPlayPlayer.shared.current == nil, CarPlayPlayer.shared.channel == nil else { return }
        #endif
        asking?.cancel()
        asking = Task {
            let songs = await client.themeSongs(of: item.id)
            guard !Task.isCancelled, page == item.id else { return }
            guard let first = songs.first, let url = client.songURL(itemId: first.id) else {
                // A page with none: whatever the last one's was stops.
                return fadeOut()
            }
            if first.id == song, player != nil { return fadeIn() }
            start(url, song: first.id)
        }
    }

    /// The page for `itemId` has gone. Not if another has asked since: a
    /// show's page giving way to an episode's keeps its song.
    func leave(_ itemId: String) {
        Task {
            // The next page asks as it appears, a moment after this one goes.
            try? await Task.sleep(for: .milliseconds(400))
            guard page == itemId else { return }
            page = nil
            fadeOut()
        }
    }

    /// Something else is to be heard (a film, a channel): out at once.
    func stop() {
        asking?.cancel()
        page = nil
        giveBackSession()
        fadeOut(over: 0.4)
    }

    private func start(_ url: URL, song id: String) {
        fading?.cancel()
        player?.pause()
        // Mixed with whatever else is playing on the device rather than
        // taking the sound from it: it's background.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        if before == nil { before = (session.category, session.mode, session.categoryOptions) }
        try? session.setCategory(.ambient)
        #endif
        let player = AVPlayer(url: url)
        player.volume = 0
        self.player = player
        song = id
        player.play()
        fadeIn()
    }

    private func fadeIn() {
        fade(to: Self.level, over: 2.5)
    }

    private func fadeOut(over seconds: Double = 1.2) {
        guard player != nil else { return }
        fade(to: 0, over: seconds) { [weak self] in
            self?.player?.pause()
            self?.player = nil
            self?.song = nil
            self?.giveBackSession()
        }
    }

    private func giveBackSession() {
        // A Mac has no sound session to give back: the song simply stops.
        #if !os(macOS)
        guard let before else { return }
        self.before = nil
        try? AVAudioSession.sharedInstance().setCategory(before.category, mode: before.mode, options: before.options)
        #endif
    }

    private func fade(to level: Float, over seconds: Double, then done: (() -> Void)? = nil) {
        fading?.cancel()
        guard let player else { return }
        let from = player.volume
        fading = Task {
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                if Task.isCancelled { return }
                player.volume = from + (level - from) * Float(step) / Float(steps)
            }
            done?()
        }
    }
}

/// A film's trailer: the one kept on the server, played here, or else the
/// one on YouTube, opened in the YouTube app (on an Apple TV, only where
/// it's installed).
enum Trailers {
    static func youTube(_ trailers: [RemoteTrailer]?) -> URL? {
        guard let id = trailers?.lazy.compactMap(\.youTubeId).first else { return nil }
        #if os(tvOS)
        guard let app = URL(string: "youtube://watch/\(id)"), UIApplication.shared.canOpenURL(app) else { return nil }
        return app
        #else
        // The YouTube app takes its own links where it's installed; Safari otherwise.
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
        #endif
    }

    static let title = String(localized: "Trailer", comment: "Button on a film's or show's page: plays its trailer")
}
