import CarPlay
import Combine
import SwiftUI

/// JellyGoose drawn on the car's screen by the app itself, the way CarTV is.
///
/// In a car that can show an app's video, iOS opens the app's CarPlay lists
/// (`CarPlaySceneDelegate`) and the car puts up the picture itself. In one
/// that can't, which is most cars, iOS 27 opens a
/// CarPlay video app as a plain window on the car's screen instead, with
/// nothing in it unless the app draws something. This draws Home, the
/// libraries, Live TV and a search there (`CarScreen`), and plays the picture
/// in it.
///
/// The picture shows only while the car is parked, as Apple's own CarPlay
/// video does: while the car limits what its screen shows (driving), the
/// sound carries on and the picture waits.
final class CarScreenSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var model: CarScreenModel?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        CarPlayPlayer.shared.drawsOwnPicture = true
        let model = CarScreenModel()
        let host = UIHostingController(rootView: CarScreen(model: model))
        host.view.backgroundColor = .black
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
        self.model = model
        CarScreenModel.shared = model
    }

    /// The app's icon chosen on the car's screen again: what's in progress
    /// may have moved on since.
    func sceneWillEnterForeground(_ scene: UIScene) {
        model?.reload()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        CarPlayPlayer.shared.drawsOwnPicture = false
        // Nobody's watching a channel in a car that's gone, and it holds a
        // tuner: let go. (A film pauses on its own, the sound having nowhere
        // to go, and can be carried on.)
        model?.tuner.stop()
        window = nil
        model = nil
    }
}

extension UIWindowScene {
    /// The app's own screen in a car (see `CarScreenSceneDelegate`).
    var isCarScreen: Bool { session.role.rawValue == "UIWindowSceneSessionRoleCarPlay" }
}

/// What the car's screen shows and plays.
@MainActor
final class CarScreenModel: NSObject, ObservableObject, CPSessionConfigurationDelegate {
    /// The car's screen that's up, if any: a film started on the phone plays
    /// there (see `PlayerStage`), and keeps to its rule about driving.
    static weak var shared: CarScreenModel?

    enum Tab: Hashable { case home, music, liveTV, search }

    /// A screen gone into from a tab.
    enum Page: Hashable {
        /// A library's titles, or a collection's.
        case titles(BaseItem)
        /// A show's seasons and episodes, opened at a season if one's given.
        case show(id: String, name: String, season: String?)
        /// An album's songs, or a playlist's.
        case songs(BaseItem)
        /// A music library's albums, or someone's.
        case albums(BaseItem)
        /// A music library's artists.
        case artists(BaseItem)
    }

    /// A row of the Music tab: covers of albums or playlists, or songs.
    struct MusicShelf: Identifiable {
        let id: String
        let title: String
        let items: [BaseItem]
    }

    /// A row of Home: what's in progress, what's next, or a library's newest.
    struct Shelf: Identifiable {
        let id: String
        let title: String
        var detail: String?
        let items: [BaseItem]
        /// Wide stills (episodes, what's part-watched) rather than posters.
        let wide: Bool
        /// The library its header opens.
        let library: BaseItem?
    }

    /// What's playing, for the player and the bar along the foot of the screen.
    struct Playing: Equatable {
        let title: String
        let subtitle: String?
        let isLive: Bool
    }

    @Published var tab: Tab = .home { didSet { if tab != oldValue { pages = [] } } }
    @Published var pages: [Page] = []
    @Published var showsPlayer = false
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var channels: [LiveChannel] = []
    /// The account's music libraries, and the Music tab's rows from them.
    @Published private(set) var musicLibraries: [BaseItem] = []
    @Published private(set) var musicShelves: [MusicShelf] = []
    @Published private(set) var signedIn = true
    @Published private(set) var loaded = false
    /// The car limits its screen (it's moving): no picture.
    @Published private(set) var driving = false
    /// The channel on, played as the phone's Live TV plays one (`LiveTuner`):
    /// the tuner's stream as it comes, with VLC, which plays what a station
    /// sends. Apple's player needs the server to convert a channel first, and
    /// over the air that took longer than it would wait.
    let tuner = LiveTuner()
    @Published private(set) var liveChannel: LiveChannel?
    /// Something on its way to playing, named, while the server readies it.
    @Published private(set) var starting: String?
    /// A word on the screen for a moment: something that couldn't be played.
    @Published var notice: String?

    private(set) var client: MediaBrowserClient?
    private var carSession: CPSessionConfiguration?
    private var observers: [NSObjectProtocol] = []
    private var tunerWatch: AnyCancellable?
    private var musicWatch: AnyCancellable?

    override init() {
        super.init()
        let session = CPSessionConfiguration(delegate: self)
        carSession = session
        driving = !session.limitedUserInterfaces.isEmpty
        observers.append(NotificationCenter.default.addObserver(forName: CarPlayPlayer.didChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        })
        // Run to its end with nothing after it: back to where it was chosen.
        observers.append(NotificationCenter.default.addObserver(forName: CarPlayPlayer.didFinish, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showsPlayer = false }
        })
        tunerWatch = tuner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // The song playing, for the bar along the foot and the music's screen.
        musicWatch = MusicPlayer.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        reload()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        driving = !limitedUserInterfaces.isEmpty
    }

    // MARK: Home and Live TV

    /// The signed-in account's Home and channels, read the way the car's
    /// lists read them (`SharedSession`): the phone may be locked and the
    /// app's own window never opened.
    func reload() {
        guard let session = SharedSession.current() else {
            client = nil
            signedIn = false
            shelves = []
            channels = []
            return
        }
        signedIn = true
        let client = session.client
        self.client = client
        let hidden = session.hiddenNextUp
        Task {
            async let resume = try? client.resumeItems(limit: 16)
            async let next = try? client.nextUp(limit: 16)
            async let views = try? client.userViews()
            var made: [Shelf] = []
            if let items = await resume, !items.isEmpty {
                made.append(Shelf(id: "resume", title: String(localized: "Continue Watching"), items: items, wide: true, library: nil))
            }
            if let items = await next?.filter({ !hidden.contains($0.id) }), !items.isEmpty {
                made.append(Shelf(id: "next", title: String(localized: "Next Up"), items: items, wide: true, library: nil))
            }
            let all = await views ?? []
            loadMusic(all.filter(\.holdsMusic), from: client)
            let libraries = all.filter(Self.browsable)
            let kinds = libraries.map { ($0, Self.kind(of: $0)) }
            // Each library's newest, and how many it holds, all at once.
            let found = await withTaskGroup(of: (String, [BaseItem], Int?).self) { group in
                for (library, kind) in kinds {
                    group.addTask {
                        async let items = try? client.latest(in: library, limit: 16)
                        async let counted = try? client.libraryItems(parentId: library.id, limit: 0, itemTypes: kind)
                        return (library.id, await items ?? [], await counted?.totalRecordCount)
                    }
                }
                var found: [String: ([BaseItem], Int?)] = [:]
                for await (id, items, count) in group { found[id] = (items, count) }
                return found
            }
            for library in libraries {
                guard let (items, count) = found[library.id], !items.isEmpty else { continue }
                made.append(Shelf(id: library.id, title: library.displayTitle, detail: count.map(library.countText),
                                  items: items, wide: library.holdsVideos, library: library))
            }
            shelves = made
            loaded = true
        }
        Task {
            let all = (try? await client.liveChannels()) ?? []
            channels = all.filter(\.isFavorite) + all.filter { !$0.isFavorite }
        }
    }

    /// The Music tab: what was played last, the playlists of songs, and the
    /// albums added lately (the first music library's, where there are several).
    private func loadMusic(_ libraries: [BaseItem], from client: MediaBrowserClient) {
        musicLibraries = libraries
        guard let library = libraries.first else {
            musicShelves = []
            if tab == .music { tab = .home }
            return
        }
        Task {
            async let played = try? client.recentlyPlayedSongs(limit: 16)
            async let lists = try? client.collections(limit: 100)
            async let recent = try? client.latest(in: library.id, limit: 16, types: nil)
            var made: [MusicShelf] = []
            if let songs = await played, !songs.isEmpty {
                made.append(MusicShelf(id: "played", title: String(localized: "Recently Played", comment: "Music: the songs played last"), items: songs))
            }
            if let playlists = await lists?.filter(\.isSongPlaylist), !playlists.isEmpty {
                made.append(MusicShelf(id: "playlists", title: String(localized: "Playlists", comment: "Music library: the server's playlists of songs"), items: playlists))
            }
            if let albums = await recent, !albums.isEmpty {
                made.append(MusicShelf(id: "added", title: String(localized: "Recently Added"), items: albums))
            }
            musicShelves = made
        }
    }

    /// Libraries of things to watch: not music, books or photos, and not the
    /// server's Live TV, which has a tab of its own.
    private static func browsable(_ library: BaseItem) -> Bool {
        switch library.collectionType {
        case "movies", "tvshows", "homevideos", "musicvideos", "boxsets": true
        case nil: library.type == "CollectionFolder"
        default: false
        }
    }

    /// Films or shows, as the server calls them; or whatever else the
    /// library is of.
    static func kind(of library: BaseItem) -> String {
        switch library.collectionType {
        case "movies": "Movie"
        case "tvshows": "Series"
        case "boxsets": "BoxSet"
        default: library.listedTypes
        }
    }

    // MARK: Going places

    /// A title chosen: a show or a collection opens; anything else plays.
    func open(_ item: BaseItem) {
        if item.isAlbum || item.isSongPlaylist {
            pages.append(.songs(item))
        } else if item.isArtist {
            pages.append(.albums(item))
        } else if item.isSong {
            playMusic([item], source: item.album)
        } else if item.isSeries {
            pages.append(.show(id: item.id, name: item.displayTitle, season: nil))
        } else if item.type == "Season", let seriesId = item.seriesId {
            pages.append(.show(id: seriesId, name: item.seriesName ?? item.displayTitle, season: item.id))
        } else if item.isLibrary || ["BoxSet", "Folder", "Playlist"].contains(item.type ?? "") {
            pages.append(.titles(item))
        } else {
            play(item)
        }
    }

    func back() {
        if !pages.isEmpty { pages.removeLast() }
    }

    // MARK: Playing

    func play(_ item: BaseItem, fromBeginning: Bool = false) {
        guard let client else { return }
        guard Unlock.shared.mayPlay else { return askToUnlock() }
        starting = item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
        showsPlayer = true
        // A channel stops itself as this starts (see `LiveTuner`).
        liveChannel = nil
        Task {
            let started = await CarPlayPlayer.shared.play(item, client: client, fromBeginning: fromBeginning, audioOnly: false)
            starting = nil
            if !started {
                showsPlayer = false
                notice = String(localized: "Couldn't play this", comment: "Shown on the car's display when a title won't start")
            }
        }
    }

    func tune(_ channel: LiveChannel) {
        guard let client else { return }
        guard Unlock.shared.mayPlay else { return askToUnlock() }
        liveChannel = channel
        showsPlayer = true
        tuner.tune(to: channel.id, on: client)
    }

    /// Songs, from one of them, or in no order: music plays through the
    /// app's own player (`MusicPlayer`), the phone's and the car's as one.
    func playMusic(_ songs: [BaseItem], from start: Int = 0, shuffled: Bool = false, source: String?) {
        guard let client, !songs.isEmpty else { return }
        guard Unlock.shared.mayPlay else { return askToUnlock() }
        liveChannel = nil
        MusicPlayer.shared.play(songs, from: start, shuffled: shuffled, source: source, client: client)
        showsPlayer = true
    }

    /// The same, the songs asked for first: an album's, an artist's, a library's.
    func playMusic(source: String?, shuffled: Bool = false, songs: @escaping () async throws -> [BaseItem]) {
        guard let client else { return }
        guard Unlock.shared.mayPlay else { return askToUnlock() }
        liveChannel = nil
        MusicPlayer.shared.play(source: source, shuffled: shuffled, client: client, songs: songs)
        showsPlayer = true
    }

    /// Music is what's playing, rather than a film or a channel.
    var playsMusic: Bool { !isLive && CarPlayPlayer.shared.current == nil && MusicPlayer.shared.isActive }

    /// Playing needs the trial or the unlock (see `Unlock`), which is had
    /// on the phone: it's asked for there, and said so here.
    private func askToUnlock() {
        notice = CarScreenModel.lockedNotice
        Unlock.shared.ask()
    }

    static var lockedNotice: String {
        String(localized: "Start the free trial or unlock JellyGoose on your iPhone to play.",
               comment: "On the car's display: playing is locked until the trial is started or the app unlocked")
    }

    /// Channel up or down, along the Live TV tab's order.
    func changeChannel(by step: Int) {
        guard let on = liveChannel, let at = channels.firstIndex(where: { $0.id == on.id }), !channels.isEmpty else { return }
        tune(channels[(at + step + channels.count) % channels.count])
    }

    /// A channel is on (or being tuned), rather than a film.
    var isLive: Bool { liveChannel != nil && tuner.channelId != nil }

    /// What's playing, for the player and the bar along the foot.
    var playing: Playing? {
        if isLive, let channel = liveChannel {
            return Playing(title: channel.name, subtitle: channel.now?.name, isLive: true)
        }
        if playsMusic, let song = MusicPlayer.shared.current {
            return Playing(title: song.displayTitle, subtitle: song.byLine, isLive: false)
        }
        guard let item = CarPlayPlayer.shared.current else { return nil }
        return item.isEpisode
            ? Playing(title: item.seriesName ?? item.displayTitle,
                      subtitle: [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · "), isLive: false)
            : Playing(title: item.displayTitle, subtitle: nil, isLive: false)
    }

    /// Why a channel isn't playing, where it isn't.
    var liveTrouble: String? {
        guard isLive else { return nil }
        switch tuner.phase {
        case .refused: return String(localized: "Couldn't get this channel. Every tuner may be in use.",
                                     comment: "Live TV: the server had no stream to give for the channel")
        case .lost, .unanswered: return String(localized: "The channel stopped coming. Choose it again to retry.",
                                               comment: "On the car's display: a channel's stream stopped or never came")
        case .unplayable: return String(localized: "This channel's sound can't be played here.",
                                        comment: "On the car's display: a channel whose sound (AC-4) nothing in the app plays")
        default: return nil
        }
    }

    var isPaused: Bool {
        if playsMusic { return !MusicPlayer.shared.isPlaying && !MusicPlayer.shared.isWaiting }
        return isLive ? tuner.isPaused : CarPlayPlayer.shared.isPaused
    }

    func togglePause() {
        if playsMusic {
            MusicPlayer.shared.togglePause()
        } else if isLive {
            if tuner.isPaused { tuner.resume() } else { tuner.pause() }
        } else {
            Task { await CarPlayPlayer.shared.togglePause() }
        }
    }

    /// Lets the channel go, if one's on: a film started on the phone is
    /// coming to this screen.
    func stopChannel() {
        guard liveChannel != nil else { return }
        tuner.stop()
        liveChannel = nil
        showsPlayer = false
    }

    /// Stops whatever's playing and closes the player.
    func stop() {
        showsPlayer = false
        if playsMusic {
            MusicPlayer.shared.stop()
        } else if isLive || liveChannel != nil {
            tuner.stop()
            liveChannel = nil
        } else {
            Task { await CarPlayPlayer.shared.stop() }
        }
    }

    // MARK: Pictures

    func posterURL(_ item: BaseItem) -> URL? {
        client?.imageURL(for: item, type: "Primary", maxWidth: 360)
    }

    /// An album's, a playlist's, an artist's or a song's square picture.
    func coverURL(_ item: BaseItem, width: Int = 360) -> URL? {
        client?.imageURL(for: item, type: "Primary", maxWidth: width)
    }

    /// A wide still: an episode's own, or a film's backdrop.
    func wideURL(_ item: BaseItem) -> URL? {
        guard let client else { return nil }
        if item.isEpisode { return client.imageURL(for: item, type: "Primary", maxWidth: 480) }
        return client.imageURL(for: item, type: "Thumb", maxWidth: 480)
            ?? client.imageURL(for: item, type: "Backdrop", maxWidth: 480)
            ?? client.imageURL(for: item, type: "Primary", maxWidth: 480)
    }

    func logoURL(_ channel: LiveChannel) -> URL? {
        client?.channelLogoURL(channel, maxWidth: 240)
    }
}
