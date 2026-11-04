import Foundation

// Seerr (Jellyseerr and Overseerr, as they were) is where the people who use
// a server ask for what it doesn't have: a film or a show is found there and
// requested, and the server's owner (or Seerr itself) has it fetched. It runs
// beside the media server, and signs people in with their media server
// accounts. This is the app's side of it: finding what could be asked for,
// asking, and seeing what's been asked.

/// A film or a show as Seerr lists it, by its number at The Movie Database.
struct SeerrTitle: Decodable, Identifiable, Hashable {
    let tmdbId: Int
    /// "movie" or "tv" ("person" too, in a search, which is left out).
    let mediaType: String
    private let title: String?
    private let name: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    private let releaseDate: String?
    private let firstAirDate: String?
    let voteAverage: Double?
    let mediaInfo: SeerrMedia?

    enum CodingKeys: String, CodingKey {
        case tmdbId = "id", mediaType, title, name, posterPath, backdropPath, overview
        case releaseDate, firstAirDate, voteAverage, mediaInfo
    }

    var id: String { "\(mediaType)-\(tmdbId)" }
    var isMovie: Bool { mediaType == "movie" }
    var displayTitle: String { title ?? name ?? "" }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }

    // The same title with a different standing isn't equal: a card whose
    // title compares equal isn't drawn again, and would go on showing a film
    // as not asked for after it had been.
    static func == (lhs: SeerrTitle, rhs: SeerrTitle) -> Bool {
        lhs.id == rhs.id && lhs.mediaInfo?.status == rhs.mediaInfo?.status && lhs.mediaInfo?.status4k == rhs.mediaInfo?.status4k
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What Seerr knows of a title's place in the library and its requests.
struct SeerrMedia: Decodable {
    let tmdbId: Int?
    let mediaType: String?
    let status: Int?
    let status4k: Int?
    /// The title on the media server, once it's there, and its 4K copy.
    let jellyfinMediaId: String?
    let jellyfinMediaId4k: String?
    let seasons: [SeerrSeasonState]?
    let requests: [SeerrRequest]?

    func availability(in4K: Bool = false) -> SeerrAvailability { SeerrAvailability(in4K ? status4k : status) }
    var availability: SeerrAvailability { availability() }
}

struct SeerrSeasonState: Decodable {
    let seasonNumber: Int
    let status: Int?
    /// On a title's own record, where the season's 4K copy stands.
    let status4k: Int?
}

/// A standing said the way Seerr says it: a word or two on a colour.
struct SeerrBadge: Equatable {
    enum Tone { case good, working, waiting, bad }
    let text: String
    let symbol: String
    let tone: Tone

    /// The mark alone, for the corner of a card, as Seerr's small badges
    /// have them: a tick for what's there, a dash for part of it, a clock
    /// for what's on its way, a bell for what waits on someone.
    var mark: String {
        switch (tone, symbol) {
        case (.good, "circle.lefthalf.filled"): "minus"
        case (.good, _): "checkmark"
        case (.working, _): "clock"
        case (.waiting, _): "bell.fill"
        case (.bad, "xmark.circle.fill"): "xmark"
        case (.bad, _): "exclamationmark"
        }
    }
}

/// Where a title stands: Seerr's numbers, 1 to 6.
enum SeerrAvailability: Equatable {
    /// Not in the library and not asked for.
    case unasked
    /// Asked for, and waiting for someone to say yes.
    case awaitingApproval
    /// Approved, and being fetched.
    case requested
    /// A show with some of its seasons there.
    case partlyAvailable
    case available

    init(_ status: Int?) {
        switch status {
        case 2: self = .awaitingApproval
        case 3: self = .requested
        case 4: self = .partlyAvailable
        case 5: self = .available
        // 1 is a title Seerr has only heard of. Past 5 are ones taken out
        // of the library or barred from being asked for: Seerr says which
        // when it's asked.
        default: self = .unasked
        }
    }

    /// Nothing for a title that hasn't been asked for.
    var label: String? {
        switch self {
        case .unasked: nil
        case .awaitingApproval: String(localized: "Awaiting Approval", comment: "A requested title that the server's owner hasn't approved yet")
        case .requested: String(localized: "Requested", comment: "A requested title that is being fetched")
        case .partlyAvailable: String(localized: "Partly Available", comment: "A show with some of its seasons in the library")
        case .available: String(localized: "In Your Library", comment: "A title that is already in the library")
        }
    }

    var symbol: String? {
        switch self {
        case .unasked: nil
        case .awaitingApproval, .requested: "clock.fill"
        case .partlyAvailable: "circle.lefthalf.filled"
        case .available: "checkmark.circle.fill"
        }
    }

    var badge: SeerrBadge? {
        guard let label, let symbol else { return nil }
        let tone: SeerrBadge.Tone = switch self {
        case .awaitingApproval: .waiting
        case .requested, .unasked: .working
        case .partlyAvailable, .available: .good
        }
        return SeerrBadge(text: label, symbol: symbol, tone: tone)
    }
}

/// A title in full, for its page. Read leniently: whatever of it Seerr hands
/// over in a shape that isn't expected is gone without, and the page still opens.
struct SeerrDetails: Decodable {
    let tmdbId: Int
    let displayTitle: String
    let overview: String?
    let tagline: String?
    let posterPath: String?
    let backdropPath: String?
    /// The day a film came out, or a show was first on: "2026-12-18".
    let released: String?
    let runtime: Int?
    let voteAverage: Double?
    let genres: [String]
    let seasons: [Season]
    let tvdbId: Int?
    let mediaInfo: SeerrMedia?
    let cast: [Credit]
    let directors: [String]
    let creators: [String]
    /// A film's studios, or the networks a show is on.
    let makers: [String]
    /// The age rating where the viewer is, or America's.
    let certification: String?
    /// The language it was made in, and the countries it's from, as codes.
    let originalLanguage: String?
    let countries: [String]

    struct Season: Decodable {
        let seasonNumber: Int
        let name: String?
        let episodeCount: Int?
    }

    /// Someone in it, and who they play.
    struct Credit: Decodable, Identifiable {
        let id: Int
        let name: String
        let character: String?
        let profilePath: String?
    }

    private struct Named: Decodable { let name: String }
    private struct Country: Decodable {
        let code: String
        enum CodingKeys: String, CodingKey { case code = "iso_3166_1" }
    }
    private struct Crew: Decodable {
        let name: String
        let job: String?
    }
    private struct Credits: Decodable {
        let cast: [Credit]?
        let crew: [Crew]?
    }
    private struct ExternalIds: Decodable { let tvdbId: Int? }
    private struct Releases: Decodable {
        let results: [Country]?
        struct Country: Decodable {
            let country: String
            let dates: [Dated]?
            enum CodingKeys: String, CodingKey { case country = "iso_3166_1", dates = "release_dates" }
        }
        struct Dated: Decodable { let certification: String? }
    }
    private struct ContentRatings: Decodable {
        let results: [Country]?
        struct Country: Decodable {
            let country: String
            let rating: String?
            enum CodingKeys: String, CodingKey { case country = "iso_3166_1", rating }
        }
    }

    private enum Keys: String, CodingKey {
        case id, title, name, overview, tagline, posterPath, backdropPath, releaseDate, firstAirDate, runtime
        case voteAverage, genres, seasons, externalIds, mediaInfo, credits, createdBy, networks
        case productionCompanies, releases, contentRatings, originalLanguage, productionCountries
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        func read<T: Decodable>(_ key: Keys, as type: T.Type = T.self) -> T? { try? box.decode(T.self, forKey: key) }
        func filled(_ key: Keys) -> String? { read(key, as: String.self).flatMap { $0.isEmpty ? nil : $0 } }
        tmdbId = try box.decode(Int.self, forKey: .id)
        displayTitle = filled(.title) ?? filled(.name) ?? ""
        overview = filled(.overview)
        tagline = filled(.tagline)
        posterPath = filled(.posterPath)
        backdropPath = filled(.backdropPath)
        released = filled(.releaseDate) ?? filled(.firstAirDate)
        runtime = read(.runtime)
        voteAverage = read(.voteAverage)
        genres = (read(.genres, as: [Named].self) ?? []).map(\.name)
        seasons = read(.seasons) ?? []
        tvdbId = read(.externalIds, as: ExternalIds.self)?.tvdbId
        mediaInfo = read(.mediaInfo)
        let credits = read(.credits, as: Credits.self)
        cast = credits?.cast ?? []
        directors = (credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
        creators = (read(.createdBy, as: [Named].self) ?? []).map(\.name)
        // A show's networks, one name each: the same one is listed per country.
        let named = (read(.networks, as: [Named].self) ?? read(.productionCompanies, as: [Named].self) ?? []).map(\.name)
        makers = named.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let here = Locale.current.region?.identifier ?? "US"
        let films = read(.releases, as: Releases.self)?.results ?? []
        let shows = read(.contentRatings, as: ContentRatings.self)?.results ?? []
        func rating(in country: String) -> String? {
            films.first { $0.country == country }?.dates?.compactMap(\.certification).first { !$0.isEmpty }
                ?? shows.first { $0.country == country }?.rating.flatMap { $0.isEmpty ? nil : $0 }
        }
        certification = rating(in: here) ?? rating(in: "US")
        originalLanguage = filled(.originalLanguage)
        countries = (read(.productionCountries, as: [Country].self) ?? []).map(\.code)
    }

    var year: String? { released.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }

    /// The day it came out, as the viewer writes dates.
    var releasedText: String? {
        guard let released else { return nil }
        let reader = DateFormatter()
        reader.calendar = Calendar(identifier: .gregorian)
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(identifier: "UTC")
        reader.dateFormat = "yyyy-MM-dd"
        guard let day = reader.date(from: String(released.prefix(10))) else { return nil }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return day.formatted(style)
    }

    /// The seasons there are to ask for. The specials (season 0) only where
    /// Seerr is set to take requests for them.
    func seasons(specials: Bool) -> [Season] {
        seasons.filter { $0.seasonNumber > 0 || specials }
    }

    /// Where a season stands, in one quality: in the library, or asked for in
    /// a request that's still open. Of a request's numbers, 1 is waiting for
    /// a yes, 2 approved, and 4 approved but not yet handed on; declined (3)
    /// and done with (5) leave the season free to be asked for again.
    func standing(ofSeason season: Int, in4K: Bool) -> SeerrAvailability {
        let state = mediaInfo?.seasons?.first { $0.seasonNumber == season }
        let there = SeerrAvailability(in4K ? state?.status4k : state?.status)
        if there != .unasked { return there }
        let open = (mediaInfo?.requests ?? []).filter { request in
            request.open && (request.is4k == true) == in4K && (request.seasons ?? []).contains { $0.seasonNumber == season }
        }
        if open.contains(where: { !$0.waiting }) { return .requested }
        return open.isEmpty ? .unasked : .awaitingApproval
    }

    func askableSeasons(in4K: Bool, specials: Bool) -> [Int] {
        seasons(specials: specials).map(\.seasonNumber).filter { standing(ofSeason: $0, in4K: in4K) == .unasked }
    }
}

/// What the critics and everyone else made of a title, where Seerr knows.
struct SeerrRatings {
    var critics: Int?
    var audience: Int?
    var imdb: Double?
}

/// Something that's been asked for.
struct SeerrRequest: Decodable, Identifiable {
    let id: Int
    /// 1 waiting for a yes, 2 approved, 3 declined, 4 approved but not handed
    /// on to be fetched (failed), 5 done with.
    let status: Int
    let is4k: Bool?
    let createdAt: String?
    let media: SeerrMedia?
    let seasons: [SeerrSeasonState]?
    let requestedBy: SeerrRequester?

    var waiting: Bool { status == 1 }
    var failed: Bool { status == 4 }
    /// Neither declined nor done with.
    var open: Bool { status == 1 || status == 2 || status == 4 }

    /// As Seerr's own list of requests says it: the request's standing until
    /// it's approved, and the title's from then on.
    var badge: SeerrBadge {
        switch status {
        case 1: return SeerrAvailability.awaitingApproval.badge!
        case 3: return SeerrBadge(text: String(localized: "Declined", comment: "A request the server's owner said no to"),
                                  symbol: "xmark.circle.fill", tone: .bad)
        case 4: return SeerrBadge(text: String(localized: "Failed", comment: "An approved request that couldn't be handed on to be fetched"),
                                  symbol: "exclamationmark.triangle.fill", tone: .bad)
        case 5: return SeerrAvailability.available.badge!
        default:
            let there = media?.availability(in4K: is4k == true) ?? .unasked
            return (there == .available || there == .partlyAvailable ? there.badge : nil) ?? SeerrAvailability.requested.badge!
        }
    }

    /// When it was asked for.
    var asked: Date? {
        guard let createdAt else { return nil }
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return reader.date(from: createdAt)
    }
}

/// Who asked.
struct SeerrRequester: Decodable {
    let id: Int
    let displayName: String?
    let avatar: String?
}

struct SeerrUser: Decodable {
    let id: Int
    let permissions: Int
    let displayName: String?
    let jellyfinUsername: String?
    /// Who this is on the media server.
    let jellyfinUserId: String?

    // Seerr's permissions are bits, and an administrator (2) has them all.
    private func may(_ permission: Int) -> Bool {
        #if DEBUG
        // For looking at what a manager sees, in a test: Seerr still refuses
        // what the account may not do.
        if ProcessInfo.processInfo.environment["GOOSETV_SEERR_ALL"] != nil { return true }
        #endif
        return permissions & 2 != 0 || permissions & permission != 0
    }

    /// 16: approves, declines and deletes anyone's requests.
    var managesRequests: Bool { may(16) }
    /// 16384 sees what everyone has asked for; someone who manages them does too.
    var seesAllRequests: Bool { may(16) || may(16_384) }
    /// 8192 chooses the server, quality and folder a request goes to.
    var setsRequestOptions: Bool { may(16) || may(8192) }
    /// 1024 asks for anything in 4K, 2048 films and 4096 shows.
    func requestsIn4K(movie: Bool) -> Bool { may(1024) || may(movie ? 2048 : 4096) }
    /// Whether what they ask for needs no one's yes: 128 anything, 256 films,
    /// 512 shows, and 32768, 65536 and 131072 the same in 4K. A manager's
    /// own are approved as they're made.
    func approvedAtOnce(movie: Bool, in4K: Bool) -> Bool {
        may(16) || (in4K ? may(32_768) || may(movie ? 65_536 : 131_072) : may(128) || may(movie ? 256 : 512))
    }
}

/// Where a request can be sent: one of the Radarrs or Sonarrs Seerr knows.
struct SeerrService: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let is4k: Bool?
    let isDefault: Bool?
    /// The folder and quality a request gets there unless told otherwise.
    let activeDirectory: String?
    let activeProfileId: Int?
}

/// What can be chosen for a request sent to one of them.
struct SeerrServiceOptions: Decodable {
    let profiles: [Profile]
    let rootFolders: [Folder]

    struct Profile: Decodable, Identifiable {
        let id: Int
        let name: String
    }
    struct Folder: Decodable, Identifiable {
        let id: Int
        let path: String
        let freeSpace: Double?
    }
}

/// What a request says beyond which title: left nil, Seerr's own choice.
struct SeerrRequestOptions {
    var serverId: Int?
    var profileId: Int?
    var rootFolder: String?
}

/// How many requests someone may still make, where they're rationed.
struct SeerrQuota: Decodable {
    let movie: Allowance?
    let tv: Allowance?

    struct Allowance: Decodable {
        let limit: Int?
        let remaining: Int?
    }
}

/// A genre as Seerr's Discover lists them, with pictures from titles of it.
struct SeerrGenre: Decodable, Identifiable {
    let id: Int
    let name: String
    let backdrops: [String]?

    /// The picture Seerr puts on a genre's card: the fifth it's given.
    var picture: String? {
        guard let backdrops, !backdrops.isEmpty else { return nil }
        return backdrops.indices.contains(4) ? backdrops[4] : backdrops[0]
    }

    /// The two colours Seerr washes the genre's picture in, dark and light:
    /// its own table, by the genre's number at The Movie Database.
    var tones: (dark: String, light: String) {
        switch id {
        case 28, 10_770: ("991B1B", "FCA5A5")                    // Action, TV Movie
        case 12, 10_759: ("480c8b", "a96bef")                    // Adventure
        case 16, 10_402, 10_762: ("032541", "01b4e4")            // Animation, Music, Kids
        case 35, 36, 37: ("92400E", "FCD34D")                    // Comedy, History, Western
        case 80: ("1F2937", "2864d2")                            // Crime
        case 99, 10_767: ("065F46", "6EE7B7")                    // Documentary, Talk
        case 18, 10_749, 10_766: ("9D174D", "F9A8D4")            // Drama, Romance, Soap
        case 10_751: ("777e0d", "e4ed55")                        // Family
        case 14, 878, 10_765: ("1F2937", "60A5FA")               // Fantasy, Science Fiction
        case 9648: ("5B21B6", "C4B5FD")                          // Mystery
        case 10_752, 10_768: ("1F2937", "F87171")                // War
        case 10_764: ("552c01", "d47c1d")                        // Reality
        default: ("1F2937", "D1D5DB")                            // Horror, Thriller, News, the rest
        }
    }
}

/// A film studio or a television network, for Discover's rows of them: the
/// ones Seerr's own Discover lists, by their numbers at The Movie Database
/// and with the logos it has for them.
struct SeerrCompany: Identifiable, Hashable {
    let id: Int
    let name: String
    let logo: String

    static let studios = [
        SeerrCompany(id: 2, name: "Disney", logo: "/wdrCwmRnLFJhEoH8GSfymY85KHT.png"),
        SeerrCompany(id: 127_928, name: "20th Century Studios", logo: "/h0rjX5vjW5r8yEnUBStFarjcLT4.png"),
        SeerrCompany(id: 34, name: "Sony Pictures", logo: "/GagSvqWlyPdkFHMfQ3pNq6ix9P.png"),
        SeerrCompany(id: 174, name: "Warner Bros. Pictures", logo: "/ky0xOc5OrhzkZ1N6KyUxacfQsCk.png"),
        SeerrCompany(id: 33, name: "Universal", logo: "/8lvHyhjr8oUKOOy2dKXoALWKdp0.png"),
        SeerrCompany(id: 4, name: "Paramount", logo: "/fycMZt242LVjagMByZOLUGbCvv3.png"),
        SeerrCompany(id: 3, name: "Pixar", logo: "/1TjvGVDMYsj6JBxOAkUHpPEwLf7.png"),
        SeerrCompany(id: 521, name: "DreamWorks", logo: "/kP7t6RwGz2AvvTkvnI1uteEwHet.png"),
        SeerrCompany(id: 420, name: "Marvel Studios", logo: "/hUzeosd33nzE5MCNsZxCGEKTXaQ.png"),
        SeerrCompany(id: 9993, name: "DC", logo: "/2Tc1P3Ac8M479naPp1kYT3izLS5.png"),
        SeerrCompany(id: 41_077, name: "A24", logo: "/1ZXsGaFPgrgS6ZZGS37AqD5uU12.png"),
    ]

    static let networks = [
        SeerrCompany(id: 213, name: "Netflix", logo: "/wwemzKWzjKYJFfCeiB57q3r4Bcm.png"),
        SeerrCompany(id: 2739, name: "Disney+", logo: "/gJ8VX6JSu3ciXHuC2dDGAo2lvwM.png"),
        SeerrCompany(id: 1024, name: "Prime Video", logo: "/ifhbNuuVnlwYy5oXA5VIb2YR8AZ.png"),
        SeerrCompany(id: 2552, name: "Apple TV+", logo: "/4KAy34EHvRM25Ih8wb82AuGU7zJ.png"),
        SeerrCompany(id: 453, name: "Hulu", logo: "/pqUTCleNUiTLAVlelGxUgWn1ELh.png"),
        SeerrCompany(id: 49, name: "HBO", logo: "/tuomPhY2UtuPTqqFnKMVHvSb724.png"),
        SeerrCompany(id: 4353, name: "Discovery+", logo: "/1D1bS3Dyw4ScYnFWTlBOvJXC3nb.png"),
        SeerrCompany(id: 2, name: "ABC", logo: "/ndAvF4JLsliGreX87jAc9GdjmJY.png"),
        SeerrCompany(id: 19, name: "FOX", logo: "/1DSpHrWyOORkL9N2QHX7Adt31mQ.png"),
        SeerrCompany(id: 359, name: "Cinemax", logo: "/6mSHSquNpfLgDdv6VnOOvC5Uz2h.png"),
        SeerrCompany(id: 174, name: "AMC", logo: "/pmvRmATOCaDykE6JrVoeYxlFHw3.png"),
        SeerrCompany(id: 67, name: "Showtime", logo: "/Allse9kbjiP6ExaQrnSpIhkurEi.png"),
        SeerrCompany(id: 318, name: "Starz", logo: "/8GJjw3HHsAJYwIWKIPBPfqMxlEa.png"),
        SeerrCompany(id: 71, name: "The CW", logo: "/ge9hzeaU7nMtQ4PjkFlc68dGAJ9.png"),
        SeerrCompany(id: 6, name: "NBC", logo: "/o3OedEP0f9mfZr33jz2BfXOUK5.png"),
        SeerrCompany(id: 16, name: "CBS", logo: "/nm8d7P7MJNiBLdgIzUK0gkuEA4r.png"),
        SeerrCompany(id: 4330, name: "Paramount+", logo: "/fi83B1oztoS47xxcemFdPMhIzK.png"),
        SeerrCompany(id: 4, name: "BBC One", logo: "/mVn7xESaTNmjBUyUtGNvDQd3CT1.png"),
        SeerrCompany(id: 56, name: "Cartoon Network", logo: "/c5OC6oVCg6QP4eqzW6XIq17CQjI.png"),
        SeerrCompany(id: 80, name: "Adult Swim", logo: "/9AKyspxVzywuaMuZ1Bvilu8sXly.png"),
        SeerrCompany(id: 13, name: "Nickelodeon", logo: "/ikZXxg6GnwpzqiZbRPhJGaZapqB.png"),
        SeerrCompany(id: 3353, name: "Peacock", logo: "/gIAcGTjKKr0KOHL5s4O36roJ8p7.png"),
    ]
}

/// A way of narrowing what there is to ask for, as Discover's genre, studio
/// and network cards do: each opens a page of its titles. With its number at
/// The Movie Database, and its name for the page's heading.
enum SeerrBrowse: Hashable {
    case movieGenre(Int, String)
    case showGenre(Int, String)
    case studio(Int, String)
    case network(Int, String)
    /// The whole of one of Discover's rows of titles.
    case shelf(SeerrClient.Shelf, String)

    var name: String {
        switch self {
        case .movieGenre(_, let name), .showGenre(_, let name), .studio(_, let name), .network(_, let name),
             .shelf(_, let name): name
        }
    }

    /// Films, shows, or (nil) both together.
    var movies: Bool? {
        switch self {
        case .movieGenre, .studio, .shelf(.movies, _), .shelf(.upcomingMovies, _): true
        case .showGenre, .network, .shelf(.shows, _), .shelf(.upcomingShows, _): false
        case .shelf(.trending, _): nil
        }
    }

    fileprivate var path: String {
        switch self {
        case .movieGenre(let id, _): "discover/movies/genre/\(id)"
        case .showGenre(let id, _): "discover/tv/genre/\(id)"
        case .studio(let id, _): "discover/movies/studio/\(id)"
        case .network(let id, _): "discover/tv/network/\(id)"
        case .shelf(let shelf, _): shelf.rawValue
        }
    }
}

/// Someone in a film or show, for their own page.
struct SeerrPerson: Decodable {
    let name: String
    let biography: String?
    let profilePath: String?
}

/// A page of a list. An entry that can't be read is left out, not let spoil
/// the rest: a search lists people and collections beside films and shows,
/// and Seerr's lists gain kinds of entry from one version to the next.
private struct SeerrPage<Entry: Decodable>: Decodable {
    let results: [Entry]
    /// How many there are in all, where the list says.
    let total: Int?

    private enum Keys: String, CodingKey { case results, pageInfo, totalResults }
    private struct Unread: Decodable {}
    private struct Info: Decodable { let results: Int? }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        var list = try box.nestedUnkeyedContainer(forKey: .results)
        var kept: [Entry] = []
        while !list.isAtEnd {
            if let entry = try? list.decode(Entry.self) {
                kept.append(entry)
            } else {
                _ = try list.decode(Unread.self)
            }
        }
        results = kept
        total = (try? box.decode(Info.self, forKey: .pageInfo))?.results ?? (try? box.decode(Int.self, forKey: .totalResults))
    }
}

struct SeerrSettings: Decodable {
    let movie4kEnabled: Bool?
    let series4kEnabled: Bool?
    let partialRequestsEnabled: Bool?
    let enableSpecialEpisodes: Bool?
}

enum SeerrError: LocalizedError {
    case notSeerr
    case signInRefused
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notSeerr: String(localized: "No Seerr answered at that address.")
        case .signInRefused: String(localized: "Seerr wouldn't sign this account in. It has to be connected to the same media server, with Quick Connect turned on there.")
        case .refused(let message): message
        }
    }
}

/// Talks to one Seerr.
final class SeerrClient: @unchecked Sendable {
    let base: URL
    /// Signs in afresh when Seerr says the session has run out: a month,
    /// usually. Set by whoever made the client.
    var signIn: (@MainActor @Sendable () async throws -> Void)?
    // The session is a cookie, which the shared session keeps between launches.
    private let session = URLSession.shared

    init(base: URL) {
        self.base = base
    }

    /// Whether a Seerr answers there (it says so without being signed in to).
    static func answers(at base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/v1/status"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["version"] != nil
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil,
                      retrying: Bool = true) async throws -> Data {
        var parts = URLComponents(url: base.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // Seerr turns away a query with a reserved character left as
            // itself (a colon, an apostrophe, a comma, brackets), and
            // URLQueryItem leaves most of them: "Mission: Impossible" and
            // "Schitt's Creek" found nothing at all.
            parts.percentEncodedQueryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: Self.unreserved))
            }
        }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // A Seerr set to guard against forged requests hands out a token in a
        // cookie, and wants it back in a header with anything that changes something.
        if method != "GET", let token = HTTPCookieStorage.shared.cookies(for: base)?.first(where: { $0.name == "XSRF-TOKEN" })?.value {
            request.setValue(token, forHTTPHeaderField: "X-XSRF-TOKEN")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retrying, let signIn {
            try await signIn()
            return try await send(method, path, query: query, json: json, retrying: false)
        }
        // A session Seerr has let go of, its cookie still held here, is
        // answered 403, and so is something this account may not do. Who
        // Seerr takes this for tells the two apart.
        if status == 403, retrying, let signIn, await !hasSession() {
            try await signIn()
            return try await send(method, path, query: query, json: json, retrying: false)
        }
        guard (200..<300).contains(status) else {
            // Seerr says why: a quota used up or a title already asked for in
            // "message", something the account may not do in "error".
            let said = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = said?["message"] as? String ?? said?["error"] as? String
            throw SeerrError.refused(message ?? String(localized: "Seerr couldn't do that just now."))
        }
        return data
    }

    /// The characters a query's value may keep as they are.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func hasSession() async -> Bool {
        (try? await send("GET", "auth/me", retrying: false)) != nil
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send("GET", path, query: query))
    }

    // MARK: Signing in

    /// Seerr starts a Quick Connect on the media server and hands back the
    /// code to approve and the secret to finish with. Refused by a Seerr on
    /// Plex or Emby, by one from before it could do this, and when Quick
    /// Connect is off on the media server.
    func beginQuickConnect() async throws -> (code: String, secret: String) {
        guard let data = try? await send("POST", "auth/jellyfin/quickconnect/initiate", retrying: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String, let secret = json["secret"] as? String else { throw SeerrError.signInRefused }
        return (code, secret)
    }

    func finishQuickConnect(secret: String) async throws -> SeerrUser {
        guard let data = try? await send("POST", "auth/jellyfin/quickconnect/authenticate", json: ["secret": secret], retrying: false),
              let user = try? JSONDecoder().decode(SeerrUser.self, from: data) else { throw SeerrError.signInRefused }
        return user
    }

    func me() async throws -> SeerrUser { try await get("auth/me") }

    func signOut() async {
        _ = try? await send("POST", "auth/logout", retrying: false)
    }

    func settings() async -> SeerrSettings? { try? await get("settings/public") }

    // MARK: Finding

    /// Seerr's own Discover, in its order.
    enum Shelf: String, CaseIterable {
        case trending = "discover/trending"
        case movies = "discover/movies"
        case upcomingMovies = "discover/movies/upcoming"
        case shows = "discover/tv"
        case upcomingShows = "discover/tv/upcoming"
    }

    /// Films and shows only: a search and what's trending list people too.
    private func titles(at path: String, query: [String: String] = [:]) async throws -> [SeerrTitle] {
        var query = query
        query["page"] = "1"
        query["language"] = Self.language
        let page: SeerrPage<SeerrTitle> = try await get(path, query: query)
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    func titles(_ shelf: Shelf) async throws -> [SeerrTitle] { try await titles(at: shelf.rawValue) }

    func search(_ term: String) async throws -> [SeerrTitle] { try await titles(at: "search", query: ["query": term]) }

    private func path(of title: SeerrTitle) -> String { "\(title.isMovie ? "movie" : "tv")/\(title.tmdbId)" }

    func details(of title: SeerrTitle) async throws -> SeerrDetails {
        try await get(path(of: title), query: ["language": Self.language])
    }

    /// The genres there are of films, or of shows, each with pictures to
    /// show it by.
    func genres(movies: Bool) async -> [SeerrGenre] {
        (try? await get("discover/genreslider/\(movies ? "movie" : "tv")", query: ["language": Self.language])) ?? []
    }

    /// A page of what a genre, studio or network has, the most popular
    /// first, and how many pages there are.
    func titles(in browse: SeerrBrowse, page: Int) async throws -> (titles: [SeerrTitle], pages: Int) {
        let data = try await send("GET", browse.path, query: ["page": String(page), "language": Self.language])
        let pages = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["totalPages"] as? NSNumber)?.intValue ?? page
        return (Self.titles(in: data, under: "results", kind: browse.movies.map { $0 ? "movie" : "tv" }), pages)
    }

    enum Related: String { case recommendations, similar }

    /// What Seerr would put beside a title. These lists don't say which kind
    /// each entry is, being all of the title's own.
    func titles(_ related: Related, to title: SeerrTitle) async -> [SeerrTitle] {
        guard let data = try? await send("GET", path(of: title) + "/" + related.rawValue,
                                         query: ["page": "1", "language": Self.language]) else { return [] }
        return Self.titles(in: data, under: "results", kind: title.mediaType)
    }

    /// The Rotten Tomatoes and IMDb scores: a film's come together, a show's
    /// are Rotten Tomatoes' alone.
    func ratings(of title: SeerrTitle) async -> SeerrRatings? {
        guard let data = try? await send("GET", path(of: title) + (title.isMovie ? "/ratingscombined" : "/ratings")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tomatoes = json["rt"] as? [String: Any] ?? json
        let ratings = SeerrRatings(critics: (tomatoes["criticsScore"] as? NSNumber)?.intValue,
                                   audience: (tomatoes["audienceScore"] as? NSNumber)?.intValue,
                                   imdb: ((json["imdb"] as? [String: Any])?["criticsScore"] as? NSNumber)?.doubleValue)
        return ratings.critics == nil && ratings.audience == nil && ratings.imdb == nil ? nil : ratings
    }

    func person(_ id: Int) async -> SeerrPerson? {
        try? await get("person/\(id)", query: ["language": Self.language])
    }

    /// What someone has been in, the best known first, each once.
    func titles(with person: Int) async -> [SeerrTitle] {
        guard let data = try? await send("GET", "person/\(person)/combined_credits", query: ["language": Self.language]) else { return [] }
        var seen = Set<String>()
        return Self.titles(in: data, under: "cast", kind: nil, byVotes: true).filter { seen.insert($0.id).inserted }
    }

    /// The films and shows in one of Seerr's lists, each given `kind` where
    /// the list leaves it out, and an entry that can't be read left out.
    private static func titles(in data: Data, under key: String, kind: String?, byVotes: Bool = false) -> [SeerrTitle] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = json[key] as? [[String: Any]] else { return [] }
        if byVotes {
            entries.sort { (($0["voteCount"] as? NSNumber)?.intValue ?? 0) > (($1["voteCount"] as? NSNumber)?.intValue ?? 0) }
        }
        return entries.compactMap { entry in
            var entry = entry
            if entry["mediaType"] == nil, let kind { entry["mediaType"] = kind }
            guard let one = try? JSONSerialization.data(withJSONObject: entry),
                  let title = try? JSONDecoder().decode(SeerrTitle.self, from: one),
                  title.mediaType == "movie" || title.mediaType == "tv" else { return nil }
            return title
        }
    }

    // MARK: Requests

    /// Which requests to list, as Seerr's own list is narrowed.
    enum RequestFilter: String, CaseIterable {
        case all, pending, approved, processing, available, failed
    }

    enum RequestSort: String, CaseIterable { case added, modified }

    /// Requests, the newest first, and how many there are in all. Everyone's
    /// for someone who may see them, and otherwise the viewer's own; `user`
    /// narrows it to one person's.
    func requests(_ filter: RequestFilter = .all, sort: RequestSort = .added, by user: SeerrUser? = nil,
                  skip: Int = 0, take: Int = 20) async throws -> (list: [SeerrRequest], total: Int) {
        var query = ["take": String(take), "skip": String(skip), "sort": sort.rawValue, "filter": filter.rawValue]
        if let user { query["requestedBy"] = String(user.id) }
        let page: SeerrPage<SeerrRequest> = try await get("request", query: query)
        return (page.results, page.total ?? page.results.count)
    }

    /// One of them as a title, for its card.
    func title(of request: SeerrRequest) async -> SeerrTitle? {
        guard let media = request.media, let tmdbId = media.tmdbId, let type = media.mediaType,
              let data = try? await send("GET", "\(type == "movie" ? "movie" : "tv")/\(tmdbId)", query: ["language": Self.language]),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // A title's page doesn't say which kind it is; a list's entry does.
        json["mediaType"] = type
        guard let whole = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(SeerrTitle.self, from: whole)
    }

    /// The titles of a list of requests, in its order; one whose title can't
    /// be found is left out.
    func titled(_ requests: [SeerrRequest]) async -> [(request: SeerrRequest, title: SeerrTitle)] {
        let found = await withTaskGroup(of: (Int, SeerrTitle?).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask { (index, await self.title(of: request)) }
            }
            var found: [Int: SeerrTitle] = [:]
            for await (index, title) in group { found[index] = title }
            return found
        }
        return requests.indices.compactMap { index in found[index].map { (requests[index], $0) } }
    }

    // Saying yes or no to a request, and sending a failed one on again, are
    // for someone who manages them. Deleting is too, save that anyone may
    // take back their own while it's still waiting.

    func approve(_ request: SeerrRequest) async throws { _ = try await send("POST", "request/\(request.id)/approve") }

    func decline(_ request: SeerrRequest) async throws { _ = try await send("POST", "request/\(request.id)/decline") }

    func retry(_ request: SeerrRequest) async throws { _ = try await send("POST", "request/\(request.id)/retry") }

    func remove(_ request: SeerrRequest) async throws { _ = try await send("DELETE", "request/\(request.id)") }

    // MARK: Asking

    /// Asks for a film, or for seasons of a show (nil for all of them).
    func request(_ title: SeerrTitle, tvdbId: Int? = nil, seasons: [Int]? = nil, in4K: Bool = false,
                 options: SeerrRequestOptions = SeerrRequestOptions()) async throws {
        var body: [String: Any] = ["mediaType": title.mediaType, "mediaId": title.tmdbId, "is4k": in4K]
        if !title.isMovie {
            body["seasons"] = seasons.map { $0 as Any } ?? "all"
            if let tvdbId { body["tvdbId"] = tvdbId }
        }
        if let server = options.serverId { body["serverId"] = server }
        if let profile = options.profileId { body["profileId"] = profile }
        if let folder = options.rootFolder { body["rootFolder"] = folder }
        _ = try await send("POST", "request", json: body)
    }

    /// The Radarrs (for films) or Sonarrs a request of that quality can go to.
    func servers(movies: Bool, in4K: Bool) async -> [SeerrService] {
        let all: [SeerrService] = (try? await get("service/\(movies ? "radarr" : "sonarr")")) ?? []
        return all.filter { ($0.is4k == true) == in4K }
    }

    func options(of server: SeerrService, movies: Bool) async -> SeerrServiceOptions? {
        try? await get("service/\(movies ? "radarr" : "sonarr")/\(server.id)")
    }

    func quota(of user: SeerrUser) async -> SeerrQuota? { try? await get("user/\(user.id)/quota") }

    // MARK: Pictures

    // By way of Seerr itself, which fetches them from The Movie Database: the
    // app talks to the viewer's own servers and nowhere else. The sizes are
    // the database's own, and posters, backdrops and faces don't share them.

    func poster(_ path: String?) -> URL? { picture(path, size: "w500") }

    func backdrop(_ path: String?) -> URL? { picture(path, size: "w1280") }

    func face(_ path: String?) -> URL? { picture(path, size: "h632") }

    /// A backdrop at the size a card wants.
    func still(_ path: String?) -> URL? { picture(path, size: "w780") }

    /// A genre's picture washed in its two colours, as Seerr's genre cards
    /// are: the database does the washing.
    func art(of genre: SeerrGenre) -> URL? {
        picture(genre.picture, size: "w780_filter(duotone,\(genre.tones.dark),\(genre.tones.light))")
    }

    /// A studio's or network's logo in white, as Seerr shows them on its
    /// cards: the database recolours it on request.
    func logo(_ path: String?) -> URL? { picture(path, size: "w780_filter(duotone,ffffff,bababa)") }

    private func picture(_ path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/imageproxy/tmdb/t/p/\(size)\(path)")
    }

    private static var language: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}

/// The app's connection to a Seerr, for the account it's signed in to the
/// media server with: where it is, who it knows the viewer as, and what they
/// may ask for.
///
/// Each account connects for itself, as each has its own menu: one person
/// connecting doesn't open an account at Seerr for everyone else who uses the
/// device.
@MainActor
final class Requests: ObservableObject {
    /// The Seerr this account is connected to. Its session may be someone
    /// else's until `ready()` has looked: use that to ask it anything.
    @Published private(set) var client: SeerrClient?
    @Published private(set) var user: SeerrUser?
    private(set) var settings: SeerrSettings?
    /// Bumped when something has been asked for, so lists of requests reload.
    @Published private(set) var revision = 0
    /// A Seerr found on the media server's own machine, for an account that
    /// hasn't connected one on this device: the menu offers it, and nothing
    /// is signed in to there until the viewer says so.
    @Published private(set) var offered: URL?
    /// The Requests section is coming to the menu or leaving it; `arriving`
    /// when what's on screen is about to become the section itself.
    var changed: ((_ arriving: Bool) -> Void)?

    private let defaults = UserDefaults.standard
    private weak var server: (any MediaServer)?
    private var checking: Task<Void, Never>?
    private var looking: Task<Void, Never>?

    private static func key(_ server: any MediaServer) -> String? {
        server.userId.map { "goosetv.seerr.\($0)" }
    }

    /// Set once the account has turned the offer down or disconnected: it
    /// isn't offered again, and Settings is where to connect.
    private static func declinedKey(_ server: any MediaServer) -> String? {
        server.userId.map { "goosetv.seerr.off.\($0)" }
    }

    /// The Seerr saved for this account, if it connected one.
    func restore(for server: (any MediaServer)?) {
        checking?.cancel()
        checking = nil
        looking?.cancel()
        looking = nil
        self.server = server
        user = nil
        settings = nil
        offered = nil
        guard let server, let key = Self.key(server) else {
            client = nil
            return
        }
        guard let saved = defaults.string(forKey: key), let base = URL(string: saved) else {
            client = nil
            look(on: server)
            return
        }
        let restored = makeClient(base)
        client = restored
        checking = Task { await check(restored, server: server) }
    }

    /// The client, once its session is known to be this viewer's. Nil when
    /// nothing is connected, or Seerr can't be reached to tell.
    func ready() async -> SeerrClient? {
        await checking?.value
        guard let client, let server else { return nil }
        if user == nil {
            let again = Task { await check(client, server: server) }
            checking = again
            await again.value
        }
        return user != nil && self.client === client ? client : nil
    }

    /// Seerr's session is a cookie, and the device keeps one for each Seerr,
    /// not for each person: after a change of account it's still the last
    /// one's. So who it belongs to is asked, and if that's someone else (or
    /// it has run out), this account signs in over it.
    private func check(_ client: SeerrClient, server: any MediaServer) async {
        let mine = { (id: String?) in id?.replacingOccurrences(of: "-", with: "").lowercased() }
        if let me = try? await client.me(), let theirs = mine(me.jellyfinUserId), theirs == mine(server.userId) {
            if self.client === client { user = me }
        } else if !Task.isCancelled, self.client === client {
            try? await signIn(client, server: server)
        }
        guard self.client === client else { return }
        settings = await client.settings()
    }

    /// For an account with no Seerr connected here: whether there's one to
    /// offer. Each device finds it for itself, at whatever address it reaches
    /// the media server by, so one connected on the television is there to
    /// connect on the phone too. Only where signing in would work (Quick
    /// Connect, which is Jellyfin's and can be turned off).
    private func look(on server: any MediaServer) {
        guard server.flavor.supportsQuickConnect, let declined = Self.declinedKey(server),
              !defaults.bool(forKey: declined) else { return }
        looking = Task {
            guard await server.quickConnectEnabled(), let found = await find(), !Task.isCancelled,
                  self.server === server, client == nil else { return }
            offered = found
            changed?(false)
        }
    }

    /// Looks once more, as the app comes back to the front: the first look
    /// may have been made before the network was up (a phone just woken, a
    /// VPN still joining).
    func lookAgain() {
        guard client == nil, offered == nil, let server else { return }
        looking?.cancel()
        look(on: server)
    }

    /// The offer turned down: the section leaves the menu, and stays out.
    func decline() {
        guard let server, let declined = Self.declinedKey(server) else { return }
        defaults.set(true, forKey: declined)
        looking?.cancel()
        looking = nil
        offered = nil
        changed?(false)
    }

    /// Where a Seerr usually is: on the media server's own machine, at Seerr's
    /// usual port. Nil if nothing answers there.
    func find() async -> URL? {
        guard let host = server?.baseURL.host else { return nil }
        for scheme in ["http", "https"] {
            if let base = URL(string: "\(scheme)://\(host):5055"), await SeerrClient.answers(at: base) { return base }
        }
        return nil
    }

    /// Connects to the Seerr at `address` and signs the viewer in there with
    /// their media server account, which takes no password: Seerr asks the
    /// media server for a Quick Connect code, and the app, already signed in,
    /// approves it.
    func connect(to address: String) async throws {
        guard let server, let key = Self.key(server) else { throw SeerrError.signInRefused }
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty else { throw SeerrError.notSeerr }
        if parts.port == nil, parts.scheme == "http" { parts.port = 5055 }
        // Kept as far as a folder Seerr is served under, without a last slash.
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        parts.query = nil
        parts.fragment = nil
        guard let base = parts.url, await SeerrClient.answers(at: base) else { throw SeerrError.notSeerr }
        let connecting = makeClient(base)
        try await signIn(connecting, server: server)
        // Signed out of the media server, or into another account, meanwhile.
        guard self.server === server, Self.key(server) == key else { return }
        checking?.cancel()
        checking = nil
        looking?.cancel()
        looking = nil
        defaults.set(base.absoluteString, forKey: key)
        if let declined = Self.declinedKey(server) { defaults.removeObject(forKey: declined) }
        changed?(true)
        offered = nil
        client = connecting
        settings = await connecting.settings()
        revision += 1
    }

    /// Leaves the Seerr, and doesn't offer it again: after this, connecting
    /// is from Settings.
    func disconnect() {
        if let server {
            if let key = Self.key(server) { defaults.removeObject(forKey: key) }
            if let declined = Self.declinedKey(server) { defaults.set(true, forKey: declined) }
        }
        checking?.cancel()
        checking = nil
        let leaving = client
        client = nil
        user = nil
        settings = nil
        offered = nil
        changed?(false)
        Task { await leaving?.signOut() }
    }

    func asked() { revision += 1 }

    private func makeClient(_ base: URL) -> SeerrClient {
        let client = SeerrClient(base: base)
        client.signIn = { [weak self, weak client] in
            guard let self, let client, let server = self.server else { throw SeerrError.signInRefused }
            try await self.signIn(client, server: server)
        }
        return client
    }

    private func signIn(_ client: SeerrClient, server: any MediaServer) async throws {
        let (code, secret) = try await client.beginQuickConnect()
        guard (try? await server.authorizeQuickConnect(code: code)) == true else { throw SeerrError.signInRefused }
        let signedIn = try await client.finishQuickConnect(secret: secret)
        // The one still wanted: not one left behind by signing out meanwhile.
        if self.server === server { user = signedIn }
    }
}
