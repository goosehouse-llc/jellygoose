import Foundation

// Both servers send PascalCase keys; the decoder lowercases the first
// letter of every key, so these models need no CodingKeys boilerplate.

// MARK: - Auth

struct AuthenticationResult: Decodable {
    let user: JFUser
    let accessToken: String
}

struct JFUser: Decodable {
    let id: String
    let name: String
    var primaryImageTag: String? = nil
}

/// Someone the server lists on its own sign-in screen: every account not
/// marked hidden.
struct PublicUser: Decodable, Identifiable {
    let id: String
    let name: String
    let primaryImageTag: String?
}

struct PublicSystemInfo: Decodable {
    let serverName: String?
    let version: String?
    let id: String?
    /// "Jellyfin Server" or "Emby Server", which is how the app tells them apart.
    let productName: String?
}

struct QuickConnectResult: Decodable {
    let secret: String
    let code: String
    let authenticated: Bool
}

// MARK: - Items

struct ItemsResult: Decodable {
    let items: [BaseItem]
    let totalRecordCount: Int?
}

struct UserData: Decodable, Hashable {
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let played: Bool?
    let unplayedItemCount: Int?
    let isFavorite: Bool?
    /// The viewer's own "like" on it, which is where the app keeps its
    /// watchlist (see `MediaServer.setWatchlisted`).
    let likes: Bool?
    /// When it was last watched (ISO 8601), if it has been.
    let lastPlayedDate: String?
}

/// What a music library is listed by.
enum MusicKind: String, CaseIterable, Hashable {
    case albums, artists, songs
}

/// An artist or an album, as a song names it: an id to go to and a name.
struct NamedItem: Decodable, Hashable {
    let id: String
    let name: String?
}

/// A song's words, line by line, each from when it's sung where the server
/// knows (an .lrc file's times); unsynced words have no starts.
struct Lyrics: Decodable {
    struct Line: Decodable, Hashable {
        let text: String?
        /// Ticks from the song's start.
        let start: Int64?
    }
    let lyrics: [Line]

    var isSynced: Bool { lyrics.contains { ($0.start ?? 0) > 0 } }
}

/// A studio or network, as the server names and numbers it.
struct Studio: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey { case id, name }

    // Jellyfin sends the id as a string; Emby sends it as a number.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(Int64.self, forKey: .id))
        }
    }
}

struct Person: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let role: String?
    let type: String?
    let primaryImageTag: String?
}

extension Person {
    /// The people a search turned up, in the order someone typing the term
    /// most likely meant: a name that starts with it, then one with a word
    /// that does, then the rest; and within each, those with a photograph
    /// first, who are the ones a library has most of. The server's own order
    /// otherwise.
    static func ranked(_ people: [Person], for term: String, limit: Int = 24) -> [Person] {
        let term = term.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func rank(_ person: Person) -> Int {
            let name = (person.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let place = name.hasPrefix(term) ? 0
                : name.split(separator: " ").contains { $0.hasPrefix(term) } ? 2 : 4
            return place + (person.primaryImageTag == nil ? 1 : 0)
        }
        let named = people.filter { !($0.name ?? "").isEmpty }
        return Array(named.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .prefix(limit))
    }
}

/// Image-tag dictionary with case-insensitive lookup, because the decoder's
/// key strategy rewrites dictionary keys ("Primary" arrives as "primary").
struct ImageTags: Decodable {
    private let tags: [String: String]

    init(from decoder: Decoder) throws {
        let raw = try [String: String](from: decoder)
        tags = Dictionary(raw.map { ($0.key.lowercased(), $0.value) },
                          uniquingKeysWith: { first, _ in first })
    }

    subscript(type: String) -> String? { tags[type.lowercased()] }
}

struct BaseItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    /// The name as the server sorts it ("dark knight, the"), only sent when asked.
    let sortName: String?
    /// When it was added to the library (ISO 8601), only sent when asked.
    let dateCreated: String?
    /// On a show: when the newest of it was added. Only sent when asked.
    let dateLastMediaAdded: String?
    /// Where its file is on the server, only sent when asked.
    let path: String?
    /// How many things a collection or a playlist holds, only sent when asked.
    let childCount: Int?
    let type: String?
    let overview: String?
    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let officialRating: String?
    let communityRating: Double?
    let criticRating: Int?
    let genres: [String]?
    /// Who made it: a film's studios, a show's network.
    let studios: [Studio]?
    let userData: UserData?
    let imageTags: ImageTags?
    /// The shape of its own picture, width over height, only sent when asked.
    let primaryImageAspectRatio: Double?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemId: String?
    let parentLogoImageTag: String?
    let seriesPrimaryImageTag: String?
    let collectionType: String?
    let status: String?
    let taglines: [String]?
    let people: [Person]?
    /// The file(s) behind a movie or episode; only sent when fetching a single item.
    let mediaSources: [MediaSource]?
    /// The streams of what's playing, as a session's NowPlayingItem has them
    /// (the remote control's track lists); nil everywhere else.
    let mediaStreams: [MediaStream]?
    /// Trailers the server knows of on the internet (YouTube, nearly always),
    /// and how many it keeps as files beside the title.
    let remoteTrailers: [RemoteTrailer]?
    let localTrailerCount: Int?
    /// Also only on a single item, and only when the file had any.
    let chapters: [Chapter]?
    /// Scrubbing thumbnails, by media source id and then by width.
    let trickplay: [String: [String: TrickplayInfo]]?
    /// On a person: born and, if so, died (ISO 8601), and where they were born.
    let premiereDate: String?
    let endDate: String?
    let productionLocations: [String]?
    /// On a television channel: its number as the tuner has it, and what's
    /// on it now, where it was asked for and the server has listings.
    let channelNumber: String?
    let currentProgram: LiveProgramDTO?
    /// On a recording the server is still making: the timer it's made for,
    /// and the station it's from, by name.
    let timerId: String?
    let channelName: String?
    /// Music. A song's album, and who it's by: the album's artist (one name
    /// for a compilation's "Various Artists") and the song's own performers.
    /// An album has the artists too, and no album of its own.
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let albumArtists: [NamedItem]?
    let artistItems: [NamedItem]?
    let albumPrimaryImageTag: String?
    /// Whether the server holds the song's words (an .lrc beside it, or in its tags).
    let hasLyrics: Bool?
    /// "Audio", "Video": what a playlist holds, as the server sees it.
    let mediaType: String?
    /// The file's container, as the server names it ("flac", "mov,mp4,m4a,…").
    let container: String?
    /// A song's place in a playlist, as moving or removing it names it. Only
    /// on a playlist's own listing (`tracks(of:playlist:)`). Jellyfin 10.9
    /// and later make it the song's own id, so a song in a playlist twice has
    /// the same one in both places (see `PlaylistRow`).
    let playlistItemId: String?
    /// On a genre: how many albums and songs of it there are, where asked.
    let albumCount: Int?
    let songCount: Int?
    /// "FileSystem" for what's on the server, "Virtual" for an episode it
    /// only knows of from the listings (one not aired yet, say).
    let locationType: String?
    /// The folder it's in, where asked: a book in parts is its folder.
    let parentId: String?

    static func == (lhs: BaseItem, rhs: BaseItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// A television channel, which is tuned rather than played.
    var isLiveChannel: Bool { type == "TvChannel" }
    /// "6.1 · WKMG-DT".
    var liveChannelLine: String { [channelNumber, name].compactMap { $0 }.joined(separator: " · ") }

    var isEpisode: Bool { type == "Episode" }
    /// One thing to watch, with one file behind it: a film, an episode, a
    /// plain video, a recording. Not a show or a folder, with others under it.
    var isOneVideo: Bool { isMovie || isEpisode || type == "Video" || type == "MusicVideo" || type == "Recording" }
    var isSeries: Bool { type == "Series" }
    /// A recording the server hasn't finished making: the programme is
    /// still on. As it was when the item was fetched.
    var isBeingRecorded: Bool { status == "InProgress" && timerId != nil }

    /// When a recording was begun; for a show among the recordings, when
    /// the newest of it was. Nil where the server was asked nothing that
    /// says (see `Recorded`).
    var recordedAt: Date? { Recorded.date(of: self) }
    /// No picture of its own in the shape of a poster: none at all, or a
    /// frame the server took from the file, as it does of a recording.
    var lacksPoster: Bool { imageTags?["Primary"] == nil || (primaryImageAspectRatio ?? 0) > 1.2 }
    /// The programme a recording is of, as a guide would list it.
    var showName: String? { seriesName ?? name }
    var isMovie: Bool { type == "Movie" }
    /// Marked to be watched, and not watched yet: watching a film takes it
    /// off the watchlist.
    var onWatchlist: Bool { userData?.likes == true && userData?.played != true }
    /// Holds other items rather than being one: opening it lists what's inside,
    /// where opening a film plays it.
    var isContainer: Bool { type == "BoxSet" || type == "Playlist" }

    /// A song, an album, someone who made one.
    var isSong: Bool { type == "Audio" }
    var isAlbum: Bool { type == "MusicAlbum" }
    var isArtist: Bool { type == "MusicArtist" }
    /// A playlist of songs, which opens as an album does and plays in the
    /// music player, not the film player.
    var isSongPlaylist: Bool { type == "Playlist" && mediaType == "Audio" }
    /// Anything the music player plays, or is opened as music.
    var isMusic: Bool { isSong || isAlbum || isArtist || isSongPlaylist }
    /// A library of music.
    var holdsMusic: Bool { collectionType == "music" }
    /// One file of an audiobook: the whole book, or one of its parts.
    var isAudiobook: Bool { type == "AudioBook" }
    /// An audiobook's chapters: its chapter marks alone, not the other marks
    /// (an intro, credits) a server puts among them.
    var bookChapters: [Chapter] { (chapters ?? []).filter { $0.markerType == nil || $0.markerType == "Chapter" } }
    /// What the music player plays: a song, or an audiobook.
    var isPlayableAudio: Bool { isSong || isAudiobook }
    /// A library of books, of which the app shows the audiobooks.
    var holdsBooks: Bool { collectionType == "books" }
    /// Who a song or an album is by, in a line: a song's own performers
    /// where it has them ("The Geese feat. Gander" on a compilation), an
    /// album's artist ("Various Artists" for the compilation itself).
    var byLine: String? {
        let performers = (artistItems ?? []).compactMap(\.name).filter { !$0.isEmpty }
        if !isAlbum, !performers.isEmpty { return performers.joined(separator: ", ") }
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if !performers.isEmpty { return performers.joined(separator: ", ") }
        let artists = (albumArtists ?? []).compactMap(\.name)
        return artists.isEmpty ? nil : artists.joined(separator: ", ")
    }
    /// The album's own artist, to go to from it: the first named.
    var leadArtist: NamedItem? { albumArtists?.first ?? artistItems?.first }
    /// An episode the server knows of and hasn't got: one still to air,
    /// which there's nothing to play of.
    var isUpcoming: Bool { locationType == "Virtual" }
    /// When an episode airs, or a film came out, to the minute.
    var airDate: Date? { LiveDate.parse(premiereDate) }
    /// "3:07": a song's length.
    var songLength: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        let seconds = Int(ticks / 10_000_000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// One of the server's libraries. A library of mixed kinds has no kind
    /// to go by, only what it is.
    var isLibrary: Bool { collectionType != nil || type == "CollectionFolder" }
    /// A library of plain videos, home videos or music videos: no posters and
    /// no page of facts to them, so they're shown as wide stills that play
    /// when chosen, as episodes are.
    var holdsVideos: Bool { collectionType == "homevideos" || collectionType == "musicvideos" }

    /// What a library lists, as the server names the kinds. A mixed library
    /// has films and shows and whatever the server could put no name to.
    /// A library of recordings, listed a recording at a time: one the server
    /// has filed under a show (the guide numbered it) is a recording still,
    /// not a season of something.
    static let recordingTypes = "Movie,Episode,Video,Recording"

    var listedTypes: String {
        switch collectionType {
        case "homevideos": "Video"
        case "musicvideos": "MusicVideo"
        case "music": "MusicAlbum"
        case "books": "AudioBook"
        case nil where type == "CollectionFolder": "Movie,Series,Video,MusicVideo"
        default: "Movie,Series"
        }
    }

    /// A library's symbol, in the menu and on its tile.
    var librarySymbol: String {
        switch collectionType {
        case "movies": "film"
        case "homevideos": "video"
        case "musicvideos": "music.note.tv"
        case "music": "music.note"
        case "books": "books.vertical"
        case nil where type == "CollectionFolder": "rectangle.stack"
        default: "play.tv"
        }
    }

    /// "225 movies", "62 shows", "40 videos".
    func countText(_ count: Int) -> String {
        switch collectionType {
        case "movies": String(localized: "\(count) movies")
        case "tvshows": String(localized: "\(count) shows")
        case "homevideos", "musicvideos": String(localized: "\(count) videos")
        case "music": String(localized: "\(count) albums")
        case "books": String(localized: "\(count) audiobooks", comment: "How many audiobooks a library has")
        // A collection, a playlist, a library of mixed kinds.
        default: String(localized: "\(count) items")
        }
    }

    var displayTitle: String { name ?? String(localized: "Untitled", comment: "Shown for an item with no name") }

    /// "S1 · E4" style label for episodes.
    var episodeLabel: String? {
        guard isEpisode, let e = indexNumber else { return nil }
        if let s = parentIndexNumber { return String(localized: "S\(s) · E\(e)", comment: "Episode label: S = season number, E = episode number") }
        return String(localized: "E\(e)", comment: "Episode label without a season: E = episode number")
    }

    /// To the minute below. A clip shorter than one counts as one: a home
    /// video of twenty seconds isn't "0m" long.
    var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return max(1, Int(ticks / 600_000_000))
    }

    var progressFraction: Double? {
        guard let pct = userData?.playedPercentage, pct > 0, pct < 100 else { return nil }
        return pct / 100
    }

    var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }

    /// The day it first aired or came out, if the server knows.
    var premiereDay: Date? { Date(serverDay: premiereDate) }

    /// What a card should be called out loud. The artwork carries the title,
    /// the badge and the progress bar visually, and a card is a button with a
    /// picture in it, so without this the whole grid reads as "button".
    var spokenDescription: String {
        var parts: [String] = []
        if isEpisode {
            if let series = seriesName { parts.append(series) }
            if let season = parentIndexNumber, let episode = indexNumber {
                parts.append(String(localized: "season \(season), episode \(episode)", comment: "Spoken by VoiceOver for an episode card"))
            }
            parts.append(displayTitle)
        } else {
            parts.append(displayTitle)
            if let year = productionYear { parts.append("\(year)") }
        }
        if let percent = userData?.playedPercentage, percent > 0, percent < 100 {
            parts.append(String(localized: "\(Int(percent)) per cent watched", comment: "Spoken by VoiceOver for a part-watched card"))
        } else if userData?.played == true {
            parts.append(String(localized: "watched", comment: "Spoken by VoiceOver for a watched card"))
        }
        if isSeries, let unplayed = userData?.unplayedItemCount, unplayed > 0 {
            parts.append(String(localized: "\(unplayed) unwatched", comment: "Spoken by VoiceOver: number of unwatched episodes in a show"))
        }
        return parts.joined(separator: ", ")
    }
}

extension Date {
    /// The day in a date the server sends at a time of day in UTC, which
    /// read in a local time zone can land on the day before: midnight on
    /// that day here.
    init?(serverDay iso: String?) {
        guard let iso, iso.count >= 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        self = day
    }
}

// MARK: - Playback

struct PlaybackInfoResponse: Decodable {
    let mediaSources: [MediaSource]
    let playSessionId: String?
}

struct MediaSource: Decodable {
    let id: String?
    let name: String?
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let transcodingUrl: String?
    let runTimeTicks: Int64?
    let bitrate: Int?
    /// The file's size in bytes, which a download shows before it starts.
    let size: Int64?
    let mediaStreams: [MediaStream]?
    /// Which tracks the server would pick if it wasn't told. A subtitle default
    /// of nil means none, which is different from "not stated".
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    /// A television channel's stream, once the server has a tuner on it:
    /// what the server knows that by, to be told when it's done with.
    var liveStreamId: String? = nil
}

struct MediaStream: Decodable {
    /// The server's own numbering, which is what a stream url asks for by
    /// AudioStreamIndex / SubtitleStreamIndex.
    let index: Int?
    let type: String?
    let language: String?
    let title: String?
    let codec: String?
    let profile: String?
    let displayTitle: String?
    let height: Int?
    let width: Int?
    let bitDepth: Int?
    let realFrameRate: Double?
    let averageFrameRate: Double?
    /// "SDR", "HDR10", "HDR10Plus", "HLG", "DOVI", "DOVIWithHDR10", …
    let videoRangeType: String?
    let channels: Int?
    let isDefault: Bool?
    /// A subtitle only for what isn't in the film's own language (signs, a
    /// line in another language).
    let isForced: Bool?
    /// A subtitle kept in its own file beside the film rather than inside it.
    let isExternal: Bool?
    let isTextSubtitleStream: Bool?
    /// Where that file is on the server; nothing for a stream inside the film.
    let path: String?
    /// Bits a second, where the server knows the stream's own.
    let bitRate: Int?

    /// A subtitle file beside the film. Nothing in a direct-played stream
    /// carries it, so the server has to serve it: as a subtitle playlist in an
    /// HLS stream for AVPlayer, or as a file of its own for VLC.
    var isExternalTextSubtitle: Bool {
        type == "Subtitle" && isExternal == true && isTextSubtitleStream != false
    }

    /// A subtitle drawn as pictures inside the film (PGS, DVD, DVB), which
    /// AVPlayer can only show burnt into the video and VLC draws itself.
    var isEmbeddedPictureSubtitle: Bool {
        type == "Subtitle" && isExternal != true && isTextSubtitleStream == false
    }
}

extension MediaStream {
    /// What to call this track in the chooser. The server's own display title
    /// is the best of these — "English - Dolby TrueHD 7.1" — but it is not
    /// always sent, so a language and a codec stand in.
    var trackName: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        if let title, !title.isEmpty { return title }
        let parts = [language?.capitalized, codec?.uppercased()].compactMap { $0 }
        return parts.isEmpty ? "Track \(index ?? 0)" : parts.joined(separator: " · ")
    }
}

extension Array where Element == MediaStream {
    /// The streams inside the film's own file, in its order. The server
    /// numbers the subtitle files kept beside a film ahead of them, so its
    /// number for a stream inside is the file's own plus however many files
    /// there are; a player that reads the file counts from the file.
    private var inside: [MediaStream] {
        filter { $0.isExternal != true && $0.index != nil }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    /// The file's own number for the stream the server calls `index`.
    func fileStream(forServerIndex index: Int) -> Int? {
        inside.firstIndex { $0.index == index }
    }

    /// The stream the file numbers `number`, as the server lists it.
    func stream(atFileStream number: Int) -> MediaStream? {
        let inside = inside
        return inside.indices.contains(number) ? inside[number] : nil
    }
}

/// A subtitle a search of the internet turned up for a film, as the server
/// passes it on from whichever provider it asked (Open Subtitles, usually).
struct RemoteSubtitle: Decodable, Identifiable, Hashable {
    let id: String
    /// What it was uploaded as: most often the name of the release it was
    /// timed to, which is how one that fits a file is told from one that
    /// doesn't.
    let name: String?
    let providerName: String?
    let format: String?
    let comment: String?
    let downloadCount: Int?
    let communityRating: Double?
    /// Found by the file's own fingerprint: timed to this very file.
    let isHashMatch: Bool?
    let hearingImpaired: Bool?
    /// Only the lines in another language. Jellyfin and Emby spell it apart.
    let forced: Bool?
    let isForced: Bool?
    let aiTranslated: Bool?
    let machineTranslated: Bool?

    var onlyForeignParts: Bool { forced == true || isForced == true }
    var translatedByMachine: Bool { aiTranslated == true || machineTranslated == true }
}

/// A subtitle the server has just been given for the film that's playing, and
/// the film's subtitles as they stand with it there: a file beside a film is
/// numbered ahead of what's inside it, so every number may have moved.
struct FoundSubtitle {
    /// The server's number for the new one.
    let index: Int
    let name: String
    /// The file as it is, for a player that reads subtitle files itself.
    let file: URL
    /// The film's streams as the server numbers them now.
    let streams: [MediaStream]
    /// Every text subtitle as WebVTT in the film's time, by those numbers,
    /// for the player whose subtitles the app draws.
    let drawable: [Int: URL]
}

/// What the server says of a stream it is converting: which halves of it are
/// the file's own and which are new, and why it had to.
struct TranscodingInfo: Decodable, Equatable {
    let videoCodec: String?
    let audioCodec: String?
    let container: String?
    let isVideoDirect: Bool?
    let isAudioDirect: Bool?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let audioChannels: Int?
    /// "videotoolbox", "nvenc", "vaapi"…; nothing when the server's own
    /// processor is doing it.
    let hardwareAccelerationType: String?
    let reasons: [String]

    private enum CodingKeys: String, CodingKey {
        case videoCodec, audioCodec, container, isVideoDirect, isAudioDirect, bitrate, width, height
        case audioChannels, hardwareAccelerationType, transcodeReasons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoCodec = try? c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try? c.decodeIfPresent(String.self, forKey: .audioCodec)
        container = try? c.decodeIfPresent(String.self, forKey: .container)
        isVideoDirect = try? c.decodeIfPresent(Bool.self, forKey: .isVideoDirect)
        isAudioDirect = try? c.decodeIfPresent(Bool.self, forKey: .isAudioDirect)
        bitrate = try? c.decodeIfPresent(Int.self, forKey: .bitrate)
        width = try? c.decodeIfPresent(Int.self, forKey: .width)
        height = try? c.decodeIfPresent(Int.self, forKey: .height)
        audioChannels = try? c.decodeIfPresent(Int.self, forKey: .audioChannels)
        hardwareAccelerationType = try? c.decodeIfPresent(String.self, forKey: .hardwareAccelerationType)
        // A list on Jellyfin and Emby both; a comma'd string on older ones.
        if let list = try? c.decodeIfPresent([String].self, forKey: .transcodeReasons) {
            reasons = list
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .transcodeReasons) {
            reasons = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            reasons = []
        }
    }
}

/// The server's sessions, read for this device's own.
struct PlayingSession: Decodable {
    struct Item: Decodable { let id: String? }
    struct State: Decodable { let liveStreamId: String? }
    let deviceId: String?
    let nowPlayingItem: Item?
    let playState: State?
    let transcodingInfo: TranscodingInfo?
}

/// Jellyfin's scrubbing thumbnails at one width: sheets of `tileWidth` ×
/// `tileHeight` frames, one frame every `interval` milliseconds of film.
struct TrickplayInfo: Decodable, Hashable {
    let width: Int
    let height: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailCount: Int
    let interval: Int
}

/// The thumbnails for what's playing, and where each sheet of them is.
struct Trickplay {
    let info: TrickplayInfo
    let sheetURLs: [URL]

    /// Which sheet holds this moment.
    func sheetIndex(at seconds: Double) -> Int {
        let perSheet = max(info.tileWidth * info.tileHeight, 1)
        guard info.interval > 0 else { return 0 }
        return max(Int(seconds * 1000) / info.interval, 0) / perSheet
    }

    /// Which sheet holds the frame for this moment, and which cell of it.
    func frame(at seconds: Double) -> (sheet: URL, column: Int, row: Int)? {
        guard info.interval > 0, info.thumbnailCount > 0 else { return nil }
        let perSheet = info.tileWidth * info.tileHeight
        let index = min(max(Int(seconds * 1000) / info.interval, 0), info.thumbnailCount - 1)
        guard perSheet > 0, sheetURLs.indices.contains(index / perSheet) else { return nil }
        let cell = index % perSheet
        return (sheetURLs[index / perSheet], cell % info.tileWidth, cell / info.tileWidth)
    }
}

/// A subtitle file beside the film, where the player can fetch it.
struct SubtitleFile {
    let index: Int
    let name: String
    let url: URL
}

/// A named point in a film. Jellyfin extracts these from the file, or a plugin
/// writes them; either way they arrive with the item rather than in the stream,
/// which is why the player has to draw its own list.
struct Chapter: Decodable, Hashable {
    let name: String?
    let startPositionTicks: Int64?
    /// Emby lists its intro and credits marks among the chapters, with this
    /// to tell them apart ("IntroStart"); a chapter proper has "Chapter", or
    /// on Jellyfin nothing.
    var markerType: String? = nil

    var startSeconds: Double { Double(startPositionTicks ?? 0) / 10_000_000 }
}

// MARK: - Skippable segments

struct MediaSegmentsResult: Decodable {
    let items: [MediaSegmentDTO]
}

/// One stretch of an episode the server has marked: an intro, the credits, a
/// recap. Jellyfin 10.10 and later report these; the Intro Skipper plugin is
/// what usually fills them in.
struct MediaSegmentDTO: Decodable {
    let type: String?
    let startTicks: Int64?
    let endTicks: Int64?
}

/// What the Intro Skipper plugin answers with on its own endpoints, which is
/// where clients looked before Jellyfin had somewhere to put this. The spelling
/// has changed across plugin versions — Start/End in one, IntroStart/IntroEnd
/// in another — so every spelling seen in the wild is optional here and the
/// first pair that arrives is used.
struct PluginSegment: Decodable {
    let valid: Bool?
    let start: Double?
    let end: Double?
    let introStart: Double?
    let introEnd: Double?

    /// Seconds, or nil when the plugin looked and found nothing.
    var range: (start: Double, end: Double)? {
        guard valid != false else { return nil }
        guard let from = start ?? introStart, let to = end ?? introEnd, to > from else { return nil }
        return (from, to)
    }
}

/// A segment worth offering to skip, in seconds into the film.
/// A trailer somewhere on the internet, as the server's metadata found it.
struct RemoteTrailer: Decodable, Hashable {
    let url: String?
    let name: String?

    /// The YouTube video it is, where it is one.
    var youTubeId: String? {
        guard let url, let parts = URLComponents(string: url), let host = parts.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") { return parts.path.split(separator: "/").first.map(String.init) }
        guard host.contains("youtube") else { return nil }
        if let v = parts.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
        // /embed/ID and /shorts/ID
        let path = parts.path.split(separator: "/")
        return path.count >= 2 && ["embed", "shorts", "v"].contains(String(path[0])) ? String(path[1]) : nil
    }
}

struct SkipSegment: Equatable, Identifiable {
    /// The opening titles, the closing credits, and the advertisements in a
    /// recording made off the air: several of those to a programme. And an
    /// episode's "previously on" at its start, and the look at the next one
    /// at its end.
    enum Kind: String { case intro, outro, commercial, recap, preview }

    let kind: Kind
    let start: Double
    let end: Double
    /// Worked out from the shape of the chapters, or from a chapter's name
    /// that could as well be a scene's, rather than marked by the server:
    /// good enough to offer, not to act on.
    var guessed = false

    var id: String { "\(kind.rawValue)-\(start)" }
    var label: String {
        switch kind {
        case .intro: String(localized: "Skip Intro")
        case .outro: String(localized: "Skip Credits")
        case .commercial: String(localized: "Skip Commercials", comment: "Button over a recording: jumps past a commercial break the server has marked")
        case .recap: String(localized: "Skip Recap", comment: "Button over an episode: jumps past the \"previously on\" summary at its start")
        case .preview: String(localized: "Skip Preview", comment: "Button over an episode: jumps past the look at the next episode, near its end")
        }
    }

    /// Whether the film, at this second, is inside the segment. The last
    /// moment is excluded so skipping to the end doesn't re-offer the button.
    func contains(_ seconds: Double) -> Bool { seconds >= start && seconds < end - 0.5 }
}

extension Array where Element == Chapter {
    /// Intros and credits read from the chapters, for the many files that have
    /// "Intro" and "End Credits" marked in them and no plugin to say so. A
    /// guess, so it is only worth making when the server itself reported
    /// nothing. An episode's credits are also looked for where no name gives
    /// them away (see `unnamedCredits`).
    func inferredSkipSegments(runtimeSeconds: Double?, episode: Bool = false) -> [SkipSegment] {
        let intro = ["intro", "opening", "opening credits", "main title", "title sequence"]
        let recap = ["recap", "previously", "previously on"]
        let preview = ["preview", "next time", "next week", "next episode"]
        let outro = ["credit", "credits", "end credits", "end titles", "closing", "outro", "ending", "abspann"]

        // A recording run through a commercial detector may have its breaks
        // written into it as chapters, each named for what it is.
        let adverts = ["commercial", "commercials", "advertisement", "advertisements", "advert", "adverts", "ad break"]

        var found = enumerated().compactMap { index, chapter -> SkipSegment? in
            guard let name = chapter.name?.lowercased() else { return nil }
            if adverts.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
                // Marked on purpose by whatever found them, and by name: not
                // a guess. To the next chapter, or the end of the recording.
                let next = index + 1 < count ? self[index + 1].startSeconds : runtimeSeconds
                guard let end = next, end > chapter.startSeconds + 2 else { return nil }
                return SkipSegment(kind: .commercial, start: chapter.startSeconds, end: end)
            }
            // "Intro End" and "End of Credits" mark where one stops, not where
            // it starts.
            guard !name.hasSuffix(" end"), !name.hasPrefix("end of ") else { return nil }
            let kind: SkipSegment.Kind
            if intro.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
                kind = .intro
            } else if recap.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
                kind = .recap
            } else if preview.contains(where: { name == $0 || name.hasPrefix($0 + " ") }) {
                // At the end, like the credits: one earlier is a scene.
                if let runtimeSeconds, chapter.startSeconds < runtimeSeconds / 2 { return nil }
                kind = .preview
            } else if outro.contains(where: { name == $0 || name.hasSuffix(" " + $0) || name.hasPrefix($0) }) {
                // "After the Credits" and "Post-Credits Scene" are what the
                // credits get sat through for, not more of them.
                guard !["after", "post", "mid"].contains(where: name.hasPrefix) else { return nil }
                // And they're at the end. A chapter called "Credits" in the
                // first half is the opening titles under another name, or a
                // scene; skipped as credits it took the film's opening with
                // it and brought up what's next.
                if let runtimeSeconds, chapter.startSeconds < runtimeSeconds / 2 { return nil }
                kind = .outro
            } else {
                return nil
            }
            // It runs until the next chapter, or to the end of the film.
            let next = index + 1 < count ? self[index + 1].startSeconds : runtimeSeconds
            guard let end = next, end > chapter.startSeconds + 2 else { return nil }
            // A file that marks where its intro starts and nothing after it
            // would have the intro run through the episode, and Skip Intro
            // jump to the end of it. None is longer than four minutes.
            if kind == .intro || kind == .recap, end - chapter.startSeconds > 240 { return nil }
            // An episode's "Opening" is its titles and its "Ending" its
            // credits. A film's are as likely its first scene and its last,
            // so only what's called credits is sure enough to skip unasked.
            let sure = episode || (kind == .outro && (name.contains("credit") || name.contains("abspann")))
            return SkipSegment(kind: kind, start: chapter.startSeconds, end: end, guessed: !sure)
        }
        if episode, !found.contains(where: { $0.kind == .outro }),
           let credits = unnamedCredits(runtimeSeconds: runtimeSeconds),
           !found.contains(where: { $0.start == credits.start }) {
            found.append(credits)
        }
        return found
    }

    /// An episode's last chapter, when it has the look of the credits though
    /// nothing names it. Most episodes' chapters are numbered rather than
    /// named: one at each act break, and a last, short one where the credits
    /// begin. Short is from twenty seconds (any less and the player's own last
    /// twenty seconds serve as well) to two and a half minutes, and no more
    /// than a twelfth of the episode: a closing act runs longer. A last
    /// chapter with a name of its own ("Epilogue", "Preview") is what it says.
    ///
    /// Chapters at even intervals are the server's own, made for a file with
    /// none, and say nothing about what's in it. So are chapters on the five
    /// minutes with other marks among them, which is how Emby's come when it
    /// has found an intro.
    private func unnamedCredits(runtimeSeconds: Double?) -> SkipSegment? {
        let chapters = filter { $0.markerType == nil || $0.markerType == "Chapter" }
        guard chapters.count >= 3, let runtime = runtimeSeconds, let last = chapters.last else { return nil }
        let name = last.name?.trimmingCharacters(in: .whitespaces) ?? ""
        guard name.isEmpty || name.contains(where: \.isNumber) else { return nil }
        let starts = chapters.map(\.startSeconds)
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        guard let shortest = gaps.min(), let longest = gaps.max(), longest - shortest > 1 else { return nil }
        let onFiveMinutes = { (start: Double) in start > 0 && abs(start - (start / 300).rounded() * 300) < 0.5 }
        guard !(onFiveMinutes(last.startSeconds) && starts.dropLast().contains(where: onFiveMinutes)) else { return nil }
        let length = runtime - last.startSeconds
        guard length >= 20, length <= Swift.min(150, runtime / 12) else { return nil }
        return SkipSegment(kind: .outro, start: last.startSeconds, end: runtime, guessed: true)
    }
}

/// Which player engine plays a stream.
enum PlaybackEngine {
    /// AVPlayer: the system player, best for H.264/HEVC (HDR, Dolby Vision, frame-rate matching).
    case avPlayer
    /// VLC: for files AVPlayer can't decode, played as-is instead of transcoded.
    case vlc
    /// AetherEngine: the original file read on the device and handed to
    /// Apple's player, instead of the server converting it.
    case aether
}

/// What the player actually needs to start playback.
struct PlaybackContext {
    let url: URL
    let item: BaseItem
    let mediaSourceId: String?
    let playSessionId: String?
    let isDirect: Bool
    /// Where in the film to start.
    let startTicks: Int64
    /// Whether the stream itself begins at the start of the film. A transcode
    /// the server starts at an offset does not, and its clock has to have the
    /// offset added back; anything else does, and is seeked into instead.
    var streamStartsAtZero: Bool = true
    var engine: PlaybackEngine = .avPlayer
    /// Every track the source has, by the server's numbering. A transcode bakes
    /// in the one it was asked for, so changing track means asking again — these
    /// are what the choice is made from.
    var mediaStreams: [MediaStream] = []
    /// Which tracks this stream was asked for, nil meaning the server's default.
    /// A subtitle index of `PlaybackContext.subtitlesOff` asked for none.
    var audioIndex: Int?
    var subtitleIndex: Int?
    /// Subtitle files beside the film, for VLC to load alongside it, and which
    /// of them the server would pick.
    var subtitleFiles: [SubtitleFile] = []
    var defaultSubtitleIndex: Int?
    /// Thumbnails to show while scrubbing, when the server has made them.
    var trickplay: Trickplay?
    /// Subtitles the app draws over the picture itself, by the server's index,
    /// each as one WebVTT file in the film's time: every text subtitle for a
    /// transcode, just the files beside the film for a direct play. The one
    /// shown first is `subtitleIndex`.
    var drawableSubtitles: [Int: URL] = [:]

    /// The server's number for "no subtitles". Leaving the index out instead
    /// means "whatever the account's default is", which may well be some.
    static let subtitlesOff = -1
}

/// Words Jellyfin always sends in English because they're fixed values rather
/// than anyone's text: a person's part in a film and a show's status. Shown in
/// the viewer's language; anything not listed is shown as sent.
enum ServerWords {
    static func personType(_ type: String) -> String {
        switch type {
        case "Actor": String(localized: "Actor")
        case "Director": String(localized: "Director")
        case "Writer": String(localized: "Writer")
        case "Producer": String(localized: "Producer")
        case "GuestStar": String(localized: "Guest Star")
        case "Composer": String(localized: "Composer")
        case "Creator": String(localized: "Creator")
        case "Editor": String(localized: "Editor", comment: "A film's editor, the person")
        default: type
        }
    }

    static func seriesStatus(_ status: String) -> String {
        switch status {
        case "Continuing": String(localized: "Continuing", comment: "A TV show still making new episodes")
        case "Ended": String(localized: "Ended", comment: "A TV show that has finished")
        case "Unreleased": String(localized: "Unreleased")
        default: status
        }
    }
}
