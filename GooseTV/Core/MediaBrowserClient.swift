import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What the server calls this device, in its list of sessions and devices:
/// the name another device's "Play on" lists it by. An Apple TV has the one
/// it's given in Settings, Play on TV (tvOS tells an app only "Apple TV");
/// a phone or tablet, what it is.
enum DeviceName {
    static let key = "goosetv.deviceName"

    static var current: String {
        #if os(tvOS)
        let chosen = clean(UserDefaults.standard.string(forKey: key) ?? "")
        return chosen.isEmpty ? fallback : chosen
        #else
        return UIDevice.current.model
        #endif
    }

    /// What it's called when nobody has named it.
    static var fallback: String {
        let system = clean(UIDevice.current.name)
        return system.isEmpty ? "Apple TV" : system
    }

    /// Letters, digits and plain punctuation only, and not too long: it goes
    /// in a header between quotation marks.
    static func clean(_ name: String) -> String {
        let kept = name.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " -_.'()&".unicodeScalars.contains($0))
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(40).description
    }
}

/// The answer if it comes within the time, otherwise nil, with the work
/// cancelled. For requests a film can start without: one the server sat on
/// held the picture for the whole 30-second request timeout.
func withinDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

enum ServerError: LocalizedError {
    case invalidURL
    case badResponse(Int)
    case notAuthenticated
    case noPlayableSource

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "That server address doesn't look valid.")
        case .badResponse(let code):
            if code == 401 { return String(localized: "Wrong username or password.") }
            return String(localized: "Server error (HTTP \(code)).", comment: "The number is an HTTP status code")
        case .notAuthenticated: return String(localized: "Not signed in.")
        case .noPlayableSource: return String(localized: "No playable video source found for this item.")
        }
    }
}

/// Speaks the Emby-lineage API that both Jellyfin and Emby serve. Where the two
/// differ — the authorization scheme, which header carries the token, Quick
/// Connect — `flavor` decides.
final class MediaBrowserClient: MediaServer {
    let baseURL: URL
    let flavor: ServerFlavor
    private(set) var token: String?
    private(set) var userId: String?
    /// Called when the server rejects the saved sign-in (401): the session was revoked,
    /// the password changed, or the user was deleted. Failed sign-ins don't trigger it,
    /// since they're sent without a token.
    var onUnauthorized: (() -> Void)?

    private static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var deviceId: String { Self.deviceId }

    private static let deviceId: String = {
        let key = "goosetv.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    /// One session for every client: the setup screen probes a dozen addresses
    /// with a client each, and a pool per client meant a connection per probe.
    /// No cache: nothing here is served with caching headers, and the screens
    /// refetch for freshness anyway, so writing every reply to disk bought nothing.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    /// Decoder mapping Jellyfin's PascalCase keys to camelCase properties,
    /// so the models don't need per-field CodingKeys.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!
            let name = key.stringValue
            // Only a leading ASCII capital is rewritten; anything else (a
            // numeric key, an id, a width) is handed back as it came.
            guard key.intValue == nil, let first = name.utf8.first, (65...90).contains(first) else { return key }
            return AnyKey(stringValue: String(UnicodeScalar(first + 32)) + name.dropFirst())
        }
        return decoder
    }()

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(baseURL: URL, flavor: ServerFlavor = .jellyfin, token: String? = nil, userId: String? = nil) {
        self.baseURL = baseURL
        self.flavor = flavor
        self.token = token
        self.userId = userId
    }

    // MARK: - Request plumbing

    private var authHeader: String {
        var header = #"\#(flavor.authScheme) Client="JellyGoose", Device="\#(DeviceName.current)", DeviceId="\#(Self.deviceId)", Version="\#(Self.appVersion)""#
        // Emby reads the token from X-Emby-Token instead, and ignores it here.
        if let token, !flavor.usesSeparateTokenHeader { header += #", Token="\#(token)""# }
        return header
    }

    func url(path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // In a fixed order: a dictionary's changes from one call to the
            // next, and the image caches are keyed by the whole address, so a
            // card redrawn with its picture's address shuffled missed them,
            // blanked, and fetched the picture again.
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves a "+" as it is, and the server reads a bare
            // one as a space: a search for "Disney+" was a search for "Disney ".
            // Only a typed search ever has one, and image urls are built for
            // every card on every redraw, so the rewrite waits for a "+".
            if query.values.contains(where: { $0.contains("+") }) {
                components.percentEncodedQuery = components.percentEncodedQuery?
                    .replacingOccurrences(of: "+", with: "%2B")
            }
        }
        return components.url!
    }

    /// The token as a query, for urls the player and VLC fetch themselves, with
    /// no headers to carry it in.
    private var tokenQuery: [String: String] {
        guard let token else { return [:] }
        var query = ["api_key": token]
        if flavor.usesSeparateTokenHeader { query["X-Emby-Token"] = token }
        return query
    }

    /// A request the server will take as this account's, for something
    /// that makes its own (a recording read as it grows).
    private func signed(_ path: String, query: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url(path: path, query: query))
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let token, flavor.usesSeparateTokenHeader {
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        return req
    }

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> Data {
        var req = signed(path, query: query)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ServerError.badResponse(0) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, token != nil { onUnauthorized?() }
            throw ServerError.badResponse(http.statusCode)
        }
        // URLSession follows redirects silently. One that keeps the path (http → https)
        // is fine; one that lands somewhere else means the call never reached its endpoint.
        guard http.url?.path == req.url?.path else { throw ServerError.badResponse(302) }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await request(path, query: query)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, query: [String: String] = [:], json: [String: Any] = [:]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json)
        let data = try await request(path, query: query, method: "POST", body: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// POST where we don't care about the response body (progress reports etc.)
    private func postVoid(_ path: String, query: [String: String] = [:], json: [String: Any]? = nil) async throws {
        var body: Data? = nil
        if let json { body = try JSONSerialization.data(withJSONObject: json) }
        _ = try await request(path, query: query, method: "POST", body: body)
    }

    // MARK: - Server / auth

    func publicInfo() async throws -> PublicSystemInfo {
        try await get("System/Info/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        let result: AuthenticationResult = try await post("Users/AuthenticateByName", json: ["Username": username, "Pw": password])
        token = result.accessToken
        userId = result.user.id
        return result
    }

    func authorizeQuickConnect(code: String) async throws -> Bool {
        guard flavor.supportsQuickConnect else { return false }
        let uid = try requireUser()
        let data = try await request("QuickConnect/Authorize", query: ["code": code, "userId": uid], method: "POST")
        return String(data: data, encoding: .utf8)?.contains("true") ?? false
    }

    func quickConnectEnabled() async -> Bool {
        guard flavor.supportsQuickConnect else { return false }
        guard let data = try? await request("QuickConnect/Enabled") else { return false }
        return String(data: data, encoding: .utf8)?.contains("true") ?? false
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        try await post("QuickConnect/Initiate")
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get("QuickConnect/Connect", query: ["secret": secret])
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        let result: AuthenticationResult = try await post("Users/AuthenticateWithQuickConnect", json: ["Secret": secret])
        token = result.accessToken
        userId = result.user.id
        return result
    }

    /// Signing out locally only stops this app using the token; the server goes
    /// on accepting it until someone deletes the device by hand. This ends the
    /// session properly. Best effort: a token the server has already forgotten
    /// answers 401, which is the outcome we wanted anyway.
    func logout() async {
        guard token != nil else { return }
        try? await postVoid("Sessions/Logout")
        token = nil
    }

    // MARK: - Browsing

    private func requireUser() throws -> String {
        guard let userId else { throw ServerError.notAuthenticated }
        return userId
    }

    func signedInUser() async throws -> JFUser {
        try await get("Users/\(try requireUser())")
    }

    func userViews() async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Views")
        // The libraries with video or music in them. Books and photographs
        // aren't this app's to show, and the server's own Collections,
        // Playlists and Live TV views are no libraries (and have sections of
        // their own, where the app has them).
        return result.items.filter {
            guard let kind = $0.collectionType else { return $0.type == "CollectionFolder" }
            return ["movies", "tvshows", "homevideos", "musicvideos", "music", "books"].contains(kind)
        }
    }

    // List endpoints ask for no extra Fields: cards show none of them, and a
    // detail page refetches its item in full. Overviews alone were most of the
    // payload on a hundred-item page. (Home's shelves ask for taglines, a
    // line each, for the banner.)

    /// What a list of cards needs of the server and no more: one image of each
    /// kind, since a card only ever uses the first backdrop and a library with
    /// fanart sends twenty; and no count of the whole list, which costs the
    /// server a second query, unless the caller shows it.
    private func listQuery(_ query: [String: String], counted: Bool = false) -> [String: String] {
        var query = query
        query["ImageTypeLimit"] = "1"
        if !counted { query["EnableTotalRecordCount"] = "false" }
        return query
    }

    func resumeItems(limit: Int = 12) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items/Resume", query: listQuery([
            "Limit": "\(limit)",
            "MediaTypes": "Video",
            // For Home's banner, which shows a film's tagline; a line apiece.
            "Fields": "Taglines,Path,PrimaryImageAspectRatio",
        ]))
        return result.items
    }

    /// Everything favourited, across every library. Films, shows and the odd
    /// favourited episode, newest first — which is the order they were marked
    /// in, near enough, and more use than alphabetical for a list people add to.
    func favorites(limit: Int = 200) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "Filters": "IsFavorite",
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,Episode",
            "SortBy": "DateCreated",
            "SortOrder": "Descending",
            "Limit": "\(limit)",
        ]))
        return result.items
    }

    /// The films marked to be watched (the viewer's "like", see
    /// `setWatchlisted`) and not yet watched, by name: a film watched since,
    /// here or anywhere else, has left the list by being watched.
    func watchlist(limit: Int = 200) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "Filters": "Likes,IsUnplayed",
            "Recursive": "true",
            "IncludeItemTypes": "Movie",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Limit": "\(limit)",
        ]))
        return result.items
    }

    /// Collections and playlists — the groupings made on the server rather than
    /// found in the folders. Both hold items and open the same way, so they are
    /// listed together.
    func collections(limit: Int = 200) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "IncludeItemTypes": "BoxSet,Playlist",
            "Recursive": "true",
            "SortBy": "SortName",
            "Limit": "\(limit)",
            // What each holds, for its tile.
            "Fields": "ChildCount",
        ]))
        return result.items
    }

    /// Everything playable in a show, a collection or a playlist, for Play All
    /// and Shuffle. In order means a playlist's own order, a collection's by
    /// release, and a show's by season and episode; episodes the server only
    /// knows of from its metadata, with no file, are left out.
    func playQueue(for container: BaseItem, shuffled: Bool, limit: Int = 300) async throws -> [BaseItem] {
        let uid = try requireUser()
        var query = [
            "ParentId": container.id,
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Episode,Video",
            "IsMissing": "false",
            "Limit": "\(limit)",
        ]
        if shuffled {
            query["SortBy"] = "Random"
        } else if container.isSeries {
            query["SortBy"] = "ParentIndexNumber,IndexNumber"
        } else if container.type != "Playlist" {
            query["SortBy"] = "PremiereDate,SortName"
        }
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(query))
        return result.items
    }

    func nextUp(limit: Int = 12) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Shows/NextUp", query: listQuery([
            "UserId": uid,
            "Limit": "\(limit)",
        ]))
        return result.items
    }

    func latest(in libraryId: String, limit: Int, types: String?) async throws -> [BaseItem] {
        let uid = try requireUser()
        var query = [
            "ParentId": libraryId,
            "Limit": "\(limit)",
            "Fields": "Taglines,Path,PrimaryImageAspectRatio",
        ]
        if let types { query["IncludeItemTypes"] = types }
        // Latest endpoint returns a bare array, not an ItemsResult envelope.
        let data = try await request("Users/\(uid)/Items/Latest", query: listQuery(query))
        return try Self.decoder.decode([BaseItem].self, from: data)
    }

    func recentRecordings(in libraryId: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": BaseItem.recordingTypes,
            "SortBy": "DateCreated,SortName",
            "SortOrder": "Descending",
            "Limit": "\(limit)",
            "Fields": "Taglines,Path,PrimaryImageAspectRatio,DateCreated,PremiereDate",
        ]))
        return result.items
    }

    func libraryItems(parentId: String, startIndex: Int = 0, limit: Int = 100,
                      sortBy: String = "SortName", sortOrder: String = "Ascending",
                      genres: [String] = [], years: [Int] = [], filters: [String] = [],
                      itemTypes: String = "Movie,Series", nameLessThan: String? = nil,
                      ids: [String] = []) async throws -> ItemsResult {
        let uid = try requireUser()
        var query = [
            "ParentId": parentId,
            "Recursive": "true",
            "IncludeItemTypes": itemTypes,
            "SortBy": sortBy,
            "SortOrder": sortOrder,
            "StartIndex": "\(startIndex)",
            "Limit": "\(limit)",
        ]
        // Titles in any of them.
        if !genres.isEmpty { query["Genres"] = genres.joined(separator: "|") }
        if !years.isEmpty { query["Years"] = years.map(String.init).joined(separator: ",") }
        if !filters.isEmpty { query["Filters"] = filters.joined(separator: ",") }
        if let nameLessThan { query["NameLessThan"] = nameLessThan }
        if !ids.isEmpty { query["Ids"] = ids.joined(separator: ",") }
        // A grid's alphabet index marks the letter of the title in focus; the
        // rest are what lists put in order here are sorted by (see
        // `showEpisodes`). Jellyfin sends most of them unasked; Emby
        // sends what it's asked for.
        if limit > 0 {
            query["Fields"] = "SortName,DateCreated,PremiereDate,ProductionYear,CommunityRating,CriticRating,PrimaryImageAspectRatio"
        }
        // The grid shows how many there are, and pages by it.
        return try await get("Users/\(uid)/Items", query: listQuery(query, counted: true))
    }

    /// A library's titles under one letter, by name: for a list too short to
    /// hold a whole library, as the car's is. "#" is everything filed before A.
    /// `startIndex` and `limit` take a stretch from the middle of them.
    func libraryItems(parentId: String, letter: String, itemTypes: String,
                      startIndex: Int = 0, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        var query = Self.filed(under: letter, in: parentId, itemTypes: itemTypes)
        query["StartIndex"] = "\(startIndex)"
        query["Limit"] = "\(limit)"
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(query))
        return result.items
    }

    /// How many of a library's titles are filed under a letter.
    func titleCount(parentId: String, letter: String, itemTypes: String) async throws -> Int {
        let uid = try requireUser()
        var query = Self.filed(under: letter, in: parentId, itemTypes: itemTypes)
        query["Limit"] = "0"
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(query, counted: true))
        return result.totalRecordCount ?? 0
    }

    /// Every title under a letter, in order, with little but its name: for
    /// marking a long letter out in stretches before any of it is listed.
    func titleNames(parentId: String, letter: String, itemTypes: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        var query = Self.filed(under: letter, in: parentId, itemTypes: itemTypes)
        query["Fields"] = "SortName"
        query["EnableImages"] = "false"
        query["EnableUserData"] = "false"
        query["Limit"] = "5000"
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(query))
        return result.items
    }

    private static func filed(under letter: String, in parentId: String, itemTypes: String) -> [String: String] {
        var query = [
            "ParentId": parentId,
            "Recursive": "true",
            "IncludeItemTypes": itemTypes,
            "SortBy": "SortName",
            "SortOrder": "Ascending",
        ]
        switch letter {
        case "#": query["NameLessThan"] = "A"
        // Whatever is filed after Z: names in other alphabets, which no
        // letter here would reach.
        case "…": query["NameStartsWithOrGreater"] = "{"
        default: query["NameStartsWith"] = letter
        }
        return query
    }

    /// Everything from one studio or network across every library, newest first.
    func items(fromStudio studioId: String, limit: Int = 200) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "StudioIds": studioId,
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series",
            "SortBy": "PremiereDate,ProductionYear,SortName",
            "SortOrder": "Descending",
            "Limit": "\(limit)",
        ]))
        return result.items
    }

    func items(ids: [String]) async throws -> [BaseItem] {
        let uid = try requireUser()
        // A hundred at a time: the ids go in the address, and a few hundred
        // of them make one longer than a server will read.
        var found: [BaseItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
                "Ids": ids[start..<min(start + 100, ids.count)].joined(separator: ","),
                "Fields": "SortName",
            ]))
            found += result.items
        }
        return found
    }

    func years(in parentId: String) async throws -> [Int] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Years", query: [
            "ParentId": parentId,
            "UserId": uid,
            "Recursive": "true",
            "SortBy": "SortName",
        ])
        return result.items.compactMap { $0.name.flatMap(Int.init) }.sorted()
    }

    /// Genre names present in a library, alphabetical.
    func genres(in parentId: String) async throws -> [String] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Genres", query: [
            "ParentId": parentId,
            "UserId": uid,
            "SortBy": "SortName",
        ])
        return result.items.compactMap(\.name)
    }

    func item(id: String) async throws -> BaseItem {
        let uid = try requireUser()
        return try await get("Users/\(uid)/Items/\(id)")
    }

    /// An item as the server sent it, and decoded: a download keeps the bytes,
    /// to read back offline with `decodeItem`.
    func itemData(id: String) async throws -> (Data, BaseItem) {
        let uid = try requireUser()
        let data = try await request("Users/\(uid)/Items/\(id)")
        return (data, try Self.decoder.decode(BaseItem.self, from: data))
    }

    static func decodeItem(_ data: Data) -> BaseItem? {
        try? decoder.decode(BaseItem.self, from: data)
    }

    /// The original file, as a download fetches it.
    func downloadURL(item: BaseItem, source: MediaSource) -> URL? {
        guard item.isPlayableAudio else { return staticStreamURL(item: item, source: source, playSessionId: nil) }
        // A song or a book's part, by the audio route, as the music player asks for it.
        var query = ["static": "true"]
        if let msId = source.id { query["MediaSourceId"] = msId }
        if flavor == .jellyfin, let token { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
        return url(path: "Audio/\(item.id)/stream", query: query)
    }

    /// A film or episode as a smaller MP4 the server makes as it's fetched,
    /// within `quality`, for a download. Its audio is the source's default
    /// track; subtitles are left out and fetched as files of their own. Asked
    /// under a device name of its own: the server stops this device's
    /// transcodes when it starts playing something else, and a download
    /// isn't to be stopped by that.
    func convertedDownloadURL(item: BaseItem, source: MediaSource, quality: DownloadQuality) -> URL? {
        guard let maxHeight = quality.maxHeight, let maxWidth = quality.maxWidth else { return nil }
        var query = ["VideoCodec": "h264", "AudioCodec": "aac", "Static": "false",
                     "MaxHeight": "\(maxHeight)", "MaxWidth": "\(maxWidth)",
                     "VideoBitrate": "\(quality.videoBitrate)", "AudioBitrate": "\(quality.audioBitrate)",
                     "MaxAudioChannels": "\(quality.audioChannels)", "SubtitleMethod": "Drop",
                     "DeviceId": Self.deviceId + "-download",
                     "PlaySessionId": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()]
        if let msId = source.id { query["MediaSourceId"] = msId }
        if let audio = source.defaultAudioStreamIndex { query["AudioStreamIndex"] = "\(audio)" }
        if flavor == .jellyfin, let token { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
        return url(path: "Videos/\(item.id)/stream.mp4", query: query)
    }

    /// Each text subtitle of a film as a WebVTT file, by the server's index:
    /// kept beside a converted download, which has none inside it.
    func subtitleDownloads(item: BaseItem, source: MediaSource) -> [Int: URL] {
        drawableSubtitles(item: item, source: source, externalOnly: false)
    }

    /// A song or a book's part Apple's player can't read (Ogg, Opus, WMA) as an
    /// MP3 the server makes as it's fetched, to keep on the device.
    func audioDownloadURL(item: BaseItem, source: MediaSource) -> URL? {
        var query = ["AudioCodec": "mp3", "AudioBitrate": "320000", "MaxAudioChannels": "2", "DeviceId": Self.deviceId]
        if let msId = source.id { query["MediaSourceId"] = msId }
        if flavor == .jellyfin, let token { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
        return url(path: "Audio/\(item.id)/stream.mp3", query: query)
    }

    /// Behind-the-scenes pieces, deleted scenes, and trailers kept beside the
    /// film. The trailers Jellyfin lists under RemoteTrailers are YouTube links
    /// and are deliberately left out: nothing here can play them, and an extra
    /// that does nothing when pressed is worse than one that isn't offered.
    func extras(for itemId: String) async -> [BaseItem] {
        guard let uid = userId else { return [] }
        async let features: [BaseItem]? = try? get("Users/\(uid)/Items/\(itemId)/SpecialFeatures")
        async let trailers: [BaseItem]? = try? get("Users/\(uid)/Items/\(itemId)/LocalTrailers")
        // Awaited in the order they were declared: the runtime allocates child
        // tasks on a stack, and awaiting them out of order has aborted the app.
        let featureList = await features ?? []
        let trailerList = await trailers ?? []
        return trailerList + featureList
    }

    func nextEpisode(seriesId: String) async -> BaseItem? {
        guard let uid = userId else { return nil }
        // Part-watched first: Next Up can skip past one once a later episode
        // has been watched.
        if let resuming: ItemsResult = try? await get("Users/\(uid)/Items/Resume", query: listQuery([
            "ParentId": seriesId,
            "Limit": "1",
            "MediaTypes": "Video",
        ])), let episode = resuming.items.first {
            return episode
        }
        let next: ItemsResult? = try? await get("Shows/NextUp", query: listQuery([
            "UserId": uid,
            "SeriesId": seriesId,
            "Limit": "1",
        ]))
        return next?.items.first
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Shows/\(seriesId)/Seasons", query: listQuery(["UserId": uid]))
        return result.items
    }

    func episodes(seriesId: String, seasonId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Shows/\(seriesId)/Episodes", query: listQuery([
            "UserId": uid,
            "SeasonId": seasonId,
            // Each card's plot. Not its files: the player and a download each
            // fetch the episode again before they need those.
            "Fields": "Overview",
        ]))
        return result.items
    }

    /// Everything in the library this person worked on, newest first.
    func items(withPerson personId: String, limit: Int = 100) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "PersonIds": personId,
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series",
            "SortBy": "PremiereDate,ProductionYear,SortName",
            "SortOrder": "Descending",
            "Limit": "\(limit)",
        ]))
        return result.items
    }

    func search(_ term: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "SearchTerm": term,
            "Recursive": "true",
            // Home videos and music videos with them, where there are any.
            "IncludeItemTypes": "Movie,Series,Video,MusicVideo",
            "Limit": "40",
        ]))
        return result.items
    }

    func searchAudiobooks(_ term: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "SearchTerm": term,
            "Recursive": "true",
            "IncludeItemTypes": "AudioBook",
            "Fields": "ParentId,DateCreated,SortName,ProductionYear",
            "Limit": "60",
        ]))
        return result.items
    }

    func searchCollections(_ term: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "SearchTerm": term,
            "Recursive": "true",
            "IncludeItemTypes": "BoxSet,Playlist",
            "Limit": "20",
        ]))
        return result.items
    }

    /// Asked for as items, Jellyfin puts the names that begin with the term
    /// first; its list of people has them by the alphabet, with "Tom Hanks"
    /// some way down the seven hundred names that have "tom" in them. That
    /// list is the fallback, for a server that keeps people out of its items.
    func searchPeople(_ term: String) async throws -> [Person] {
        let uid = try requireUser()
        var found: [BaseItem] = []
        if let result: ItemsResult = try? await get("Users/\(uid)/Items", query: listQuery([
            "SearchTerm": term,
            "Recursive": "true",
            "IncludeItemTypes": "Person",
            "Limit": "60",
        ])) {
            found = result.items
        }
        if found.isEmpty {
            let result: ItemsResult = try await get("Persons", query: listQuery([
                "SearchTerm": term,
                "UserId": uid,
                "Limit": "60",
            ]))
            found = result.items
        }
        return Person.ranked(found.map {
            Person(id: $0.id, name: $0.name, role: nil, type: nil, primaryImageTag: $0.imageTags?["Primary"])
        }, for: term)
    }

    // MARK: - Images

    func imageURL(for item: BaseItem, type: String = "Primary", maxWidth: Int = 600) -> URL? {
        var itemId = item.id
        var tag: String? = item.imageTags?[type]

        if type == "Backdrop" {
            if let t = item.backdropImageTags?.first {
                tag = t
            } else if let parentId = item.parentBackdropItemId, let t = item.parentBackdropImageTags?.first {
                itemId = parentId
                tag = t
            } else {
                return nil
            }
        }
        if type == "Logo", tag == nil {
            // Episodes borrow the series' logo artwork.
            if let parentId = item.parentLogoItemId, let t = item.parentLogoImageTag {
                itemId = parentId
                tag = t
            } else {
                return nil
            }
        }
        if type == "Thumb", tag == nil {
            // Plenty of items have no wide still. Every other type says so by
            // returning nil; this one used to hand back a URL the server answers
            // 404 to, which a caller can only find out about by drawing a hole.
            return nil
        }
        if type == "Primary", tag == nil {
            // Episodes without their own art fall back to the series poster,
            // and songs to their album's cover.
            if let album = item.albumId, let t = item.albumPrimaryImageTag {
                itemId = album
                tag = t
            } else if item.isAudiobook, let folder = item.parentId {
                // A part of a book in parts: the cover is its folder's.
                itemId = folder
                tag = nil
            } else if let sid = item.seriesId, let t = item.seriesPrimaryImageTag {
                itemId = sid
                tag = t
            } else {
                return nil
            }
        }
        var query = ["maxWidth": "\(maxWidth)", "quality": "90"]
        if let tag { query["tag"] = tag }
        let index = type == "Backdrop" ? "/0" : ""
        return url(path: "Items/\(itemId)/Images/\(type)\(index)", query: query)
    }

    func similar(to itemId: String, limit: Int = 16) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Items/\(itemId)/Similar", query: listQuery([
            "UserId": uid,
            "Limit": "\(limit)",
        ]))
        return result.items
    }

    func setPlayed(_ itemId: String, _ played: Bool) async throws {
        let uid = try requireUser()
        _ = try await request("Users/\(uid)/PlayedItems/\(itemId)", method: played ? "POST" : "DELETE")
    }

    func setFavorite(_ itemId: String, _ favorite: Bool) async throws {
        let uid = try requireUser()
        _ = try await request("Users/\(uid)/FavoriteItems/\(itemId)", method: favorite ? "POST" : "DELETE")
    }

    func setWatchlisted(_ itemId: String, _ listed: Bool) async throws {
        let uid = try requireUser()
        // Deleting the rating leaves the film neither liked nor disliked.
        _ = try await request("Users/\(uid)/Items/\(itemId)/Rating", query: listed ? ["Likes": "true"] : [:],
                              method: listed ? "POST" : "DELETE")
    }

    /// The episode after this one, crossing into the next season if needed.
    func nextEpisode(after episode: BaseItem) async throws -> BaseItem? {
        let uid = try requireUser()
        guard let seriesId = episode.seriesId else { return nil }
        let result: ItemsResult = try await get("Shows/\(seriesId)/Episodes", query: listQuery([
            "UserId": uid,
            "StartItemId": episode.id,
            "Limit": "2",
            "Fields": "Overview",
        ]))
        guard result.items.first?.id == episode.id, result.items.count > 1 else { return nil }
        return result.items[1]
    }

    func episodes(after episode: BaseItem, limit: Int) async -> [BaseItem] {
        guard let uid = try? requireUser(), let seriesId = episode.seriesId,
              let result: ItemsResult = try? await get("Shows/\(seriesId)/Episodes", query: listQuery([
                  "UserId": uid,
                  "StartItemId": episode.id,
                  "Limit": String(limit + 1),
              ])),
              result.items.first?.id == episode.id else { return [] }
        return Array(result.items.dropFirst())
    }

    // MARK: - Library administration (needs an administrator account)

    /// The signed-in user's configuration plus whether they can administer the server.
    func userDetails() async throws -> (configuration: [String: Any], isAdministrator: Bool, findsSubtitles: Bool) {
        let uid = try requireUser()
        let data = try await request("Users/\(uid)")
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configuration = user["Configuration"] as? [String: Any] else {
            throw ServerError.badResponse(0)
        }
        let policy = user["Policy"] as? [String: Any]
        let administrator = policy?["IsAdministrator"] as? Bool ?? false
        // Whoever runs the server may, and anyone it has been allowed to:
        // "subtitle management" on Jellyfin, "subtitle downloading" on Emby.
        let subtitles = ["EnableSubtitleManagement", "EnableSubtitleDownloading"].contains { policy?[$0] as? Bool == true }
        return (configuration, administrator, administrator || subtitles)
    }

    func libraries() async throws -> [VirtualFolder] {
        try await get("Library/VirtualFolders")
    }

    func addLibrary(name: String, kind: LibraryKind, folders: [String]) async throws {
        var query = ["name": name, "refreshLibrary": "true"]
        if let collectionType = kind.collectionType { query["collectionType"] = collectionType }
        try await postVoid("Library/VirtualFolders", query: query,
                           json: ["LibraryOptions": ["PathInfos": folders.map { ["Path": $0] },
                                                     "EnableRealtimeMonitor": true]])
    }

    func removeLibrary(name: String) async throws {
        _ = try await request("Library/VirtualFolders", query: ["name": name, "refreshLibrary": "true"],
                              method: "DELETE")
    }

    func renameLibrary(_ name: String, to newName: String) async throws {
        try await postVoid("Library/VirtualFolders/Name", query: ["name": name, "newName": newName])
    }

    func addFolder(_ path: String, toLibrary name: String) async throws {
        try await postVoid("Library/VirtualFolders/Paths", query: ["refreshLibrary": "true"],
                           json: ["Name": name, "Path": path, "PathInfo": ["Path": path]])
    }

    func removeFolder(_ path: String, fromLibrary name: String) async throws {
        _ = try await request("Library/VirtualFolders/Paths",
                              query: ["name": name, "path": path, "refreshLibrary": "true"], method: "DELETE")
    }

    /// Looks for new, changed and removed files across every library.
    func scanLibraries() async throws {
        try await postVoid("Library/Refresh")
    }

    /// Re-reads metadata and artwork for one library (or any item).
    func refreshMetadata(itemId: String, replacingExisting: Bool) async throws {
        try await postVoid("Items/\(itemId)/Refresh", query: [
            "metadataRefreshMode": replacingExisting ? "FullRefresh" : "Default",
            "imageRefreshMode": replacingExisting ? "FullRefresh" : "Default",
            "replaceAllMetadata": replacingExisting ? "true" : "false",
            "replaceAllImages": "false",
            "Recursive": "true",
        ])
    }

    /// The server's background jobs, for showing what a scan is up to.
    func serverTasks() async throws -> [ServerTask] {
        try await get("ScheduledTasks")
    }

    // MARK: Plugins (Jellyfin, administrators)

    /// The plugins installed on the server, the ones it comes with included.
    func serverPlugins() async throws -> [ServerPlugin] {
        let plugins: [Lossy<ServerPlugin>] = try await get("Plugins")
        return plugins.compactMap(\.value)
    }

    /// What the repositories the server uses offer.
    func pluginCatalog() async throws -> [PluginPackage] {
        let packages: [Lossy<PluginPackage>] = try await get("Packages")
        return packages.compactMap(\.value)
    }

    /// The server fetches the release itself; it's in use after a restart.
    func installPlugin(_ package: PluginPackage, release: PluginRelease) async throws {
        var query = ["assemblyGuid": package.guid, "version": release.version]
        if let repository = release.repositoryUrl { query["repositoryUrl"] = repository }
        try await postVoid("Packages/Installed/\(package.name)", query: query)
    }

    func setPlugin(_ plugin: ServerPlugin, on: Bool) async throws {
        try await postVoid("Plugins/\(plugin.id)/\(plugin.version)/\(on ? "Enable" : "Disable")")
    }

    func uninstallPlugin(_ plugin: ServerPlugin) async throws {
        _ = try await request("Plugins/\(plugin.id)/\(plugin.version)", method: "DELETE")
    }

    func serverRestartState() async throws -> ServerRestartState {
        let info: SystemRestartInfo = try await get("System/Info")
        return ServerRestartState(version: info.version ?? "0", pendingRestart: info.hasPendingRestart ?? false,
                                  canRestart: info.canSelfRestart ?? false)
    }

    func restartServer() async throws {
        try await postVoid("System/Restart")
    }

    // MARK: - New-episode alerts
    #if !EXTENSION

    /// The episodes the server added last, newest first, with when.
    func recentlyAddedEpisodes(limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: [
            "IncludeItemTypes": "Episode", "Recursive": "true", "SortBy": "DateCreated", "SortOrder": "Descending",
            "Limit": "\(limit)", "Fields": "DateCreated,SeriesPrimaryImageTag", "IsMissing": "false",
            // Not counted: tens of thousands of episodes, for a number nobody reads.
            "EnableTotalRecordCount": "false",
        ])
        return result.items
    }

    /// The shows this account watches: those with an episode watched (of the
    /// last few hundred), those up next, and its favourites.
    func followedSeriesIds() async throws -> Set<String> {
        let uid = try requireUser()
        async let watched: ItemsResult = get("Users/\(uid)/Items", query: [
            "IncludeItemTypes": "Episode", "Recursive": "true", "Filters": "IsPlayed", "SortBy": "DatePlayed",
            "SortOrder": "Descending", "Limit": "400", "EnableImages": "false",
        ])
        async let upNext: ItemsResult = get("Shows/NextUp", query: ["UserId": uid, "Limit": "200", "EnableImages": "false"])
        async let favourites: ItemsResult = get("Users/\(uid)/Items", query: [
            "IncludeItemTypes": "Series", "Recursive": "true", "Filters": "IsFavorite", "EnableImages": "false",
        ])
        // Awaited in the order they were declared (see `extras`).
        let seen = try await watched.items.compactMap(\.seriesId)
        let next = try await upNext.items.compactMap(\.seriesId)
        let liked = try await favourites.items.map(\.id)
        return Set(seen + next + liked)
    }
    #endif

    // MARK: - Dashboard (administrators)
    #if !EXTENSION

    /// Every session seen in the last quarter of an hour.
    func dashboardSessions() async throws -> [ServerSession] {
        try await get("Sessions", query: ["ActiveWithinSeconds": "960"])
    }

    func scheduledTasks() async throws -> [ScheduledTask] {
        try await get("ScheduledTasks", query: ["IsHidden": "false"])
    }

    func activityLog(limit: Int) async throws -> [ActivityEntry] {
        let page: ActivityPage = try await get("System/ActivityLog/Entries", query: ["StartIndex": "0", "Limit": "\(limit)"])
        return page.items
    }

    func dashboardInfo() async throws -> ServerSystemInfo {
        try await get("System/Info")
    }

    func runTask(_ id: String) async throws {
        try await postVoid("ScheduledTasks/Running/\(id)")
    }

    func stopTask(_ id: String) async throws {
        _ = try await request("ScheduledTasks/Running/\(id)", method: "DELETE")
    }

    /// Stops what a session is playing, as its own Stop would.
    func stopPlayback(session: String) async throws {
        try await postVoid("Sessions/\(session)/Playing/Stop")
    }

    /// A message over what a session is playing, for ten seconds.
    func sendMessage(session: String, text: String) async throws {
        try await postVoid("Sessions/\(session)/Message", json: ["Header": "JellyGoose", "Text": text, "TimeoutMs": 10_000])
    }
    #endif

    private struct SystemRestartInfo: Decodable {
        let version: String?
        let hasPendingRestart: Bool?
        let canSelfRestart: Bool?
    }

    /// Folders on the server. A nil path lists the roots it offers.
    func serverFolders(at path: String?) async throws -> [FileSystemEntry] {
        guard let path else { return try await get("Environment/Drives") }
        return try await get("Environment/DirectoryContents",
                             query: ["path": path, "includeFiles": "false", "includeDirectories": "true"])
    }

    /// How many items a library holds, which climbs while a scan runs.
    func itemCount(inLibrary parentId: String, types: String) async throws -> Int {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: [
            "ParentId": parentId,
            "Recursive": "true",
            "IncludeItemTypes": types,
            "Limit": "0",
        ])
        return result.totalRecordCount ?? 0
    }

    // MARK: - Account preferences

    /// The user's full Jellyfin configuration, untyped so saving it back
    /// preserves fields GooseTV doesn't know about.
    func userConfiguration() async throws -> [String: Any] {
        try await userDetails().configuration
    }

    func saveUserConfiguration(_ configuration: [String: Any]) async throws {
        let uid = try requireUser()
        try await postToMovedRoute("Users/Configuration", query: ["userId": uid],
                                   or: "Users/\(uid)/Configuration", json: configuration)
    }

    /// Jellyfin 10.9 moved some per-user routes; Emby and older Jellyfin have
    /// only the old one. The old one is tried only when the new one isn't
    /// there (10.8 reads the new path as a user id and answers 400): a refusal
    /// or a dropped connection would only be the same answer twice.
    private func postToMovedRoute(_ path: String, query: [String: String], or oldPath: String,
                                  json: [String: Any]) async throws {
        if flavor == .jellyfin {
            do {
                try await postVoid(path, query: query, json: json)
                return
            } catch ServerError.badResponse(let code) where [400, 404, 405].contains(code) {
                // An older Jellyfin: on to the old route.
            }
        }
        try await postVoid(oldPath, json: json)
    }

    /// Forgets the resume point, which takes the item off Continue Watching.
    func clearResumePosition(_ itemId: String) async throws {
        try await setResumePosition(itemId, ticks: 0)
    }

    /// Where the viewer got to, told after the fact: a download watched
    /// offline, whose progress reports never reached the server.
    func setResumePosition(_ itemId: String, ticks: Int64) async throws {
        let uid = try requireUser()
        try await postToMovedRoute("UserItems/\(itemId)/UserData", query: ["userId": uid],
                                   or: "Users/\(uid)/Items/\(itemId)/UserData",
                                   json: ["PlaybackPositionTicks": ticks])
    }

    /// An account's picture, or nil for one without.
    func userImageURL(userId: String, tag: String?) -> URL? {
        guard let tag else { return nil }
        return url(path: "Users/\(userId)/Images/Primary",
                   query: ["maxWidth": "240", "quality": "90", "tag": tag])
    }

    /// The accounts the server shows on its own sign-in screen. None on a
    /// server that hides them all, which is a common choice.
    func publicUsers() async -> [PublicUser] {
        (try? await get("Users/Public")) ?? []
    }

    func personImageURL(_ person: Person, maxWidth: Int = 300) -> URL? {
        guard let tag = person.primaryImageTag else { return nil }
        return url(path: "Items/\(person.id)/Images/Primary",
                   query: ["maxWidth": "\(maxWidth)", "quality": "90", "tag": tag])
    }

    // MARK: - Playback

    /// Jellyfin 10.10 and later report marked segments here, usually filled in
    /// by the Intro Skipper plugin. Emby has no equivalent, and a server with
    /// neither answers 404 — all of which mean the same thing to the player, so
    /// the failure is swallowed rather than surfaced.
    func skipSegments(for itemId: String) async -> [SkipSegment] {
        guard flavor == .jellyfin else { return [] }
        let native = await nativeSegments(for: itemId)
        // The plugin answered on its own endpoints long before Jellyfin had
        // anywhere to put this, and still does — a server can have the data and
        // report none here, which is how a show that skips in other clients
        // skipped in none of ours.
        return native.isEmpty ? await pluginSegments(for: itemId) : native
    }

    func stillWatching(liveStreamId: String, channelId: String?) async -> Bool? {
        guard let sessions: [PlayingSession] = try? await get("Sessions", query: ["DeviceId": Self.deviceId]) else { return nil }
        return sessions.contains { session in
            session.deviceId == Self.deviceId
                && (session.playState?.liveStreamId == liveStreamId
                    || (channelId != nil && session.nowPlayingItem?.id == channelId))
        }
    }

    func transcoding(of itemId: String) async -> TranscodingInfo? {
        guard let sessions: [PlayingSession] = try? await get("Sessions", query: ["DeviceId": Self.deviceId]) else { return nil }
        return sessions.first { $0.deviceId == Self.deviceId && $0.nowPlayingItem?.id == itemId }?.transcodingInfo
    }

    func remoteSubtitles(for itemId: String, language: String) async throws -> [RemoteSubtitle] {
        try await get("Items/\(itemId)/RemoteSearch/Subtitles/\(language)")
    }

    func downloadRemoteSubtitle(_ subtitleId: String, for itemId: String) async throws {
        try await postVoid("Items/\(itemId)/RemoteSearch/Subtitles/\(subtitleId)")
    }

    func subtitles(of item: BaseItem, mediaSourceId: String?) -> (streams: [MediaStream], files: [SubtitleFile], drawable: [Int: URL]) {
        let sources = item.mediaSources ?? []
        guard let source = mediaSourceId.flatMap({ id in sources.first { $0.id == id } }) ?? sources.first else {
            return ([], [], [:])
        }
        return (source.mediaStreams ?? [], subtitleFiles(item: item, source: source),
                drawableSubtitles(item: item, source: source, externalOnly: false))
    }

    private func nativeSegments(for itemId: String) async -> [SkipSegment] {
        guard let result: MediaSegmentsResult = try? await get("MediaSegments/\(itemId)") else { return [] }
        return result.items.compactMap { segment in
            guard let start = segment.startTicks, let end = segment.endTicks, end > start else { return nil }
            let kind: SkipSegment.Kind
            switch segment.type?.lowercased() {
            case "intro": kind = .intro
            case "outro": kind = .outro
            // The breaks in a recording made off the air, where the server
            // has something that finds them (a commercial detector run over
            // its recordings).
            case "commercial": kind = .commercial
            // "Previously on", and the look at the next episode.
            case "recap": kind = .recap
            case "preview": kind = .preview
            default: return nil
            }
            return SkipSegment(kind: kind,
                               start: Double(start) / 10_000_000,
                               end: Double(end) / 10_000_000)
        }
    }

    /// Intro Skipper's own routes, newest spelling first. Each is tried and the
    /// first that answers wins; a server without the plugin answers 404 to all
    /// of them, which is the same as having nothing to skip.
    private func pluginSegments(for itemId: String) async -> [SkipSegment] {
        if let named: [String: PluginSegment] = try? await get("Episode/\(itemId)/IntroSkipperSegments") {
            // Dictionary keys come through the decoder lowercased, like every
            // other key it rewrites.
            let found = named.compactMap { key, segment -> SkipSegment? in
                guard let range = segment.range else { return nil }
                let name = key.lowercased()
                let kind: SkipSegment.Kind = name.hasPrefix("credit") ? .outro
                    : name.hasPrefix("recap") ? .recap
                    : name.hasPrefix("preview") ? .preview
                    : name.hasPrefix("commercial") ? .commercial : .intro
                return SkipSegment(kind: kind, start: range.start, end: range.end)
            }
            if !found.isEmpty { return found.sorted { $0.start < $1.start } }
        }
        if let single: PluginSegment = try? await get("Episode/\(itemId)/IntroTimestamps/v1"),
           let range = single.range {
            return [SkipSegment(kind: .intro, start: range.start, end: range.end)]
        }
        return []
    }

    func playbackContext(for item: BaseItem, startTicks: Int64,
                         audioIndex: Int?, subtitleIndex: Int?,
                         mediaSourceId: String?) async throws -> PlaybackContext {
        try await playbackContext(for: item, startTicks: startTicks, audioIndex: audioIndex,
                                  subtitleIndex: subtitleIndex, mediaSourceId: mediaSourceId,
                                  systemPlayerOnly: false)
    }

    /// The sound alone, for a car that shows no picture: the server's
    /// soundtrack of the film as AAC in short pieces, the whole film long so
    /// it can be moved through, a few per cent of the data a picture takes.
    /// It begins at the film's start: the player goes to `startTicks` itself.
    func audioOnlyContext(for item: BaseItem, startTicks: Int64, audioIndex: Int?) -> PlaybackContext? {
        guard let token, let source = item.mediaSources?.first, let sourceId = source.id else { return nil }
        let playSession = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var query = ["MediaSourceId": sourceId, "PlaySessionId": playSession, "DeviceId": Self.deviceId,
                     "AudioCodec": "aac", "AudioBitrate": "192000", "MaxAudioChannels": "2",
                     "SegmentContainer": "ts"]
        if let audioIndex { query["AudioStreamIndex"] = String(audioIndex) }
        // ApiKey, not api_key, on Jellyfin: these routes refuse the older spelling.
        if flavor == .jellyfin { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
        var context = PlaybackContext(url: url(path: "Audio/\(item.id)/master.m3u8", query: query), item: item,
                                      mediaSourceId: sourceId, playSessionId: playSession, isDirect: false,
                                      startTicks: startTicks, streamStartsAtZero: true, engine: .avPlayer,
                                      mediaStreams: source.mediaStreams ?? [],
                                      defaultSubtitleIndex: source.defaultSubtitleStreamIndex)
        context.audioIndex = audioIndex
        return context
    }

    /// `systemPlayerOnly` leaves VLC and AetherEngine out of it: the stream
    /// is one Apple's player takes, converted by the server if need be, for
    /// where only that player will do (AirPlay to a car). Nothing draws a
    /// subtitle over the picture there, so a subtitle asked for is burnt in.
    func playbackContext(for item: BaseItem, startTicks: Int64,
                         audioIndex: Int?, subtitleIndex: Int?,
                         mediaSourceId: String?, systemPlayerOnly: Bool) async throws -> PlaybackContext {
        // This device's limits: a bitrate ceiling, and optionally no direct play.
        let maxBitrate = PlaybackPreferences.maxBitrate
        let allowDirect = PlaybackPreferences.allowDirectPlay
        // Named even when there is only one version: Jellyfin applies a chosen
        // audio or subtitle track only to the source the request names, and
        // with none named it quietly used its own default, so a subtitle picked
        // from the panel never arrived.
        let mediaSourceId = mediaSourceId ?? item.mediaSources?.first?.id

        // The item already describes its file, which settles two questions
        // before the server is asked anything: whether it's VLC's to play, and
        // whether the subtitle wanted is one the app draws. Each used to cost a
        // second PlaybackInfo round trip after the first.
        let known = mediaSourceId.flatMap { id in item.mediaSources?.first { $0.id == id } } ?? item.mediaSources?.first
        let knownStreams = known?.mediaStreams ?? []
        let knownSubtitle = subtitleIndex ?? known?.defaultSubtitleStreamIndex
        if allowDirect, !systemPlayerOnly, let known, !knownStreams.isEmpty {
            let picture = knownStreams.contains { $0.index == knownSubtitle && $0.isEmbeddedPictureSubtitle }
            // Played from the file on the Apple TV rather than converted by the server.
            let onDevice = OnDevicePlayback.wanted(item, source: known, audioIndex: audioIndex,
                                                   subtitleIndex: subtitleIndex, maxBitrate: maxBitrate)
            // AetherEngine draws a picture subtitle itself, so one only needs
            // VLC for a film the engine isn't playing.
            if wantsVLC(known, maxBitrate: maxBitrate, pictureSubtitle: picture && !onDevice),
               let vlc = await directContext(item: item, sourceId: known.id, startTicks: startTicks,
                                             maxBitrate: maxBitrate, subtitleIndex: subtitleIndex,
                                             audioIndex: audioIndex) {
                return vlc
            }
            if onDevice,
               let onDevice = await directContext(item: item, sourceId: known.id, startTicks: startTicks,
                                                  maxBitrate: maxBitrate, subtitleIndex: subtitleIndex,
                                                  audioIndex: audioIndex, engine: .aether) {
                return onDevice
            }
        }
        // A text subtitle is drawn by the app, never carried in the stream (see
        // below), so the stream is asked for without one from the start.
        let knownText = !systemPlayerOnly && knownSubtitle.flatMap { index in
            knownStreams.first { $0.index == index && $0.type == "Subtitle" && $0.isTextSubtitleStream != false }
        } != nil
        let profile = systemPlayerOnly ? DeviceProfile.burningSubtitles : DeviceProfile.appleTV
        var info = try await playbackInfo(for: item, startTicks: startTicks, profile: profile,
                                          maxBitrate: maxBitrate, allowDirect: allowDirect,
                                          audioIndex: audioIndex,
                                          subtitleIndex: knownText ? PlaybackContext.subtitlesOff : subtitleIndex,
                                          mediaSourceId: mediaSourceId)
        // A film kept in more than one version — a 4K remux beside a 1080p
        // encode — has a source each. Without a choice the server's first is
        // as good as any.
        let chosen = mediaSourceId.flatMap { id in info.mediaSources.first { $0.id == id } }
        guard var source = chosen ?? info.mediaSources.first else { throw ServerError.noPlayableSource }
        // Asked for with none, the server's default reads as none; the item said which.
        let wantedSubtitle = knownText ? knownSubtitle : (subtitleIndex ?? source.defaultSubtitleStreamIndex)
        let streams = source.mediaStreams ?? []

        // Files AVPlayer can't decode go to VLC as-is, rather than making the server transcode.
        // So do films whose subtitle is a picture (PGS, DVD): AVPlayer can only
        // have those burnt into the video, which means re-encoding all of it.
        let wantsPictureSubtitle = streams.contains { stream in
            stream.index == wantedSubtitle && stream.isEmbeddedPictureSubtitle
        }
        // (Decided above when the item described its file; this is for one that didn't.)
        if allowDirect, !systemPlayerOnly, knownStreams.isEmpty,
           wantsVLC(source, maxBitrate: maxBitrate, pictureSubtitle: wantsPictureSubtitle),
           let vlc = await directContext(item: item, sourceId: source.id, startTicks: startTicks,
                                         maxBitrate: maxBitrate, subtitleIndex: subtitleIndex,
                                         audioIndex: audioIndex) {
            return vlc
        }

        // Text subtitles the app draws itself, from one WebVTT file each in the
        // film's own time. Jellyfin's HLS subtitles run ten seconds late over
        // the fragmented MP4 HEVC has to travel in, and AVPlayer won't let
        // them be corrected; drawing them all also keeps the choice in one
        // menu. A direct-played file shows its own subtitles on time, so there
        // only the files beside it are drawn.
        let playable = (source.supportsDirectPlay ?? false) || (source.supportsDirectStream ?? false)
        let direct = allowDirect && playable
        let drawable = drawableSubtitles(item: item, source: source, externalOnly: direct)
        if direct {
            return PlaybackContext(url: staticStreamURL(item: item, source: source, playSessionId: info.playSessionId),
                                   item: item, mediaSourceId: source.id,
                                   playSessionId: info.playSessionId, isDirect: true, startTicks: startTicks,
                                   mediaStreams: source.mediaStreams ?? [],
                                   audioIndex: audioIndex,
                                   subtitleIndex: wantedSubtitle.flatMap { drawable[$0] == nil ? nil : $0 },
                                   trickplay: trickplay(item: item, sourceId: source.id),
                                   drawableSubtitles: drawable)
        }
        // The stream carries no text subtitle: one there would only be offered
        // again in AVPlayer's menu, late. A picture subtitle stays, burnt in,
        // since it only reaches here when the film is too big for VLC to play.
        if !knownText, !systemPlayerOnly, let wantedSubtitle, drawable[wantedSubtitle] != nil {
            info = try await playbackInfo(for: item, startTicks: startTicks, profile: DeviceProfile.appleTV,
                                          maxBitrate: maxBitrate, allowDirect: allowDirect,
                                          audioIndex: audioIndex, subtitleIndex: PlaybackContext.subtitlesOff,
                                          mediaSourceId: source.id)
            source = info.mediaSources.first { $0.id == source.id } ?? info.mediaSources.first ?? source
        }
        // 12-second segments instead of Jellyfin's 6. AVPlayer abandons a segment request
        // after half the segment length, and starting a 4K remux (probing the file, audio
        // conversion) takes the server ~2.5s: with 6s segments that raced AVPlayer's 3s
        // limit, and every abandoned retry restarted the wait, so playback kept stalling.
        if let transcodePath = source.transcodingUrl,
           let masterURL = URL(string: transcodePath + "&SegmentLength=12", relativeTo: baseURL) {
            let transcodeURL = await preferStreamCopy(masterURL)
            // A variant playlist carries none of the master's query, the resume
            // point included, so it runs from the top of the film: the player
            // seeks into it. The master keeps its offset and does not.
            // Whether the stream begins at the top of the film is a question of
            // what the url asks for, not of which playlist was chosen: a variant
            // carries none of the master's query, and a master does not always
            // carry an offset either.
            // Emby lists the whole film from zero and marks where to begin
            // (EXT-X-START), so its clock is already the film's, offset or not.
            var fromZero = startTime(in: transcodeURL) == 0
            if !fromZero, flavor == .emby { fromZero = await playlistMarksStart(transcodeURL) }
            return PlaybackContext(url: transcodeURL, item: item, mediaSourceId: source.id,
                                   playSessionId: info.playSessionId, isDirect: false,
                                   startTicks: startTicks, streamStartsAtZero: fromZero,
                                   mediaStreams: source.mediaStreams ?? [],
                                   audioIndex: audioIndex ?? source.defaultAudioStreamIndex,
                                   subtitleIndex: wantedSubtitle,
                                   trickplay: trickplay(item: item, sourceId: source.id),
                                   drawableSubtitles: drawable)
        }
        throw ServerError.noPlayableSource
    }

    private func playbackInfo(for item: BaseItem, startTicks: Int64, profile: [String: Any],
                              maxBitrate: Int, allowDirect: Bool,
                              audioIndex: Int?, subtitleIndex: Int?,
                              mediaSourceId: String?) async throws -> PlaybackInfoResponse {
        let uid = try requireUser()
        var profile = profile
        profile["MaxStreamingBitrate"] = maxBitrate
        profile["MaxStaticBitrate"] = maxBitrate
        var query = [
            "UserId": uid,
            "StartTimeTicks": "\(startTicks)",
            "IsPlayback": "true",
            "AutoOpenLiveStream": "true",
            "MaxStreamingBitrate": "\(maxBitrate)",
        ]
        // A transcode bakes the chosen tracks in, so they are part of the ask.
        if let audioIndex { query["AudioStreamIndex"] = "\(audioIndex)" }
        if let subtitleIndex { query["SubtitleStreamIndex"] = "\(subtitleIndex)" }
        if let mediaSourceId { query["MediaSourceId"] = mediaSourceId }
        return try await post("Items/\(item.id)/PlaybackInfo", query: query, json: [
            "DeviceProfile": profile,
            "MaxStreamingBitrate": maxBitrate,
            "EnableDirectPlay": allowDirect,
            "EnableDirectStream": allowDirect,
        ])
    }

    /// VLC's stream of the file, when the server agrees it can go as it is.
    /// The original file, as it is, for an engine that plays it on the device.
    private func directContext(item: BaseItem, sourceId: String?, startTicks: Int64,
                               maxBitrate: Int, subtitleIndex: Int?, audioIndex: Int? = nil,
                               engine: PlaybackEngine = .vlc) async -> PlaybackContext? {
        guard let vlc = try? await playbackInfo(for: item, startTicks: startTicks, profile: DeviceProfile.vlc,
                                                maxBitrate: maxBitrate, allowDirect: true,
                                                audioIndex: nil, subtitleIndex: nil, mediaSourceId: sourceId),
              let vlcSource = vlc.mediaSources.first(where: { $0.id == sourceId }) ?? vlc.mediaSources.first,
              vlcSource.supportsDirectPlay ?? false else { return nil }
        return PlaybackContext(url: staticStreamURL(item: item, source: vlcSource, playSessionId: vlc.playSessionId),
                               item: item, mediaSourceId: vlcSource.id, playSessionId: vlc.playSessionId,
                               isDirect: true, startTicks: startTicks, engine: engine,
                               mediaStreams: vlcSource.mediaStreams ?? [],
                               audioIndex: audioIndex ?? vlcSource.defaultAudioStreamIndex,
                               subtitleFiles: subtitleFiles(item: item, source: vlcSource),
                               defaultSubtitleIndex: subtitleIndex ?? vlcSource.defaultSubtitleStreamIndex,
                               trickplay: trickplay(item: item, sourceId: vlcSource.id))
    }

    /// VLC plays a source when asked to always, when AVPlayer can't decode its video,
    /// or when the subtitle wanted is a picture, as long as the original fits under
    /// the quality cap (VLC plays it untranscoded).
    private func wantsVLC(_ source: MediaSource, maxBitrate: Int, pictureSubtitle: Bool) -> Bool {
        if let bitrate = source.bitrate, bitrate > maxBitrate { return false }
        if PlaybackPreferences.alwaysVLC || pictureSubtitle { return true }
        if PlaybackPreferences.vlcForMKV {
            let mkv = source.container?.lowercased().split(separator: ",").contains { $0 == "mkv" || $0 == "matroska" || $0 == "webm" } ?? false
            let dolbyVision = source.mediaStreams?.contains { $0.type == "Video" && ($0.videoRangeType ?? "").hasPrefix("DOVI") } ?? false
            if mkv && !dolbyVision { return true }
        }
        guard let codec = source.mediaStreams?.first(where: { $0.type == "Video" })?.codec?.lowercased() else {
            return false
        }
        return !PlaybackPreferences.nativeVideoCodecs.contains(codec)
    }

    /// The scrubbing thumbnails nearest 320 wide — Jellyfin's default, and
    /// plenty for a frame above the timeline.
    private func trickplay(item: BaseItem, sourceId: String?) -> Trickplay? {
        guard let sourceId, let byWidth = item.trickplay?[sourceId] ?? item.trickplay?.values.first,
              let info = byWidth.values.min(by: { abs($0.width - 320) < abs($1.width - 320) }) else { return nil }
        let perSheet = max(info.tileWidth * info.tileHeight, 1)
        let sheets = (info.thumbnailCount + perSheet - 1) / perSheet
        // ApiKey, not api_key: this route refuses the older spelling.
        var query = ["MediaSourceId": sourceId]
        if let token { query["ApiKey"] = token }
        let urls = (0..<sheets).map { url(path: "Videos/\(item.id)/Trickplay/\(info.width)/\($0).jpg", query: query) }
        return Trickplay(info: info, sheetURLs: urls)
    }

    /// Every text subtitle the app can draw, by the server's index: each as one
    /// WebVTT file in the film's own time. Only the files beside the film when
    /// `externalOnly`.
    private func drawableSubtitles(item: BaseItem, source: MediaSource, externalOnly: Bool) -> [Int: URL] {
        guard let sourceId = source.id else { return [:] }
        let query = tokenQuery
        var urls: [Int: URL] = [:]
        for stream in source.mediaStreams ?? [] {
            guard stream.type == "Subtitle", stream.isTextSubtitleStream != false, let index = stream.index,
                  !externalOnly || stream.isExternal == true else { continue }
            urls[index] = url(path: "Videos/\(item.id)/\(sourceId)/Subtitles/\(index)/Stream.vtt", query: query)
        }
        return urls
    }

    /// Where VLC can fetch each subtitle file kept beside the film.
    private func subtitleFiles(item: BaseItem, source: MediaSource) -> [SubtitleFile] {
        guard let sourceId = source.id else { return [] }
        let query = tokenQuery
        return (source.mediaStreams ?? []).compactMap { stream -> SubtitleFile? in
            guard stream.isExternalTextSubtitle, let index = stream.index else { return nil }
            let format: String
            switch stream.codec?.lowercased() {
            case "subrip", nil: format = "srt"
            case "webvtt": format = "vtt"
            case let codec?: format = codec
            }
            return SubtitleFile(index: index, name: stream.trackName,
                                url: url(path: "Videos/\(item.id)/\(sourceId)/Subtitles/\(index)/Stream.\(format)",
                                         query: query))
        }
    }

    private func staticStreamURL(item: BaseItem, source: MediaSource, playSessionId: String?) -> URL {
        var query = tokenQuery
        query["static"] = "true"
        if let msId = source.id { query["mediaSourceId"] = msId }
        if let playSessionId { query["playSessionId"] = playSessionId }
        return url(path: "Videos/\(item.id)/stream", query: query)
    }

    /// The offset a streaming url asks the server to start at, zero if it asks
    /// for none.
    private func startTime(in url: URL) -> Int64 {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        let value = items.first { $0.name.caseInsensitiveCompare("StartTimeTicks") == .orderedSame }?.value
        return Int64(value ?? "") ?? 0
    }

    /// Whether the playlist (or the first variant of a master) lists the film
    /// from its start and says where to begin, rather than beginning there.
    private func playlistMarksStart(_ url: URL) async -> Bool {
        guard let (data, _) = try? await session.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        if text.contains("#EXT-X-START") { return true }
        guard text.contains("#EXT-X-STREAM-INF"),
              let variant = text.split(whereSeparator: \.isNewline).map(String.init)
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              let variantURL = URL(string: variant, relativeTo: url),
              let (variantData, _) = try? await session.data(from: variantURL.absoluteURL),
              let variantText = String(data: variantData, encoding: .utf8) else { return false }
        return variantText.contains("#EXT-X-START")
    }

    /// For an HDR remux, Jellyfin's master playlist lists two versions: the video copied
    /// as-is, and an SDR one it re-encodes (tone-mapped) on the fly. AVPlayer picks the SDR
    /// one whenever the TV isn't in HDR mode, and re-encoding 4K in real time is beyond most
    /// servers, so playback stalls constantly. Hand AVPlayer the copied version alone; on an
    /// SDR screen the Apple TV tone-maps HDR itself. A variant carries no subtitles, which is
    /// no loss: the app draws a transcode's subtitles itself.
    private func preferStreamCopy(_ master: URL) async -> URL {
        // Only a preference: the master itself plays, so it isn't worth a wait.
        let session = session
        guard let data = await withinDeadline(4, { try? await session.data(from: master).0 }),
              let playlist = String(data: data, encoding: .utf8) else { return master }
        let variants = playlist.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard variants.count > 1,
              let copy = variants.first(where: { !$0.contains("AllowVideoStreamCopy=false") }),
              let url = URL(string: copy, relativeTo: master) else { return master }
        return url.absoluteURL
    }

    // MARK: - Live TV

    func liveChannelCount() async throws -> Int {
        let uid = try requireUser()
        let result: LiveChannelsResult = try await get("LiveTv/Channels", query: [
            "UserId": uid,
            "Limit": "1",
            "AddCurrentProgram": "false",
            "EnableImages": "false",
            "EnableUserData": "false",
        ])
        return result.totalRecordCount ?? result.items.count
    }

    func liveChannels() async throws -> [LiveChannel] {
        let uid = try requireUser()
        let result: LiveChannelsResult = try await get("LiveTv/Channels", query: [
            "UserId": uid,
            "AddCurrentProgram": "true",
            "EnableUserData": "true",
            "EnableImages": "true",
            "EnableImageTypes": "Primary",
            "ImageTypeLimit": "1",
            // The programme's description comes with it only when asked for.
            "Fields": "Overview",
        ])
        return result.items.map(\.channel)
    }

    func liveGuide(channelIds: [String], from start: Date, to end: Date) async throws -> [LiveProgram] {
        let uid = try requireUser()
        // Posted, not put in the address: a tuner's worth of channel ids is
        // longer than an address should be.
        let result: LiveProgramsResult = try await post("LiveTv/Programs", json: [
            "UserId": uid,
            "ChannelIds": channelIds,
            // Over after the stretch begins and starting before it ends:
            // what's part-way through at either edge is wanted too.
            "MinEndDate": LiveDate.write(start),
            "MaxStartDate": LiveDate.write(end),
            "SortBy": ["StartDate"],
            "Fields": ["Overview"],
            "EnableImages": false,
            "EnableUserData": false,
            "EnableTotalRecordCount": false,
        ])
        return result.items.compactMap(\.program)
    }

    /// A channel is asked for as a film is, and with the profile of the
    /// player that takes anything: what an HDHomeRun sends over the air is
    /// MPEG-2 with Dolby Digital sound, interlaced as often as not, which
    /// Apple's player has no decoder for and VLC plays as it comes, tidying
    /// the picture itself. So the station's own stream is what's asked for,
    /// and the server converts only when the quality limit in Settings is
    /// under what the station sends (away from home, on a slow line).
    func openLiveStream(channelId: String) async throws -> LiveStream {
        let uid = try requireUser()
        let maxBitrate = PlaybackPreferences.maxBitrate
        let allowDirect = PlaybackPreferences.allowDirectPlay
        var profile = DeviceProfile.vlc
        profile["MaxStreamingBitrate"] = maxBitrate
        profile["MaxStaticBitrate"] = maxBitrate
        let info: PlaybackInfoResponse = try await post("Items/\(channelId)/PlaybackInfo", query: [
            "UserId": uid,
            "StartTimeTicks": "0",
            "IsPlayback": "true",
            // Without it the answer describes the channel and tunes nothing.
            "AutoOpenLiveStream": "true",
            "MaxStreamingBitrate": "\(maxBitrate)",
        ], json: [
            "DeviceProfile": profile,
            "MaxStreamingBitrate": maxBitrate,
            "EnableDirectPlay": allowDirect,
            "EnableDirectStream": allowDirect,
        ])
        guard let source = info.mediaSources.first else { throw ServerError.noPlayableSource }
        let direct = allowDirect && ((source.supportsDirectPlay ?? false) || (source.supportsDirectStream ?? false))
        let address: URL
        if direct {
            // Through the server, by its own address for the stream. The
            // source's path is no use from here: it names the server as the
            // server sees itself (127.0.0.1).
            var query = tokenQuery
            query["static"] = "true"
            if let id = source.id { query["mediaSourceId"] = id }
            if let live = source.liveStreamId { query["LiveStreamId"] = live }
            if let session = info.playSessionId { query["playSessionId"] = session }
            address = url(path: "Videos/\(channelId)/stream", query: query)
        } else if let path = source.transcodingUrl, let converted = URL(string: path, relativeTo: baseURL) {
            address = converted.absoluteURL
        } else {
            // Tuned, and nothing to play it by: let the tuner go again.
            let orphan = LiveStream(channelId: channelId, url: baseURL, liveStreamId: source.liveStreamId,
                                    mediaSourceId: source.id, playSessionId: info.playSessionId, isDirect: false)
            await reportLive(orphan, .stopped)
            throw ServerError.noPlayableSource
        }
        return LiveStream(channelId: channelId, url: address, liveStreamId: source.liveStreamId,
                          mediaSourceId: source.id, playSessionId: info.playSessionId, isDirect: direct)
    }

    /// A channel for the car, which plays through Apple's player: the server
    /// converts what the station sends into a stream it takes (see
    /// `DeviceProfile.carLive`). In a car that shows no picture, the sound
    /// alone, as AAC: the server converts only the sound, a fraction of the
    /// work and of the data. Let go of as any channel is, by the stop report
    /// (`reportLive`).
    func openCarLiveStream(channelId: String, audioOnly: Bool) async throws -> LiveStream {
        let uid = try requireUser()
        let maxBitrate = min(PlaybackPreferences.maxBitrate, 4_000_000)
        var profile = DeviceProfile.carLive
        profile["MaxStreamingBitrate"] = maxBitrate
        let info: PlaybackInfoResponse = try await post("Items/\(channelId)/PlaybackInfo", query: [
            "UserId": uid,
            "StartTimeTicks": "0",
            "IsPlayback": "true",
            "AutoOpenLiveStream": "true",
            "MaxStreamingBitrate": "\(maxBitrate)",
        ], json: [
            "DeviceProfile": profile,
            "MaxStreamingBitrate": maxBitrate,
            "EnableDirectPlay": false,
            "EnableDirectStream": false,
        ])
        guard let source = info.mediaSources.first else { throw ServerError.noPlayableSource }
        let address: URL?
        if audioOnly, let sourceId = source.id {
            // The server's sound-only stream; its HLS one (the universal
            // route) names a playlist for a channel that it then can't find.
            var query = ["MediaSourceId": sourceId, "DeviceId": Self.deviceId,
                         "AudioCodec": "aac", "AudioBitrate": "160000", "MaxAudioChannels": "2"]
            if let live = source.liveStreamId { query["LiveStreamId"] = live }
            if let session = info.playSessionId { query["PlaySessionId"] = session }
            if flavor == .jellyfin, let token { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
            address = url(path: "Audio/\(channelId)/stream.aac", query: query)
        } else {
            address = source.transcodingUrl.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        }
        let stream = LiveStream(channelId: channelId, url: address ?? baseURL, liveStreamId: source.liveStreamId,
                                mediaSourceId: source.id, playSessionId: info.playSessionId, isDirect: false)
        guard address != nil else {
            // Tuned, and nothing to play it by: let the tuner go again.
            await reportLive(stream, .stopped)
            throw ServerError.noPlayableSource
        }
        return stream
    }

    /// The newer broadcasts (ATSC 3.0) carry their sound as AC-4, which
    /// nothing here decodes and Jellyfin can't read either: asked to tune
    /// one, it sat on the request with a tuner taken for nobody, for as long
    /// as it was left. So a channel is asked about before it's asked for.
    /// The description takes no tuner.
    func livePlayable(channelId: String) async -> Bool? {
        guard let uid = try? requireUser() else { return nil }
        let asked: PlaybackInfoResponse? = try? await post("Items/\(channelId)/PlaybackInfo", query: ["UserId": uid],
                                                           json: ["DeviceProfile": DeviceProfile.vlc])
        guard let streams = asked?.mediaSources.first?.mediaStreams else { return nil }
        let sound = streams.filter { $0.type == "Audio" }.compactMap { $0.codec?.lowercased() }
        return sound.isEmpty || sound.contains { $0 != "ac4" }
    }

    @discardableResult
    func reportLive(_ stream: LiveStream, _ event: LiveEvent) async -> Bool {
        var body: [String: Any] = [
            "ItemId": stream.channelId,
            "PositionTicks": 0,
            "PlayMethod": stream.isDirect ? "DirectStream" : "Transcode",
            // There's no going back or forward in what's on the air.
            "CanSeek": false,
        ]
        if let id = stream.mediaSourceId { body["MediaSourceId"] = id }
        if let session = stream.playSessionId { body["PlaySessionId"] = session }
        if let live = stream.liveStreamId { body["LiveStreamId"] = live }
        switch event {
        case .started:
            return (try? await postVoid("Sessions/Playing", json: body)) != nil
        case .playing:
            return (try? await postVoid("Sessions/Playing/Progress", json: body)) != nil
        case .stopped:
            // The report is what lets the tuner go, played or not, and it's
            // all that's sent. One stream serves everyone on a channel, and
            // the server counts who's on it: closing the stream by name as
            // well took this device off the count twice, which with someone
            // else in the house on the same channel was their picture gone.
            return (try? await postVoid("Sessions/Playing/Stopped", json: body)) != nil
        }
    }

    /// The server lists a recording among its recordings from half a minute
    /// or so after it begins, as an item with the timer's name on it, and
    /// hands its file over by the byte while it's still writing it. (Its own
    /// way of playing one, a stream of the file from the top with no end
    /// and no going back, is no use for a picture to move about in.)
    func liveRecording(timerId: String) async -> (recording: LiveRecording, channelId: String?)? {
        guard flavor == .jellyfin, let uid = try? requireUser(),
              let found: ItemsResult = try? await get("LiveTv/Recordings", query: [
                  "UserId": uid, "IsInProgress": "true", "EnableImages": "false", "EnableUserData": "false",
              ]),
              let item = found.items.first(where: { $0.timerId == timerId }) else { return nil }
        // The item says which station by name only; the timer has its id.
        let timer = (try? await request("LiveTv/Timers/\(timerId)")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let recording = LiveRecording(timerId: timerId, file: signed("Items/\(item.id)/File"),
                                      stillGoing: signed("LiveTv/Timers/\(timerId)"))
        // Measured before it's handed over: how far back it goes is the
        // first thing asked of it. Off the main thread: it waits on the server.
        let measured = await Task.detached { recording.measure() != nil }.value
        return measured ? (recording, timer?["ChannelId"] as? String) : nil
    }

    func liveCanRecord() async -> Bool {
        guard let uid = try? requireUser(), let data = try? await request("Users/\(uid)"),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = user["Policy"] as? [String: Any] else { return false }
        // An administrator may whatever the account's own switch says: the
        // server's first account has it off, and records all the same.
        return policy["IsAdministrator"] as? Bool == true || policy["EnableLiveTvManagement"] as? Bool == true
    }

    /// The server is asked what it would do with the programme by itself
    /// (how early to start, how late to stop, what to keep), and told to do
    /// just that: those are settings of its DVR, which is where to change
    /// them. For a series the same answer makes the series' recording.
    func liveRecord(programId: String, series: Bool) async throws {
        let data = try await request("LiveTv/Timers/Defaults", query: ["programId": programId])
        guard let defaults = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError.badResponse(0)
        }
        try await postVoid(series ? "LiveTv/SeriesTimers" : "LiveTv/Timers", json: defaults)
    }

    func liveCancelRecording(timerId: String) async throws {
        _ = try await request("LiveTv/Timers/\(timerId)", method: "DELETE")
    }

    func liveCancelSeries(timerId: String) async throws {
        _ = try await request("LiveTv/SeriesTimers/\(timerId)", method: "DELETE")
    }

    func liveScheduled() async throws -> (timers: [LiveTimer], series: [LiveSeriesTimer]) {
        async let timers: LiveTimersResult = get("LiveTv/Timers")
        async let series: LiveSeriesTimersResult = get("LiveTv/SeriesTimers", query: ["SortBy": "SortName"])
        return try await (timers.items.compactMap(\.timer).sorted { $0.start < $1.start }, series.items.map(\.timer))
    }

    /// The series' recording as the server has it, with these changed: the
    /// rest of it (padding, days, priority) goes back as it came.
    func liveSetSeries(timerId: String, _ options: LiveSeriesOptions) async throws {
        let data = try await request("LiveTv/SeriesTimers/\(timerId)")
        guard var timer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError.badResponse(0)
        }
        timer["RecordNewOnly"] = options.newOnly
        timer["RecordAnyChannel"] = options.anyChannel
        timer["RecordAnyTime"] = options.anyTime
        timer["KeepUpTo"] = options.keepUpTo
        try await postVoid("LiveTv/SeriesTimers/\(timerId)", json: timer)
    }

    func fileRequest(itemId: String) -> URLRequest? {
        flavor == .jellyfin ? signed("Items/\(itemId)/File") : nil
    }

    func liveRecordingFolders() async -> Set<String> {
        guard let uid = try? requireUser(),
              let folders: ItemsResult = try? await get("LiveTv/Recordings/Folders", query: ["userId": uid]) else { return [] }
        // The libraries kept for recordings, and not a library of shows or films the
        // server also records into: with its series (or film) recording path inside the
        // TV library, as many set it up so recorded shows sit among the rest, the server
        // counts the whole TV library among these. Listed a recording at a time, that
        // library became every episode of every show on its own card (reported on 1.7.1).
        // Such a library is listed as the shows or films it holds.
        return Set(folders.items.filter { !Self.titleLibraryTypes.contains($0.collectionType ?? "") }.map(\.id))
    }

    /// Libraries listed by their titles, whatever the server records into them.
    static let titleLibraryTypes: Set<String> = ["tvshows", "movies"]

    func recordings(in parentId: String, itemTypes: String, genres: [String], years: [Int], filters: [String]) async throws -> [BaseItem] {
        let uid = try requireUser()
        var query = [
            "ParentId": parentId,
            "Recursive": "true",
            "IncludeItemTypes": itemTypes,
            "SortBy": "DateCreated,SortName",
            "SortOrder": "Descending",
            "Limit": "2000",
            "Fields": "SortName,DateCreated,DateLastMediaAdded,Path,ProductionYear,PremiereDate,PrimaryImageAspectRatio",
        ]
        if !genres.isEmpty { query["Genres"] = genres.joined(separator: "|") }
        if !years.isEmpty { query["Years"] = years.map(String.init).joined(separator: ",") }
        if !filters.isEmpty { query["Filters"] = filters.joined(separator: ",") }
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(query))
        return result.items
    }

    func guideProgramme(named name: String) async -> BaseItem? {
        guard let uid = try? requireUser(),
              let found: ItemsResult = try? await get("Items", query: listQuery([
                  "userId": uid,
                  "IncludeItemTypes": "LiveTvProgram",
                  "SearchTerm": name,
                  "Recursive": "true",
                  "Limit": "8",
                  "EnableUserData": "false",
                  "Fields": "PrimaryImageAspectRatio",
              ])) else { return nil }
        // By that name exactly: a search finds every programme with the words in it.
        return found.items.first {
            $0.name?.caseInsensitiveCompare(name) == .orderedSame && $0.imageTags?["Primary"] != nil
        }
    }

    func recordingPlace(_ itemId: String, among folders: Set<String>) async -> (isRecording: Bool, pictured: BaseItem?) {
        guard !folders.isEmpty, let uid = try? requireUser(),
              let above: [BaseItem] = try? await get("Items/\(itemId)/Ancestors", query: ["userId": uid]) else { return (false, nil) }
        // Nearest first: the folder it's in, not a library or the drive.
        let folder = above.first.flatMap { $0.type == "Folder" && $0.imageTags?["Primary"] != nil ? $0 : nil }
        return (above.contains { folders.contains($0.id) }, folder)
    }

    // MARK: - Watching together

    func syncPlayAccess() async -> SyncPlayAccess {
        guard flavor == .jellyfin, let uid = try? requireUser(), let data = try? await request("Users/\(uid)"),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = user["Policy"] as? [String: Any] else { return .none }
        switch policy["SyncPlayAccess"] as? String {
        case "CreateAndJoinGroups": return .create
        case "JoinGroups": return .join
        default: return .none
        }
    }

    func syncPlayGroups() async throws -> [SyncPlayGroupInfo] {
        try await get("SyncPlay/List")
    }

    func syncPlay(_ request: String, _ body: [String: Any]?) async throws {
        try await postVoid("SyncPlay/\(request)", json: body ?? [:])
    }

    func serverClock() async throws -> (received: Date, sent: Date) {
        struct Clock: Decodable {
            let requestReceptionTime: String
            let responseTransmissionTime: String
        }
        let clock: Clock = try await get("GetUtcTime")
        guard let received = ServerTime.parse(clock.requestReceptionTime),
              let sent = ServerTime.parse(clock.responseTransmissionTime) else { throw ServerError.badResponse(0) }
        return (received, sent)
    }

    func localTrailers(of itemId: String) async -> [BaseItem] {
        guard let uid = try? requireUser() else { return [] }
        return (try? await get("Users/\(uid)/Items/\(itemId)/LocalTrailers")) ?? []
    }

    func themeSongs(of itemId: String) async -> [BaseItem] {
        guard let uid = try? requireUser(),
              let found: ItemsResult = try? await get("Items/\(itemId)/ThemeSongs",
                                                       query: ["userId": uid, "inheritFromParent": "true"]) else { return [] }
        return found.items
    }

    func songURL(itemId: String) -> URL? {
        guard let token else { return nil }
        var query = ["static": "true"]
        // ApiKey, not api_key, on Jellyfin: its newer routes refuse the older spelling.
        if flavor == .jellyfin { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
        return url(path: "Audio/\(itemId)/stream", query: query)
    }

    // MARK: - Music

    func music(_ kind: MusicKind, in libraryId: String, startIndex: Int, limit: Int,
               sortBy: String, sortOrder: String) async throws -> ItemsResult {
        let uid = try requireUser()
        var query = [
            "ParentId": libraryId,
            "StartIndex": "\(startIndex)",
            "Limit": "\(limit)",
            "SortBy": sortBy,
            "SortOrder": sortOrder,
            "Fields": "SortName,DateCreated,ProductionYear,PrimaryImageAspectRatio",
        ]
        switch kind {
        case .artists:
            // The artists with albums of their own, as a record shop files
            // them; not everyone who sings on a compilation.
            query["UserId"] = uid
            return try await get("Artists/AlbumArtists", query: listQuery(query, counted: true))
        case .albums, .songs:
            query["Recursive"] = "true"
            query["IncludeItemTypes"] = kind == .albums ? "MusicAlbum" : "Audio"
            return try await get("Users/\(uid)/Items", query: listQuery(query, counted: true))
        }
    }

    func tracks(of containerId: String, playlist: Bool) async throws -> [BaseItem] {
        let uid = try requireUser()
        // A playlist keeps the order it was put in, and is asked by its own
        // route: only that one numbers each song's place in it, which moving
        // or removing a song goes by. An album keeps its discs' order.
        if playlist {
            let result: ItemsResult = try await get("Playlists/\(containerId)/Items",
                                                    query: listQuery(["UserId": uid, "Fields": "MediaSources"]))
            return result.items
        }
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": containerId,
            "Fields": "MediaSources",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName",
        ]))
        return result.items
    }

    func albums(by artistId: String) async throws -> [BaseItem] {
        try await artistAlbums(["AlbumArtistIds": artistId])
    }

    func albums(featuring artistId: String) async throws -> [BaseItem] {
        let theirs = Set(try await albums(by: artistId).map(\.id))
        return try await artistAlbums(["ContributingArtistIds": artistId]).filter { !theirs.contains($0.id) }
    }

    private func artistAlbums(_ who: [String: String]) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(who.merging([
            "Recursive": "true",
            "IncludeItemTypes": "MusicAlbum",
            "SortBy": "PremiereDate,ProductionYear,SortName",
            "SortOrder": "Descending",
            "Limit": "200",
        ]) { $1 }))
        return result.items
    }

    func songs(by artistId: String, shuffled: Bool, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ArtistIds": artistId,
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "SortBy": shuffled ? "Random" : "ProductionYear,Album,ParentIndexNumber,IndexNumber,SortName",
            "Limit": "\(limit)",
            "Fields": "MediaSources",
        ]))
        return result.items
    }

    func shuffledSongs(in libraryId: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "SortBy": "Random",
            "Limit": "\(limit)",
            "Fields": "MediaSources",
        ]))
        return result.items
    }

    func instantMix(from itemId: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Items/\(itemId)/InstantMix", query: listQuery([
            "UserId": uid,
            "Limit": "\(limit)",
            "Fields": "MediaSources",
        ]))
        return result.items
    }

    func recentlyPlayedSongs(limit: Int) async throws -> [BaseItem] {
        try await playedSongs(sortBy: "DatePlayed", limit: limit)
    }

    func mostPlayedSongs(limit: Int) async throws -> [BaseItem] {
        try await playedSongs(sortBy: "PlayCount,DatePlayed", limit: limit)
    }

    private func playedSongs(sortBy: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "Filters": "IsPlayed",
            "SortBy": sortBy,
            "SortOrder": "Descending",
            "Limit": "\(limit)",
            "Fields": "MediaSources",
        ]))
        return result.items
    }

    func recentlyPlayedAlbums(limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        // The songs played last, gone through for their albums: a few
        // hundred, since an album played through is a dozen of them.
        let played: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "Filters": "IsPlayed",
            "SortBy": "DatePlayed",
            "SortOrder": "Descending",
            "Limit": "300",
        ]))
        var order: [String] = []
        for song in played.items {
            guard let album = song.albumId, !order.contains(album) else { continue }
            order.append(album)
            if order.count == limit { break }
        }
        guard !order.isEmpty else { return [] }
        let found: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(["Ids": order.joined(separator: ",")]))
        let byId = Dictionary(found.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byId[$0] }
    }

    func favoriteMusic(_ kind: MusicKind, in libraryId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        var query = ["ParentId": libraryId, "SortBy": "SortName", "SortOrder": "Ascending", "Limit": "500"]
        switch kind {
        case .artists:
            // Anyone marked, not only those with albums of their own: a
            // singer liked from a compilation is a favourite too.
            query["UserId"] = uid
            query["IsFavorite"] = "true"
            let result: ItemsResult = try await get("Artists", query: listQuery(query))
            return result.items
        case .albums, .songs:
            query["Recursive"] = "true"
            query["Filters"] = "IsFavorite"
            query["IncludeItemTypes"] = kind == .albums ? "MusicAlbum" : "Audio"
            if kind == .songs { query["Fields"] = "MediaSources" }
            let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(query))
            return result.items
        }
    }

    func musicGenres(in libraryId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Genres", query: listQuery([
            "ParentId": libraryId,
            "UserId": uid,
            "SortBy": "SortName",
            // How many albums and songs each has.
            "Fields": "ItemCounts",
        ]))
        return result.items
    }

    func albums(inGenre genreId: String, library libraryId: String, startIndex: Int, limit: Int) async throws -> ItemsResult {
        let uid = try requireUser()
        return try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": "MusicAlbum",
            // By id, not name: a name can hold the characters that separate them.
            "GenreIds": genreId,
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "StartIndex": "\(startIndex)",
            "Limit": "\(limit)",
        ], counted: true))
    }

    func shuffledSongs(inGenre genreId: String, library libraryId: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "GenreIds": genreId,
            "SortBy": "Random",
            "Limit": "\(limit)",
            "Fields": "MediaSources",
        ]))
        return result.items
    }

    func mostPlayedSongs(by artistId: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ArtistIds": artistId,
            "Recursive": "true",
            "IncludeItemTypes": "Audio",
            "Filters": "IsPlayed",
            "SortBy": "PlayCount,DatePlayed",
            "SortOrder": "Descending",
            "Limit": "\(limit)",
            "Fields": "MediaSources",
        ]))
        return result.items
    }

    func similarArtists(to artistId: String, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Artists/\(artistId)/Similar", query: listQuery([
            "UserId": uid,
            "Limit": "\(limit + 1)",
        ]))
        return Array(result.items.filter { $0.id != artistId }.prefix(limit))
    }

    // MARK: - Playlists of songs

    func audiobookFiles(in libraryId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": "AudioBook",
            "Fields": "ParentId,DateCreated,SortName,ProductionYear",
            "SortBy": "SortName",
            "Limit": "5000",
        ]))
        return result.items
    }

    func audiobookParts(of bookId: String, folder: Bool?) async throws -> [BaseItem] {
        let uid = try requireUser()
        let fields = "Chapters,MediaSources,ParentId,Overview"
        let isFolder: Bool
        if let folder { isFolder = folder } else { isFolder = try await !item(id: bookId).isAudiobook }
        if !isFolder {
            let found: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery(["Ids": bookId, "Fields": fields]))
            return found.items
        }
        // The folder's own files: a book's parts are those of one folder (the
        // library groups them so), and a library's whole tree is never asked.
        let found: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "ParentId": bookId,
            "IncludeItemTypes": "AudioBook",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName",
            "Fields": fields,
        ]))
        return found.items
    }

    func resumeAudiobooks(limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items/Resume", query: listQuery([
            "Limit": "\(limit)",
            "MediaTypes": "Audio",
            "IncludeItemTypes": "AudioBook",
            "Fields": "ParentId",
        ]))
        return result.items
    }

    func playlists(mediaType: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "IncludeItemTypes": "Playlist",
            "Recursive": "true",
            "SortBy": "SortName",
            "Limit": "500",
            "Fields": "ChildCount",
        ]))
        // An empty one made elsewhere may not say what it holds: it's a
        // playlist of films as much as of songs.
        return result.items.filter { ($0.mediaType ?? mediaType) == mediaType }
    }

    private struct Created: Decodable { let id: String }

    /// Ids a hundred at a time: they go in the address, and a few hundred
    /// make one longer than the server will read.
    private static func batches(_ ids: [String]) -> [String] {
        stride(from: 0, to: ids.count, by: 100).map { ids[$0..<min($0 + 100, ids.count)].joined(separator: ",") }
    }

    func createPlaylist(named name: String, items ids: [String], mediaType: String) async throws -> String {
        let uid = try requireUser()
        // Made with the first hundred, the rest added after.
        let first = Array(ids.prefix(100))
        // Said twice: Jellyfin reads the body, Emby the address.
        let created: Created = try await post("Playlists", query: [
            "Name": name,
            "Ids": first.joined(separator: ","),
            "UserId": uid,
            "MediaType": mediaType,
        ], json: ["Name": name, "Ids": first, "UserId": uid, "MediaType": mediaType])
        if ids.count > first.count { try await addToPlaylist(created.id, songs: Array(ids.dropFirst(first.count))) }
        return created.id
    }

    func removeFromPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        // By their places in it, as the server names them: on Emby a place's
        // id isn't the item's.
        let uid = try requireUser()
        let listed: ItemsResult = try await get("Playlists/\(playlistId)/Items", query: listQuery(["UserId": uid]))
        let wanted = Set(itemIds)
        let entries = listed.items.filter { wanted.contains($0.id) }.map { $0.playlistItemId ?? $0.id }
        guard !entries.isEmpty else { return }
        try await removeFromPlaylist(playlistId, entries: entries)
    }

    func boxSets() async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
            "IncludeItemTypes": "BoxSet",
            "Recursive": "true",
            "SortBy": "SortName",
            "Limit": "500",
            "Fields": "ChildCount",
        ]))
        return result.items
    }

    func createCollection(named name: String, items ids: [String]) async throws -> String {
        let first = Array(ids.prefix(100))
        let created: Created = try await post("Collections", query: ["Name": name, "Ids": first.joined(separator: ",")])
        if ids.count > first.count { try await addToCollection(created.id, items: Array(ids.dropFirst(first.count))) }
        return created.id
    }

    func addToCollection(_ collectionId: String, items ids: [String]) async throws {
        for batch in Self.batches(ids) {
            try await postVoid("Collections/\(collectionId)/Items", query: ["Ids": batch])
        }
    }

    func removeFromCollection(_ collectionId: String, items ids: [String]) async throws {
        for batch in Self.batches(ids) {
            _ = try await request("Collections/\(collectionId)/Items", query: ["Ids": batch], method: "DELETE")
        }
    }

    func canManageCollections() async -> Bool {
        guard let uid = try? requireUser(), let data = try? await request("Users/\(uid)"),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = user["Policy"] as? [String: Any] else { return false }
        return policy["IsAdministrator"] as? Bool == true || policy["EnableCollectionManagement"] as? Bool == true
    }

    func upcomingEpisodes(limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("Shows/Upcoming", query: listQuery([
            "UserId": uid,
            "Limit": "\(limit)",
            "Fields": "PremiereDate,Overview",
            "EnableImageTypes": "Primary,Thumb,Backdrop",
        ]))
        return result.items
    }

    /// Everything the device's search should find, a page at a time: films,
    /// shows, albums and artists, with what a search result says of each.
    func searchableTitles(startIndex: Int, limit: Int) async throws -> ItemsResult {
        let uid = try requireUser()
        return try await get("Users/\(uid)/Items", query: listQuery([
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,MusicAlbum,MusicArtist",
            "Fields": "Genres,ProductionYear",
            "EnableImageTypes": "Primary",
            "SortBy": "DateCreated",
            "SortOrder": "Ascending",
            "StartIndex": "\(startIndex)",
            "Limit": "\(limit)",
        ], counted: true))
    }

    func episodesToWatch(seriesId: String, limit: Int) async -> [BaseItem] {
        guard let uid = try? requireUser() else { return [] }
        // From the next on, a few over: watched ones further on (skipped ahead
        // of) are left out. With no next (Next Up says nothing once a show's
        // last episode is watched, earlier ones left or not), from the first
        // not watched, as the show's own Play button has it.
        let next = await nextEpisode(seriesId: seriesId)
        var query = ["UserId": uid, "IsMissing": "false"]
        if let next {
            query["StartItemId"] = next.id
            query["Limit"] = "\(limit * 2 + 1)"
        }
        let found: ItemsResult? = try? await get("Shows/\(seriesId)/Episodes", query: listQuery(query))
        let episodes = (found?.items ?? next.map { [$0] } ?? []).filter { $0.userData?.played != true && !$0.isUpcoming }
        return Array(episodes.prefix(limit))
    }

    // Any items: a show or a season, the server takes as all its episodes.
    func addToPlaylist(_ playlistId: String, songs songIds: [String]) async throws {
        let uid = try requireUser()
        for batch in Self.batches(songIds) {
            try await postVoid("Playlists/\(playlistId)/Items", query: ["Ids": batch, "UserId": uid])
        }
    }

    func removeFromPlaylist(_ playlistId: String, entries: [String]) async throws {
        for batch in Self.batches(entries) {
            _ = try await request("Playlists/\(playlistId)/Items", query: ["EntryIds": batch], method: "DELETE")
        }
    }

    func movePlaylistEntry(_ playlistId: String, entry: String, to index: Int) async throws {
        try await postVoid("Playlists/\(playlistId)/Items/\(entry)/Move/\(index)")
    }

    func renamePlaylist(_ playlistId: String, to name: String) async throws {
        // Jellyfin 10.9 and later have a route for it; before that, and on
        // Emby, the item is sent back whole with its new name.
        if flavor == .jellyfin, (try? await postVoid("Playlists/\(playlistId)", json: ["Name": name])) != nil { return }
        let uid = try requireUser()
        let data = try await request("Users/\(uid)/Items/\(playlistId)")
        guard var item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServerError.badResponse(0) }
        item["Name"] = name
        try await postVoid("Items/\(playlistId)", json: item)
    }

    func canEditPlaylist(_ playlistId: String) async -> Bool {
        // Emby has no shared playlists: a playlist listed is the account's own.
        guard flavor == .jellyfin, let uid = try? requireUser() else { return true }
        struct Permission: Decodable { let canEdit: Bool? }
        do {
            let permission: Permission = try await get("Playlists/\(playlistId)/Users/\(uid)")
            return permission.canEdit ?? true
        } catch ServerError.badResponse(let status) where status == 403 {
            return false
        } catch {
            // A server older than shared playlists (10.9): each was its owner's alone.
            return true
        }
    }

    func searchMusic(_ term: String) async throws -> (artists: [BaseItem], albums: [BaseItem], songs: [BaseItem]) {
        let uid = try requireUser()
        // A kind at a time: asked together, a library's songs crowded its
        // artists and albums out of the answer.
        var found: [[BaseItem]] = []
        for (kind, limit) in [("MusicArtist", 16), ("MusicAlbum", 20), ("Audio", 12)] {
            let result: ItemsResult = try await get("Users/\(uid)/Items", query: listQuery([
                "SearchTerm": term,
                "Recursive": "true",
                "IncludeItemTypes": kind,
                "Limit": "\(limit)",
                "Fields": kind == "Audio" ? "MediaSources" : "PrimaryImageAspectRatio",
            ]))
            found.append(result.items)
        }
        return (found[0], found[1], found[2])
    }

    func lyrics(of songId: String) async -> Lyrics? {
        guard flavor == .jellyfin, let found: Lyrics = try? await get("Audio/\(songId)/Lyrics"),
              found.lyrics.contains(where: { !($0.text ?? "").isEmpty }) else { return nil }
        return found
    }

    /// The containers Apple's player reads as they are, by the server's
    /// names for them. Anything else (Ogg, Opus, WMA, APE, WavPack, DSD) the
    /// server makes AAC of.
    static let playableSongContainers: Set<String> = ["mp3", "aac", "m4a", "m4b", "mp4", "mov", "flac", "wav", "aif", "aiff", "caf", "alac"]
    static let playableSongCodecs: Set<String> = ["mp3", "aac", "alac", "flac", "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be", "pcm_f32le"]

    func songStream(_ song: BaseItem) -> PlaybackContext? {
        guard let token else { return nil }
        let source = song.mediaSources?.first
        let sourceId = source?.id ?? song.id
        let playSession = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let containers = Set((source?.container ?? song.container ?? "").lowercased().split(separator: ",").map(String.init))
        let codecs = (source?.mediaStreams ?? []).filter { $0.type == "Audio" }.compactMap { $0.codec?.lowercased() }
        let direct = !containers.isDisjoint(with: Self.playableSongContainers)
            && codecs.allSatisfy { Self.playableSongCodecs.contains($0) }
        var query: [String: String]
        let path: String
        if direct {
            // Named by its kind, so the player knows what it's reading
            // whatever the server calls it in its headers.
            let kind = containers.first { Self.playableSongContainers.contains($0) } ?? "mp3"
            query = ["static": "true", "MediaSourceId": sourceId, "PlaySessionId": playSession, "DeviceId": Self.deviceId]
            path = "Audio/\(song.id)/stream.\(kind == "mov" || kind == "mp4" ? "m4a" : kind)"
        } else {
            query = ["MediaSourceId": sourceId, "PlaySessionId": playSession, "DeviceId": Self.deviceId,
                     "AudioCodec": "aac", "AudioBitrate": "256000", "MaxAudioChannels": "2", "SegmentContainer": "ts"]
            path = "Audio/\(song.id)/master.m3u8"
        }
        // ApiKey, not api_key, on Jellyfin: its newer routes refuse the older spelling.
        if flavor == .jellyfin { query["ApiKey"] = token } else { query.merge(tokenQuery) { $1 } }
        return PlaybackContext(url: url(path: path, query: query), item: song, mediaSourceId: sourceId,
                               playSessionId: playSession, isDirect: direct, startTicks: 0)
    }

    func reportCapabilities(controllable: Bool) async {
        let body: [String: Any] = controllable
            ? ["PlayableMediaTypes": ["Video"], "SupportedCommands": ["SetAudioStreamIndex", "SetSubtitleStreamIndex"],
               "SupportsMediaControl": true, "SupportsPersistentIdentifier": true]
            : ["PlayableMediaTypes": [String](), "SupportedCommands": [String](),
               "SupportsMediaControl": false, "SupportsPersistentIdentifier": true]
        try? await postVoid("Sessions/Capabilities/Full", json: body)
    }

    func controllableSessions() async throws -> [RemoteSession] {
        let uid = try requireUser()
        return try await get("Sessions", query: ["controllableByUserId": uid, "activeWithinSeconds": "960"])
    }

    func play(_ itemIds: [String], on session: String, startTicks: Int64?) async throws {
        var query = ["playCommand": "PlayNow", "itemIds": itemIds.joined(separator: ",")]
        if let startTicks, startTicks > 0 { query["startPositionTicks"] = String(startTicks) }
        try await postVoid("Sessions/\(session)/Playing", query: query)
    }

    func playstate(_ command: String, on session: String, seekTicks: Int64?) async throws {
        try await postVoid("Sessions/\(session)/Playing/\(command)",
                           query: seekTicks.map { ["seekPositionTicks": String($0)] } ?? [:])
    }

    func command(_ name: String, on session: String, arguments: [String: String]) async throws {
        try await postVoid("Sessions/\(session)/Command", json: ["Name": name, "Arguments": arguments])
    }

    func socketRequest() -> URLRequest? {
        guard token != nil else { return nil }
        var req = signed("socket")
        guard var parts = req.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        req.url = parts.url
        return req
    }

    func liveDeletableLibraries() async -> Set<String> {
        guard let uid = try? requireUser(), let data = try? await request("Users/\(uid)"),
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = user["Policy"] as? [String: Any] else { return [] }
        let anywhere = policy["IsAdministrator"] as? Bool == true || policy["EnableContentDeletion"] as? Bool == true
        let some = Set(policy["EnableContentDeletionFromFolders"] as? [String] ?? [])
        guard anywhere || !some.isEmpty,
              let folders: ItemsResult = try? await get("LiveTv/Recordings/Folders", query: ["userId": uid]) else { return [] }
        return Set(folders.items.map(\.id).filter { anywhere || some.contains($0) })
    }

    func deleteItem(_ id: String) async throws {
        _ = try await request("Items/\(id)", method: "DELETE")
    }

    func liveOnNow(first: String?, limit: Int) async throws -> [BaseItem] {
        let uid = try requireUser()
        let result: ItemsResult = try await get("LiveTv/Channels", query: [
            "UserId": uid,
            "AddCurrentProgram": "true",
            "EnableUserData": "true",
            "EnableImages": "true",
            "EnableImageTypes": "Primary",
            "ImageTypeLimit": "1",
            "Fields": "Overview",
        ])
        // In three sorts, each in the tuner's order.
        let last = result.items.filter { $0.id == first }
        let favourites = result.items.filter { $0.id != first && $0.userData?.isFavorite == true }
        let rest = result.items.filter { $0.id != first && $0.userData?.isFavorite != true }
        return Array((last + favourites + rest).prefix(limit))
    }

    func liveProgramPictureURL(programId: String, maxWidth: Int) async -> URL? {
        guard let uid = try? requireUser(),
              let found: LiveProgramDTO = try? await get("LiveTv/Programs/\(programId)", query: ["UserId": uid]),
              let tag = found.imageTags?["Primary"] else { return nil }
        return url(path: "Items/\(programId)/Images/Primary", query: ["maxWidth": "\(maxWidth)", "quality": "90", "tag": tag])
    }

    func libraryTitle(named name: String, film: Bool) async -> BaseItem? {
        guard let uid = try? requireUser(),
              let found: ItemsResult = try? await get("Users/\(uid)/Items", query: [
                  "Recursive": "true",
                  "IncludeItemTypes": film ? "Movie" : "Series",
                  "SearchTerm": name,
                  "Limit": "10",
                  "EnableUserData": "false",
                  "EnableImageTypes": "Backdrop,Logo,Primary",
                  "ImageTypeLimit": "1",
                  "Fields": "Overview,Taglines",
                  "EnableTotalRecordCount": "false",
              ]) else { return nil }
        return found.items.first {
            $0.name?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    func libraryEpisodes(of seriesId: String, season: Int?) async -> [BaseItem] {
        guard let uid = try? requireUser() else { return [] }
        var query = ["UserId": uid, "Fields": "PremiereDate", "EnableUserData": "false", "EnableImages": "false"]
        if let season { query["Season"] = "\(season)" }
        let found: ItemsResult? = try? await get("Shows/\(seriesId)/Episodes", query: query)
        return found?.items ?? []
    }

    func liveSearch(_ term: String) async throws -> [LiveListing] {
        let uid = try requireUser()
        // The listings' own search, as the library's is asked: every showing,
        // each with its channel. The programmes endpoint takes no words.
        let result: LiveProgramsResult = try await get("Items", query: [
            "userId": uid,
            "IncludeItemTypes": "LiveTvProgram",
            "SearchTerm": term,
            "Recursive": "true",
            "Limit": "300",
            "SortBy": "StartDate",
            "Fields": "Overview,ChannelInfo",
            "EnableImageTypes": "Primary",
            "ImageTypeLimit": "1",
            "EnableUserData": "false",
            "EnableTotalRecordCount": "false",
        ])
        let now = Date()
        return result.items.compactMap(\.listing).filter { $0.program.end > now }
    }

    func liveListingImageURL(_ listing: LiveListing, maxWidth: Int) -> URL? {
        guard let tag = listing.imageTag else { return nil }
        return url(path: "Items/\(listing.program.id)/Images/Primary", query: ["maxWidth": "\(maxWidth)", "quality": "90", "tag": tag])
    }

    func liveProgramImageURL(on channel: BaseItem, maxWidth: Int) -> URL? {
        guard let program = channel.currentProgram, let tag = program.imageTags?["Primary"] else { return nil }
        return url(path: "Items/\(program.id)/Images/Primary", query: ["maxWidth": "\(maxWidth)", "quality": "90", "tag": tag])
    }

    func channelLogoURL(_ channel: LiveChannel, maxWidth: Int) -> URL? {
        guard let tag = channel.imageTag else { return nil }
        return url(path: "Items/\(channel.id)/Images/Primary", query: ["maxWidth": "\(maxWidth)", "quality": "90", "tag": tag])
    }

    // MARK: - Starting quickly

    /// The server does nothing on a stream until the player asks for its first
    /// piece, and the player only asks once the TV has changed mode and the
    /// player is built. Asking here instead has the server working through
    /// both. For a remux it also decides where the server starts: the player
    /// asks for the setup segment first, which Jellyfin serves by converting
    /// from the top of the film, only to throw that away when the resume point
    /// is asked for a moment later. Asked for first, the resume point is where
    /// it starts, and the setup segment comes from the same run.
    func warmUp(_ ctx: PlaybackContext) async {
        let session = session
        let agent = Self.streamUserAgent
        if ctx.isDirect {
            // Nothing to prepare but the disk, which may be asleep.
            var wake = URLRequest(url: ctx.url)
            wake.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
            Task.detached(priority: .userInitiated) { _ = try? await session.data(for: wake) }
            return
        }
        guard flavor == .jellyfin else { return }
        let start = ctx.streamStartsAtZero ? Double(ctx.startTicks) / 10_000_000 : 0
        let playlist = ctx.url
        // A warm-up is a head start, never a wait: the server readies the
        // first piece of a 4K remux in about 3 seconds, and one that got stuck
        // held the picture for the full 20 this used to allow, while the
        // player's own request then went straight through.
        _ = await withinDeadline(6) { () async -> Bool? in
            guard let segment = await Self.segment(at: start, in: playlist, session: session) else { return nil }
            var request = URLRequest(url: segment)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            guard let (bytes, _) = try? await session.bytes(for: request) else { return nil }
            // It's ready once the server answers; the player fetches it itself.
            bytes.task.cancel()
            return true
        }
    }

    /// What the player and the warm-up both call themselves. Jellyfin names a
    /// conversion after the asker's user agent among other things, so with the
    /// player's own (AppleCoreMedia) the warm-up's run was a different one, and
    /// the player's first request stopped it and began again from the top.
    static let streamUserAgent = "JellyGoose/\(appVersion) (Apple TV)"

    /// The address of the piece of a stream that holds this moment, from its
    /// playlist, or from the first variant when handed a master.
    private static func segment(at seconds: Double, in playlistURL: URL, session: URLSession) async -> URL? {
        guard let (data, _) = try? await session.data(from: playlistURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if text.contains("#EXT-X-STREAM-INF"),
           let variant = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
           let url = URL(string: variant, relativeTo: playlistURL) {
            return await segment(at: seconds, in: url.absoluteURL, session: session)
        }
        var elapsed = 0.0
        var duration: Double?
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#"), let length = duration {
                if elapsed + length > seconds { return URL(string: line, relativeTo: playlistURL)?.absoluteURL }
                elapsed += length
                duration = nil
            }
        }
        return nil
    }

    // MARK: - Progress reporting

    func reportStart(_ ctx: PlaybackContext) async {
        try? await postVoid("Sessions/Playing", json: playbackBody(ctx, positionTicks: ctx.startTicks))
    }

    func reportProgress(_ ctx: PlaybackContext, positionTicks: Int64, paused: Bool, audioIndex: Int?, subtitleIndex: Int?) async {
        var body = playbackBody(ctx, positionTicks: positionTicks)
        body["IsPaused"] = paused
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        if let subtitleIndex { body["SubtitleStreamIndex"] = subtitleIndex }
        let sent = (try? await postVoid("Sessions/Playing/Progress", json: body)) != nil
        await noteDownloadPosition(ctx, positionTicks, sent: sent)
    }

    func reportStopped(_ ctx: PlaybackContext, positionTicks: Int64) async {
        let sent = (try? await postVoid("Sessions/Playing/Stopped", json: playbackBody(ctx, positionTicks: positionTicks))) != nil
        await noteDownloadPosition(ctx, positionTicks, sent: sent)
    }

    /// A download remembers where it got to on the device too, so it resumes
    /// offline, and so what the server didn't hear can be told it later.
    private func noteDownloadPosition(_ ctx: PlaybackContext, _ ticks: Int64, sent: Bool) async {
        // Not in the widgets (EXTENSION), which compile the client and have no downloads.
        #if !os(tvOS) && !EXTENSION
        await Downloads.shared.notePosition(ctx.item.id, ticks: ticks, sent: sent)
        #endif
    }

    private func playbackBody(_ ctx: PlaybackContext, positionTicks: Int64) -> [String: Any] {
        var body: [String: Any] = [
            "ItemId": ctx.item.id,
            "PositionTicks": positionTicks,
            "PlayMethod": ctx.isDirect ? "DirectStream" : "Transcode",
            "CanSeek": true,
        ]
        if let ms = ctx.mediaSourceId { body["MediaSourceId"] = ms }
        if let ps = ctx.playSessionId { body["PlaySessionId"] = ps }
        return body
    }
}
