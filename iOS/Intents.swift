import AppIntents
import UIKit

// Siri and Shortcuts: "Continue watching in JellyGoose", "Play The Office in
// JellyGoose", "Listen to Pond Life in JellyGoose", "Shuffle my music in
// JellyGoose". In CarPlay too, where the music ones play without the phone
// being touched. The session is read as the widgets read it (SharedSession),
// so a request needs nothing of the app's screens.

/// Why a request couldn't be done, as Siri says it.
enum IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    case signedOut, nothingToPlay, noMusic

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Open JellyGoose and sign in first."
        case .nothingToPlay: "There's nothing to carry on with."
        case .noMusic: "There's no music on your server."
        }
    }
}

enum IntentSession {
    static func client() throws -> MediaBrowserClient {
        guard let client = SharedSession.current()?.client else { throw IntentProblem.signedOut }
        return client
    }

    /// Hands the app something to open or play, as a link from the shelf
    /// or a widget would: Home takes it from there.
    @MainActor
    static func open(_ url: URL) async {
        if let app = AppState.current {
            app.open(url: url)
        } else {
            await UIApplication.shared.open(url)
        }
    }
}

// MARK: - Films and shows

/// A film or a show, as Siri and Shortcuts name one.
struct VideoEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Film or Show")
    static let defaultQuery = VideoQuery()

    let id: String
    let title: String
    let detail: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: detail.map { "\($0)" })
    }

    init(_ item: BaseItem) {
        id = item.isEpisode ? (item.seriesId ?? item.id) : item.id
        title = item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
        detail = item.productionYear.map(String.init)
    }
}

struct VideoQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [VideoEntity] {
        try await IntentSession.client().items(ids: identifiers).map(VideoEntity.init)
    }

    func entities(matching string: String) async throws -> [VideoEntity] {
        try await IntentSession.client().search(string).filter { $0.isMovie || $0.isSeries }.prefix(12).map(VideoEntity.init)
    }

    /// What's being watched: what Siri offers first, and the titles the
    /// phrases with a name in them are learnt for.
    func suggestedEntities() async throws -> [VideoEntity] {
        let client = try IntentSession.client()
        async let resuming = try? client.resumeItems(limit: 10)
        async let next = try? client.nextUp(limit: 10)
        var seen = Set<String>()
        return ((await resuming ?? []) + (await next ?? [])).map(VideoEntity.init).filter { seen.insert($0.id).inserted }
    }
}

/// Plays a film, or the next episode of a show.
struct PlayVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Film or Show"
    static let description = IntentDescription("Plays a film, or the next episode of a show, in JellyGoose.")
    static let openAppWhenRun = true

    @Parameter(title: "Film or Show")
    var item: VideoEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$item)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try IntentSession.client()
        await IntentSession.open(DeepLink.play(item.id))
        return .result()
    }
}

/// Carries on with what was being watched last, or else the next episode
/// of a show.
struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Carries on with what you were watching in JellyGoose.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let client = try IntentSession.client()
        let resuming = (try? await client.resumeItems(limit: 1)) ?? []
        let next = resuming.isEmpty ? ((try? await client.nextUp(limit: 1)) ?? []) : []
        guard let item = (resuming + next).first else { throw IntentProblem.nothingToPlay }
        await IntentSession.open(DeepLink.play(item.id))
        return .result()
    }
}

// MARK: - Music

/// An artist, an album, a playlist of songs or a song.
struct MusicEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music")
    static let defaultQuery = MusicQuery()

    let id: String
    let title: String
    let detail: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: detail.map { "\($0)" })
    }

    init(_ item: BaseItem) {
        id = item.id
        title = item.displayTitle
        detail = item.isArtist ? nil : item.byLine
    }
}

struct MusicQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MusicEntity] {
        try await IntentSession.client().items(ids: identifiers).map(MusicEntity.init)
    }

    func entities(matching string: String) async throws -> [MusicEntity] {
        let found = try await IntentSession.client().searchMusic(string)
        return (found.artists.prefix(4) + found.albums.prefix(6) + found.songs.prefix(4)).map(MusicEntity.init)
    }

    func suggestedEntities() async throws -> [MusicEntity] {
        try await IntentSession.client().recentlyPlayedAlbums(limit: 10).map(MusicEntity.init)
    }
}

/// Plays music by name, here or in the car, without opening the app.
struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays an artist, an album, a playlist or a song in JellyGoose.")

    @Parameter(title: "Music")
    var music: MusicEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$music)") { \.$shuffle } }

    @MainActor
    func perform() async throws -> some IntentResult {
        let client = try IntentSession.client()
        let item = try await client.item(id: music.id)
        MusicPlayer.shared.play(source: item.isSong ? item.album : item.displayTitle, shuffled: shuffle, client: client,
                                songs: MusicMenu.songs(of: item, client: client))
        return .result()
    }
}

/// Every music library's songs in no order.
struct ShuffleMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle My Music"
    static let description = IntentDescription("Plays all your music in JellyGoose in no order.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let client = try IntentSession.client()
        let libraries = try await client.userViews().filter(\.holdsMusic)
        guard !libraries.isEmpty else { throw IntentProblem.noMusic }
        let share = max(300 / libraries.count, 50)
        MusicPlayer.shared.play(source: String(localized: "Shuffle All", comment: "Plays a whole music library in no order"),
                                shuffled: true, client: client) {
            var songs: [BaseItem] = []
            for library in libraries { songs += (try? await client.shuffledSongs(in: library.id, limit: share)) ?? [] }
            return songs.shuffled()
        }
        return .result()
    }
}

// MARK: - What Siri knows to listen for

struct JellyGooseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueWatchingIntent(),
                    phrases: ["Continue watching in \(.applicationName)",
                              "Resume watching in \(.applicationName)"],
                    shortTitle: "Continue Watching", systemImageName: "play.circle")
        AppShortcut(intent: PlayVideoIntent(),
                    phrases: ["Watch \(\.$item) in \(.applicationName)",
                              "Play \(\.$item) in \(.applicationName)",
                              "Watch something in \(.applicationName)"],
                    shortTitle: "Play a Film or Show", systemImageName: "film")
        AppShortcut(intent: PlayMusicIntent(),
                    phrases: ["Listen to \(\.$music) in \(.applicationName)",
                              "Play music in \(.applicationName)"],
                    shortTitle: "Play Music", systemImageName: "music.note")
        AppShortcut(intent: ShuffleMusicIntent(),
                    phrases: ["Shuffle my music in \(.applicationName)",
                              "Shuffle music in \(.applicationName)"],
                    shortTitle: "Shuffle My Music", systemImageName: "shuffle")
    }
}
