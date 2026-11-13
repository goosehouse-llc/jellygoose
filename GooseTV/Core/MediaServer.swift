import Foundation

/// Which server is on the other end. Jellyfin and Emby share an ancestor — Jellyfin
/// forked from Emby 3.5 — so one client speaks to both; the differences are the
/// authorization scheme, where the token goes, and which extras exist.
enum ServerFlavor: String, CaseIterable, Codable {
    case jellyfin
    case emby

    var label: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        }
    }

    /// The scheme word in the authorization header. Emby accepts the old
    /// "MediaBrowser" spelling too, but answers to its own name.
    var authScheme: String {
        switch self {
        case .jellyfin: return "MediaBrowser"
        case .emby: return "Emby"
        }
    }

    /// Jellyfin reads the access token out of the authorization header; Emby wants
    /// it in X-Emby-Token instead.
    var usesSeparateTokenHeader: Bool { self == .emby }

    /// Quick Connect is Jellyfin's. Emby has Emby Connect, which is a different
    /// thing entirely (an account service, not a code on a screen).
    var supportsQuickConnect: Bool { self == .jellyfin }

    /// What the server calls itself in /System/Info/Public.
    static func named(_ productName: String?) -> ServerFlavor? {
        guard let name = productName?.lowercased() else { return nil }
        if name.contains("emby") { return .emby }
        if name.contains("jellyfin") { return .jellyfin }
        return nil
    }
}

/// Everything the screens ask of a server. The app talks to this and never to a
/// concrete client, so another backend — Plex speaks nothing like these two — can
/// be added by writing one more conforming type.
protocol MediaServer: AnyObject {
    var baseURL: URL { get }
    var flavor: ServerFlavor { get }
    var token: String? { get }
    var userId: String? { get }
    /// Called when the server rejects the saved sign-in, so the app can return to login.
    var onUnauthorized: (() -> Void)? { get set }

    // Server / auth
    func publicInfo() async throws -> PublicSystemInfo
    func authenticate(username: String, password: String) async throws -> AuthenticationResult
    func quickConnectEnabled() async -> Bool
    func quickConnectInitiate() async throws -> QuickConnectResult
    func quickConnectState(secret: String) async throws -> QuickConnectResult
    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult
    /// Approves a Quick Connect code as the account signed in here: how the
    /// app signs the viewer in somewhere else that asks the server (Seerr).
    func authorizeQuickConnect(code: String) async throws -> Bool
    /// Ends the session on the server, so the token stops working there too.
    func logout() async

    // Browsing
    func userViews() async throws -> [BaseItem]
    func resumeItems(limit: Int) async throws -> [BaseItem]
    func nextUp(limit: Int) async throws -> [BaseItem]
    /// Everything favourited, across every library.
    func favorites(limit: Int) async throws -> [BaseItem]
    /// The films marked to be watched that haven't been yet, across every
    /// library.
    func watchlist(limit: Int) async throws -> [BaseItem]
    /// Collections and playlists, which hold items rather than being one.
    /// Each playlist says what it holds (see `withPlaylistTypes`).
    func collections(limit: Int) async throws -> [BaseItem]
    /// The same items, each playlist the server left unsaid told by what's
    /// in it.
    func withPlaylistTypes(_ items: [BaseItem]) async -> [BaseItem]
    func items(fromStudio studioId: String, limit: Int) async throws -> [BaseItem]
    func playQueue(for container: BaseItem, shuffled: Bool, limit: Int) async throws -> [BaseItem]
    func latest(in libraryId: String, limit: Int, types: String?) async throws -> [BaseItem]
    /// `nameLessThan` keeps only what sorts before it by name, which with a
    /// limit of 0 counts where a letter starts. `ids`, where there are any,
    /// keeps only those titles (the shows chosen in a TV library's filters).
    func libraryItems(parentId: String, startIndex: Int, limit: Int,
                      sortBy: String, sortOrder: String,
                      genres: [String], years: [Int], filters: [String],
                      itemTypes: String, nameLessThan: String?, ids: [String]) async throws -> ItemsResult
    /// These titles as they are now, in no particular order.
    func items(ids: [String]) async throws -> [BaseItem]
    func genres(in parentId: String) async throws -> [String]
    /// The years a library's titles came out, earliest first.
    func years(in parentId: String) async throws -> [Int]
    func item(id: String) async throws -> BaseItem
    func seasons(seriesId: String) async throws -> [BaseItem]
    /// The show's episode to carry on with: one part-watched, else Next Up.
    func nextEpisode(seriesId: String) async -> BaseItem?
    /// Extras kept beside an item: local trailers, deleted scenes, featurettes.
    func extras(for itemId: String) async -> [BaseItem]
    func episodes(seriesId: String, seasonId: String) async throws -> [BaseItem]
    func items(withPerson personId: String, limit: Int) async throws -> [BaseItem]
    func search(_ term: String) async throws -> [BaseItem]
    /// Collections and playlists by name.
    func searchCollections(_ term: String) async throws -> [BaseItem]
    /// Cast and crew by name, the likeliest first.
    func searchPeople(_ term: String) async throws -> [Person]
    func similar(to itemId: String, limit: Int) async throws -> [BaseItem]
    func nextEpisode(after episode: BaseItem) async throws -> BaseItem?
    /// The episodes after this one, in order across seasons, up to so many.
    func episodes(after episode: BaseItem, limit: Int) async -> [BaseItem]

    // Live TV
    /// How many channels this account can watch: none where the server has
    /// no tuner, or the account isn't let near it.
    func liveChannelCount() async throws -> Int
    /// The channels in the tuner's order, each with what's on it now where
    /// the server has a guide.
    func liveChannels() async throws -> [LiveChannel]
    /// The guide for these channels over a stretch of time: every programme
    /// any of it falls in, in no promised order.
    func liveGuide(channelIds: [String], from start: Date, to end: Date) async throws -> [LiveProgram]
    /// Where a programme's own picture is, if the listings came with one.
    /// The guide is asked for without them: there are hundreds of
    /// programmes in it and one is wanted at a time.
    func liveProgramPictureURL(programId: String, maxWidth: Int) async -> URL?
    /// Has the server put a tuner on the channel. Refused when it has none
    /// to spare.
    func openLiveStream(channelId: String) async throws -> LiveStream
    /// Whether the channel is one the app can play, by what the server says
    /// of it when asked to describe it and tune nothing. Nil where that
    /// can't be told.
    func livePlayable(channelId: String) async -> Bool?
    /// Told as a stream starts, every so often while it plays, and when it's
    /// done with: the last is what lets the tuner go.
    /// True if the server took the report.
    @discardableResult
    func reportLive(_ stream: LiveStream, _ event: LiveEvent) async -> Bool
    /// Whether the server still has this device on a live stream (by its
    /// name, or the channel): nil where it can't be asked.
    func stillWatching(liveStreamId: String, channelId: String?) async -> Bool?
    /// A film's file, to be read by the byte as this account: for a
    /// transport stream (a recording made off the air), whose own clock is
    /// the one thing that says where a moment in it lies (`TransportFile`).
    /// Nil where the server has no such thing to ask.
    func fileRequest(itemId: String) -> URLRequest?
    /// The libraries the server records into.
    func liveRecordingFolders() async -> Set<String>
    /// A library of recordings, all of it, each with what says when it was
    /// recorded (see `Recorded`): they're put in order by that here, which
    /// the server can't do.
    func recordings(in parentId: String, itemTypes: String, genres: [String], years: [Int], filters: [String]) async throws -> [BaseItem]
    /// A programme of that name in the listings that has a picture: the
    /// guide's own of it, which a recording comes without (it has none, or a
    /// frame of itself). Nil where the listings have none in the days they
    /// cover.
    func guideProgramme(named name: String) async -> BaseItem?
    /// Whether an item is among the server's recordings, in one of those
    /// libraries: nothing in the item itself says so once it's made. And the
    /// folder it's in, where that has a picture: the server keeps the
    /// programme's there as it records, and the recording has none itself.
    func recordingPlace(_ itemId: String, among folders: Set<String>) async -> (isRecording: Bool, pictured: BaseItem?)
    /// The recording the server is making for a timer this minute, to be
    /// read as it grows, with the channel it's from. Nil when it isn't
    /// making one, or hasn't got as far as listing it (the first half-minute).
    func liveRecording(timerId: String) async -> (recording: LiveRecording, channelId: String?)?
    /// Whether this account may set the server to record: whoever runs the
    /// server, and anyone it has let manage recordings.
    func liveCanRecord() async -> Bool
    /// Sets the server to record a programme, or every episode of the series
    /// it belongs to, by the server's own settings for a recording.
    func liveRecord(programId: String, series: Bool) async throws
    /// Takes a recording off. One that's under way stops, and what there is
    /// of it is kept.
    func liveCancelRecording(timerId: String) async throws
    /// Takes a series' recording off, and with it every episode still to come.
    func liveCancelSeries(timerId: String) async throws
    /// What the server is set to record: the showings in the order they
    /// come, and the series behind them.
    func liveScheduled() async throws -> (timers: [LiveTimer], series: [LiveSeriesTimer])
    /// Changes how a series is recorded.
    func liveSetSeries(timerId: String, _ options: LiveSeriesOptions) async throws
    /// The libraries the server keeps its recordings in, where this account
    /// may delete what's in them: none where it may not.
    func liveDeletableLibraries() async -> Set<String>
    /// Deletes an item from the server, its file with it.
    func deleteItem(_ id: String) async throws
    func channelLogoURL(_ channel: LiveChannel, maxWidth: Int) -> URL?
    /// The channels for Home's row of what's on, each with its programme:
    /// the one last watched first, then favourites, then the tuner's order,
    /// and no more than `limit` of them.
    func liveOnNow(first: String?, limit: Int) async throws -> [BaseItem]
    /// A show (or a film) in the library by its exact name, for what's on
    /// television: with its overview and pictures, to be shown as its own
    /// page would show it. Nil where there's none.
    func libraryTitle(named name: String, film: Bool) async -> BaseItem?
    /// The episodes of a series in the library, of one season or all, each
    /// with when it first aired.
    func libraryEpisodes(of seriesId: String, season: Int?) async -> [BaseItem]
    /// The showings to come of every programme whose name has these words
    /// in it, earliest first: what Search finds in the listings.
    func liveSearch(_ term: String) async throws -> [LiveListing]
    /// A showing's picture, where the listings came with one.
    func liveListingImageURL(_ listing: LiveListing, maxWidth: Int) -> URL?
    /// The picture of what's on a channel, where the listings gave one.
    func liveProgramImageURL(on channel: BaseItem, maxWidth: Int) -> URL?

    // Watching together (Jellyfin's SyncPlay)
    /// What this account may do about watching together: start groups and
    /// join them, only join, or neither (and on a server that hasn't it).
    func syncPlayAccess() async -> SyncPlayAccess
    /// The groups watching together on the server that this account may join.
    func syncPlayGroups() async throws -> [SyncPlayGroupInfo]
    /// Asks the group something: SyncPlay/New, Join, Leave, SetNewQueue,
    /// Pause, Unpause, Seek, Stop, Buffering, Ready, NextItem, Ping.
    func syncPlay(_ request: String, _ body: [String: Any]?) async throws
    /// The server's clock as it took a request and as it answered, to set
    /// this device's by.
    func serverClock() async throws -> (received: Date, sent: Date)
    /// A request for the server's own connection, over which it tells the
    /// group's members what to do. Nil where there's no token yet.
    func socketRequest() -> URLRequest?

    // Extras
    /// The trailers a film or show has as files on the server.
    func localTrailers(of itemId: String) async -> [BaseItem]
    /// The theme songs the server keeps for a title, or for the show it's in.
    func themeSongs(of itemId: String) async -> [BaseItem]
    /// A song's file as it is, to play.
    func songURL(itemId: String) -> URL?

    // Music
    /// A music library's albums, songs or album artists, a page at a time,
    /// counted. `sortBy` is the server's ("SortName", "DateCreated", …).
    func music(_ kind: MusicKind, in libraryId: String, startIndex: Int, limit: Int,
               sortBy: String, sortOrder: String) async throws -> ItemsResult
    /// An album's songs in its order (by disc, then track), or a playlist's in its own.
    func tracks(of containerId: String, playlist: Bool) async throws -> [BaseItem]
    /// The albums someone made, newest first; and those of others they're on.
    func albums(by artistId: String) async throws -> [BaseItem]
    func albums(featuring artistId: String) async throws -> [BaseItem]
    /// Everything someone sings on, album by album, or shuffled.
    func songs(by artistId: String, shuffled: Bool, limit: Int) async throws -> [BaseItem]
    /// A library's songs in no order, for Shuffle All.
    func shuffledSongs(in libraryId: String, limit: Int) async throws -> [BaseItem]
    /// Songs like this song, album or artist: the server's Instant Mix.
    func instantMix(from itemId: String, limit: Int) async throws -> [BaseItem]
    /// The songs this person played last, newest first; most often, most first.
    func recentlyPlayedSongs(limit: Int) async throws -> [BaseItem]
    func mostPlayedSongs(limit: Int) async throws -> [BaseItem]
    /// The albums of the songs this person played last, newest first, each once.
    func recentlyPlayedAlbums(limit: Int) async throws -> [BaseItem]
    /// The songs, albums or artists of a library this person has made favourites.
    func favoriteMusic(_ kind: MusicKind, in libraryId: String) async throws -> [BaseItem]
    /// A music library's genres, by name, each with how many albums and songs it has.
    func musicGenres(in libraryId: String) async throws -> [BaseItem]
    /// A genre's albums in a library, by name, a page at a time, counted.
    func albums(inGenre genreId: String, library libraryId: String, startIndex: Int, limit: Int) async throws -> ItemsResult
    /// A genre's songs in a library, shuffled, for playing the genre.
    func shuffledSongs(inGenre genreId: String, library libraryId: String, limit: Int) async throws -> [BaseItem]
    /// Someone's songs this person has played most, most first.
    func mostPlayedSongs(by artistId: String, limit: Int) async throws -> [BaseItem]
    /// Artists like this one, as the server finds them (by genre).
    func similarArtists(to artistId: String, limit: Int) async throws -> [BaseItem]

    // Audiobooks
    /// Every audiobook file in a library: whole books, and the parts of
    /// books in parts, each with the folder it's in.
    func audiobookFiles(in libraryId: String) async throws -> [BaseItem]
    /// A book's files in order, with their chapters: the one file, or the
    /// files in a folder (its own, not those of folders within it). `folder`
    /// says which it is when known; nil asks the server first.
    func audiobookParts(of bookId: String, folder: Bool?) async throws -> [BaseItem]
    /// The audiobook files part-way through, latest first.
    func resumeAudiobooks(limit: Int) async throws -> [BaseItem]

    // Playlists (of songs, or of films and episodes) and collections
    /// The playlists this account has of one kind ("Audio" or "Video"), by name.
    func playlists(mediaType: String) async throws -> [BaseItem]
    /// Makes a playlist of that kind with these in it; its id.
    func createPlaylist(named name: String, items ids: [String], mediaType: String) async throws -> String
    /// Puts songs, films or episodes at the end of a playlist (a show or a
    /// season, all its episodes).
    func addToPlaylist(_ playlistId: String, songs songIds: [String]) async throws
    /// Takes these out of a playlist, wherever they are in it, by their own ids.
    func removeFromPlaylist(_ playlistId: String, itemIds: [String]) async throws
    /// The server's collections, by name.
    func boxSets() async throws -> [BaseItem]
    /// Makes a collection with these in it; its id.
    func createCollection(named name: String, items ids: [String]) async throws -> String
    func addToCollection(_ collectionId: String, items ids: [String]) async throws
    func removeFromCollection(_ collectionId: String, items ids: [String]) async throws
    /// Whether this account may make and change collections: one that runs
    /// the server, or (Jellyfin 10.9 and later) one allowed to.
    func canManageCollections() async -> Bool
    /// Episodes of the shows in the library still to air, soonest first.
    func upcomingEpisodes(limit: Int) async throws -> [BaseItem]
    /// A show's episodes from the next to watch on, unwatched and on the
    /// server, as many as asked.
    func episodesToWatch(seriesId: String, limit: Int) async -> [BaseItem]
    /// Takes songs out of a playlist, by their places in it (`playlistItemId`).
    func removeFromPlaylist(_ playlistId: String, entries: [String]) async throws
    /// Moves a song in a playlist, by its place in it, to `index` (from 0).
    func movePlaylistEntry(_ playlistId: String, entry: String, to index: Int) async throws
    /// Gives a playlist a new name.
    func renamePlaylist(_ playlistId: String, to name: String) async throws
    /// Whether this account may change the playlist: its own, or one shared
    /// with it to edit.
    func canEditPlaylist(_ playlistId: String) async -> Bool
    /// The artists, albums and songs the words turn up.
    func searchMusic(_ term: String) async throws -> (artists: [BaseItem], albums: [BaseItem], songs: [BaseItem])
    /// The audiobook files the words turn up, to be made into books.
    func searchAudiobooks(_ term: String) async throws -> [BaseItem]
    /// A song's words, where the server has them (Jellyfin 10.9 and later).
    func lyrics(of songId: String) async -> Lyrics?
    /// How to play a song: its file as it is where Apple's player takes the
    /// kind, else the server's AAC of it.
    func songStream(_ song: BaseItem) -> PlaybackContext?

    /// The newest recordings in a library of them, each its own: the
    /// server's "latest" puts a show's under the show.
    func recentRecordings(in libraryId: String, limit: Int) async throws -> [BaseItem]

    // Playing on another device (Jellyfin's remote control)
    /// Tells the server what this device can be asked to do from another:
    /// play video, change its tracks; or, `controllable` false, nothing.
    func reportCapabilities(controllable: Bool) async
    /// The other devices this account can play on: sessions that take
    /// commands and play video, as recently heard from.
    func controllableSessions() async throws -> [RemoteSession]
    /// Plays these on that session, the first from `startTicks`.
    func play(_ itemIds: [String], on session: String, startTicks: Int64?) async throws
    /// Pause, Unpause, PlayPause, Stop, Seek (with `seekTicks`), and the rest
    /// of the server's playstate commands, on that session.
    func playstate(_ command: String, on session: String, seekTicks: Int64?) async throws
    /// One of the server's general commands, SetAudioStreamIndex say, on that session.
    func command(_ name: String, on session: String, arguments: [String: String]) async throws
    /// This device's id, as the server knows it: a session that's this one.
    var deviceId: String { get }

    // Images
    func imageURL(for item: BaseItem, type: String, maxWidth: Int) -> URL?
    func personImageURL(_ person: Person, maxWidth: Int) -> URL?
    func userImageURL(userId: String, tag: String?) -> URL?
    func publicUsers() async -> [PublicUser]

    // Watched / favourite / resume
    func setPlayed(_ itemId: String, _ played: Bool) async throws
    func setFavorite(_ itemId: String, _ favorite: Bool) async throws
    /// Puts a film on the viewer's watchlist, or takes it off. Neither
    /// server has a watchlist, so it's kept as the viewer's "like" on the
    /// film: a mark of their own that the server keeps for them, that goes
    /// with them from device to device, and that nothing else here uses.
    func setWatchlisted(_ itemId: String, _ listed: Bool) async throws
    func clearResumePosition(_ itemId: String) async throws

    // Account preferences
    /// The account's own settings, and what the server lets it do: run the
    /// server, and look for subtitles on the internet for what's in it.
    func userDetails() async throws -> (configuration: [String: Any], isAdministrator: Bool, findsSubtitles: Bool)
    /// Who the token belongs to: name and picture.
    func signedInUser() async throws -> JFUser
    func userConfiguration() async throws -> [String: Any]
    func saveUserConfiguration(_ configuration: [String: Any]) async throws

    // Library administration
    func libraries() async throws -> [VirtualFolder]
    func addLibrary(name: String, kind: LibraryKind, folders: [String]) async throws
    func removeLibrary(name: String) async throws
    func renameLibrary(_ name: String, to newName: String) async throws
    func addFolder(_ path: String, toLibrary name: String) async throws
    func removeFolder(_ path: String, fromLibrary name: String) async throws
    func scanLibraries() async throws
    func refreshMetadata(itemId: String, replacingExisting: Bool) async throws
    func serverTasks() async throws -> [ServerTask]
    func serverFolders(at path: String?) async throws -> [FileSystemEntry]

    // Plugin administration (Jellyfin)
    func serverPlugins() async throws -> [ServerPlugin]
    func pluginCatalog() async throws -> [PluginPackage]
    func installPlugin(_ package: PluginPackage, release: PluginRelease) async throws
    func setPlugin(_ plugin: ServerPlugin, on: Bool) async throws
    func uninstallPlugin(_ plugin: ServerPlugin) async throws
    func serverRestartState() async throws -> ServerRestartState
    func restartServer() async throws
    func itemCount(inLibrary parentId: String, types: String) async throws -> Int

    /// Intros and credits the server has marked, so the player can offer to
    /// skip them. Empty when the server doesn't know of any.
    func skipSegments(for itemId: String) async -> [SkipSegment]

    /// Subtitles for a film that the server's providers find on the internet,
    /// in one language (ISO 639-2, "eng"). None when it has no provider that
    /// answers, which reads the same as nothing being found.
    func remoteSubtitles(for itemId: String, language: String) async throws -> [RemoteSubtitle]
    /// Has the server fetch one of them and keep it with the film. The film's
    /// streams list it a moment later, once the server has looked again.
    func downloadRemoteSubtitle(_ subtitleId: String, for itemId: String) async throws
    /// What the server says of the stream it's converting for this device,
    /// if it is converting one of this film: which parts are the file's own,
    /// and why not the rest.
    func transcoding(of itemId: String) async -> TranscodingInfo?
    /// A film's subtitles as the server lists them now, and where each can be
    /// fetched: for one added while the film plays.
    func subtitles(of item: BaseItem, mediaSourceId: String?) -> (streams: [MediaStream], files: [SubtitleFile], drawable: [Int: URL])

    // Playback
    /// Resolves a stream. The track indexes are the server's own numbering; nil
    /// takes whatever it would choose itself.
    func playbackContext(for item: BaseItem, startTicks: Int64,
                         audioIndex: Int?, subtitleIndex: Int?,
                         mediaSourceId: String?) async throws -> PlaybackContext
    /// Gets the server going on the stream before the player asks for it.
    /// Returns once the first piece is ready, or after a few seconds regardless.
    func warmUp(_ ctx: PlaybackContext) async
    func reportStart(_ ctx: PlaybackContext) async
    /// Where the film has got to, whether it's paused, and which tracks are on
    /// by the server's numbering (nil where the player can't say), which a
    /// remote shows.
    func reportProgress(_ ctx: PlaybackContext, positionTicks: Int64, paused: Bool, audioIndex: Int?, subtitleIndex: Int?) async
    func reportStopped(_ ctx: PlaybackContext, positionTicks: Int64) async
}

/// The shorthands the screens actually call. Protocol requirements can't carry
/// default arguments, so the defaults live here instead.
extension MediaServer {
    func audiobookParts(of bookId: String) async throws -> [BaseItem] {
        try await audiobookParts(of: bookId, folder: nil)
    }

    func resumeItems() async throws -> [BaseItem] { try await resumeItems(limit: 12) }
    func nextUp() async throws -> [BaseItem] { try await nextUp(limit: 12) }
    func favorites() async throws -> [BaseItem] { try await favorites(limit: 200) }
    func watchlist() async throws -> [BaseItem] { try await watchlist(limit: 200) }
    func collections() async throws -> [BaseItem] { try await collections(limit: 200) }
    /// The Collections section's: collections and playlists of films and
    /// episodes. Playlists of songs are music's, under its Playlists.
    func videoCollections() async throws -> [BaseItem] {
        try await collections(limit: 200).filter { !$0.isSongPlaylist }
    }
    func reportProgress(_ ctx: PlaybackContext, positionTicks: Int64, paused: Bool) async {
        await reportProgress(ctx, positionTicks: positionTicks, paused: paused, audioIndex: nil, subtitleIndex: nil)
    }
    func items(fromStudio studioId: String) async throws -> [BaseItem] { try await items(fromStudio: studioId, limit: 200) }
    func playQueue(for container: BaseItem, shuffled: Bool) async throws -> [BaseItem] {
        try await playQueue(for: container, shuffled: shuffled, limit: 300)
    }
    /// A library's newest. A library of home videos keeps photographs too,
    /// and the server's newest would have those among them, so there (and
    /// for music videos) it's asked for what the library lists.
    func latest(in library: BaseItem, limit: Int = 16) async throws -> [BaseItem] {
        try await latest(in: library.id, limit: limit, types: library.holdsVideos ? library.listedTypes : nil)
    }
    func similar(to itemId: String) async throws -> [BaseItem] { try await similar(to: itemId, limit: 16) }
    func songPlaylists() async throws -> [BaseItem] { try await playlists(mediaType: "Audio") }
    func createPlaylist(named name: String, songs songIds: [String]) async throws -> String {
        try await createPlaylist(named: name, items: songIds, mediaType: "Audio")
    }
    func items(withPerson personId: String) async throws -> [BaseItem] {
        try await items(withPerson: personId, limit: 100)
    }

    func libraryItems(parentId: String, limit: Int, itemTypes: String = "Movie,Series") async throws -> ItemsResult {
        try await libraryItems(parentId: parentId, startIndex: 0, limit: limit,
                               sortBy: "SortName", sortOrder: "Ascending",
                               genres: [], years: [], filters: [], itemTypes: itemTypes, nameLessThan: nil, ids: [])
    }

    func libraryItems(parentId: String, startIndex: Int, limit: Int,
                      sortBy: String, sortOrder: String,
                      genres: [String], years: [Int], filters: [String],
                      itemTypes: String, nameLessThan: String?) async throws -> ItemsResult {
        try await libraryItems(parentId: parentId, startIndex: startIndex, limit: limit,
                               sortBy: sortBy, sortOrder: sortOrder, genres: genres, years: years, filters: filters,
                               itemTypes: itemTypes, nameLessThan: nameLessThan, ids: [])
    }

    func imageURL(for item: BaseItem, maxWidth: Int) -> URL? {
        imageURL(for: item, type: "Primary", maxWidth: maxWidth)
    }

    func personImageURL(_ person: Person) -> URL? { personImageURL(person, maxWidth: 300) }

    func playbackContext(for item: BaseItem, startTicks: Int64) async throws -> PlaybackContext {
        try await playbackContext(for: item, startTicks: startTicks,
                                  audioIndex: nil, subtitleIndex: nil, mediaSourceId: nil)
    }
}

/// What an account may do about watching together.
enum SyncPlayAccess: Equatable {
    case none, join, create
}

/// Another device signed in to the server, as the remote control sees it:
/// what it's called, whose it is, and what it's playing.
struct RemoteSession: Decodable, Identifiable {
    let id: String
    let deviceName: String?
    let deviceId: String?
    let client: String?
    let userName: String?
    let supportsRemoteControl: Bool?
    let playableMediaTypes: [String]?
    let nowPlayingItem: BaseItem?
    let playState: PlayState?
    /// When the device last said where it was in what's playing.
    let lastPlaybackCheckIn: String?

    /// That as a date. The server writes seven places of a second, more than
    /// the formatter reads, so the fraction goes.
    var checkedIn: Date? {
        guard var text = lastPlaybackCheckIn else { return nil }
        if let dot = text.firstIndex(of: "."),
           let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber }) {
            text.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    struct PlayState: Decodable {
        let positionTicks: Int64?
        let isPaused: Bool?
        let audioStreamIndex: Int?
        let subtitleStreamIndex: Int?
    }

    /// Takes commands and plays video: somewhere to send a film.
    var takesVideo: Bool {
        supportsRemoteControl == true && (playableMediaTypes ?? []).contains("Video")
    }
}

/// A group watching together, as the server lists it.
struct SyncPlayGroupInfo: Decodable, Identifiable, Equatable {
    let groupId: String
    let groupName: String?
    /// Idle, Waiting, Paused or Playing.
    let state: String?
    /// Who's in it, by name.
    let participants: [String]?

    var id: String { groupId }
}
