#if !os(tvOS)
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A film, episode, song or part of an audiobook kept on the device, to play
/// without the server.
struct DownloadRecord: Codable, Identifiable {
    enum State: String, Codable { case downloading, done, failed }

    /// The item's id on the server.
    let id: String
    /// The server's own description of the item, as it sent it, read back with
    /// the client's decoder whenever the item is needed offline.
    let itemJSON: Data
    let fileName: String
    var imageFileName: String?
    var state: State
    var bytesWritten: Int64 = 0
    var bytesExpected: Int64 = 0
    /// Where playback got to on this device, in ticks.
    var positionTicks: Int64 = 0
    /// Set when that position hasn't reached the server yet (watched offline).
    var positionUnsent = false
    /// Whether it was started to wait for Wi-Fi: the request keeps the rule it
    /// began with, whatever the setting says later. Optional so a download saved
    /// before the setting existed still decodes.
    var wifiOnly: Bool?
    let addedAt: Date
    /// What the system handed back when a download broke off (the app force-quit,
    /// the connection lost): enough to carry on from where it got to.
    var resumeData: Data?
    /// How many times it has been picked up again; after a few, it's failed.
    var resumeAttempts: Int?
    /// Downloaded for itself, not only as a song of an album, a playlist or a
    /// book (`DownloadGroup`): it stays when those go. Nil, from before there
    /// were groups, is for itself.
    var standalone: Bool?
    /// A smaller copy the server made (`DownloadQuality`'s raw value), not the
    /// file as it is; nil for the file as it is.
    var converted: String?
    /// A converted copy's text subtitles, kept as WebVTT files beside it, by
    /// the server's index (as a string, for the index's JSON).
    var subtitleFiles: [String: String]?

    var isStandalone: Bool { standalone ?? true }
}

/// An album, a playlist or an audiobook kept on the device. Its songs or parts
/// are downloads of their own (a song in an album and a playlist both is kept
/// once); this says which they are, in what order, and under what name.
struct DownloadGroup: Codable, Identifiable {
    enum Kind: String, Codable { case album, playlist, book }

    let id: String
    let kind: Kind
    let name: String
    /// Who it's by, under its name.
    var byLine: String?
    /// The page a notice about it opens: the album's, the playlist's, the
    /// book's file or folder.
    let pageId: String
    var itemIds: [String]
    var imageFileName: String?
    let addedAt: Date
    /// Whether its having all come down has been told (once).
    var announced = false
}

/// Downloads, in a background session so they carry on when the app is left,
/// kept in Application Support and listed in an index beside them.
@MainActor
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    @Published private(set) var records: [String: DownloadRecord] = [:]
    @Published private(set) var groups: [String: DownloadGroup] = [:]
    /// On mobile data with no Wi-Fi, which is when Wi-Fi-only downloads wait.
    @Published private(set) var onlyMobileData = false
    private let network = NWPathMonitor()

    /// Called by the system when it wakes the app for finished background
    /// downloads; handed back once the session has told us everything.
    var backgroundCompletion: (() -> Void)?

    private static let sessionID = "com.goosehouse.jellygoose.downloads"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = true
        // Two at a time: a smaller copy is a transcode the server runs for as
        // long as it comes down, and a season asked for at once was ten.
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Made once: every row and badge asks for a picture or a file through it,
    /// and each asked the disk whether the folder was there.
    nonisolated static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Kept, not backed up: a film is the server's to hand out again.
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return folder
    }()

    private var indexURL: URL { Self.folder.appendingPathComponent("index.json") }
    private var groupsURL: URL { Self.folder.appendingPathComponent("groups.json") }

    /// Each download's item, decoded once rather than on every redraw of its
    /// row. Not published: it only saves work.
    private var decoded: [String: BaseItem] = [:]
    /// Where each download's position was last written to the index.
    private var savedPositions: [String: Int64] = [:]

    override init() {
        super.init()
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            // A download that was running when the app was stopped carries on in
            // the session if the system kept it; the session reports on it below.
            records = saved
            savedPositions = saved.mapValues(\.positionTicks)
        }
        if let data = try? Data(contentsOf: groupsURL),
           let saved = try? JSONDecoder().decode([String: DownloadGroup].self, from: data) {
            groups = saved
        }
        _ = session   // reconnect to downloads still running from before
        reconciled = Task { await reconcile() }
        network.pathUpdateHandler = { [weak self] path in
            let mobile = path.status == .satisfied && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            DispatchQueue.main.async { self?.onlyMobileData = mobile }
        }
        network.start(queue: DispatchQueue(label: "com.goosehouse.jellygoose.network"))
    }

    /// Downloads the index says are coming down but the session has no task
    /// for: broken off while the app was away, or stopped with it. Those with
    /// resume data carry on now; the rest wait for `carryOn(client:)`.
    private var stalled: Set<String> = []
    /// The look through the session at launch, which `carryOn` waits for:
    /// asked first, it found nothing stranded yet.
    private var reconciled: Task<Void, Never>?
    /// Downloads being started. Asked for twice in a moment (a double tap),
    /// one came down twice: the record that says it's coming is only made
    /// once the server has described the file.
    private var starting: Set<String> = []

    private func reconcile() async {
        let live = Set((await session.allTasks).compactMap(\.taskDescription))
        for (id, record) in records where record.state == .downloading && !live.contains(id) {
            if record.resumeData != nil {
                resumeDownload(id)
            } else {
                stalled.insert(id)
            }
        }
    }

    /// Starts over any download that broke off with nothing to carry on
    /// from, once the server can be reached. Called as the app reaches it.
    func carryOn(client: MediaBrowserClient) async {
        await reconciled?.value
        // A smaller copy whose subtitles didn't all come (the app was put away).
        for (id, record) in records where record.converted != nil && record.subtitleFiles == nil {
            await fetchSubtitles(id, client: client)
        }
        let ids = stalled
        stalled = []
        guard !ids.isEmpty else { return }
        let live = Set((await session.allTasks).compactMap(\.taskDescription))
        for id in ids {
            // Still stranded: it may have been cancelled, or started again by
            // hand, since it was found.
            guard records[id]?.state == .downloading, !live.contains(id), let item = self.item(id) else { continue }
            // Its record stays until the new download has begun, so one that
            // can't begin isn't lost from the list.
            switch await begin(item, client: client, startingOver: true, standalone: records[id]?.isStandalone ?? true) {
            case nil: break
            // The server can't be asked now: again the next time the app comes forward.
            case .unreachable: stalled.insert(id)
            case .noSpace:
                records[id]?.state = .failed
                save()
            }
        }
    }

    /// Picks a download up again from its resume data. After three tries it's
    /// failed, so a server that keeps dropping it doesn't have it going for ever.
    private func resumeDownload(_ id: String) {
        guard var record = records[id], let data = record.resumeData else { return }
        let attempts = (record.resumeAttempts ?? 0) + 1
        guard attempts <= 3 else {
            record.state = .failed
            record.resumeData = nil
            records[id] = record
            save()
            if let item = item(id) { DownloadNotices.shared.failed(item) }
            return
        }
        record.resumeData = nil
        record.resumeAttempts = attempts
        records[id] = record
        save()
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = id
        task.resume()
    }

    /// Whether a download is held up by the Wi-Fi-only setting right now.
    func waitingForWiFi(_ id: String) -> Bool {
        guard let record = records[id], record.state == .downloading, onlyMobileData else { return false }
        return record.wifiOnly == true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func saveGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: groupsURL, options: .atomic)
    }

    // MARK: Asking

    func record(_ id: String) -> DownloadRecord? { records[id] }

    /// The file to play, once it's all here.
    func fileURL(_ id: String) -> URL? {
        guard let record = records[id], record.state == .done else { return nil }
        let url = Self.folder.appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func item(_ id: String) -> BaseItem? {
        if let hit = decoded[id] { return hit }
        guard let item = records[id].flatMap({ MediaBrowserClient.decodeItem($0.itemJSON) }) else { return nil }
        decoded[id] = item
        return item
    }

    /// A download's picture, or an album's, playlist's or book's kept here.
    func imageURL(_ id: String) -> URL? {
        (records[id]?.imageFileName ?? groups[id]?.imageFileName).map { Self.folder.appendingPathComponent($0) }
    }

    /// Where a download was last played to: this device's place where the
    /// server hasn't heard it yet, else the server's (another device may have
    /// gone further). In ticks.
    func position(of item: BaseItem) -> Int64 {
        guard let record = records[item.id], record.positionUnsent else { return item.userData?.playbackPositionTicks ?? 0 }
        return record.positionTicks
    }

    func progress(_ id: String) -> Double? {
        guard let record = records[id], record.state == .downloading else { return nil }
        guard record.bytesExpected > 0 else { return 0 }
        // A smaller copy's size is an estimate (the server can't say ahead), so
        // it may run past it: it doesn't read as done until it is.
        return min(Double(record.bytesWritten) / Double(record.bytesExpected), 0.99)
    }

    /// Whether it's a smaller copy the server made, and at what quality.
    func quality(_ id: String) -> DownloadQuality? {
        records[id]?.converted.flatMap(DownloadQuality.init(rawValue:))
    }

    /// A converted copy's subtitles kept beside it, by the server's index.
    func subtitleURLs(_ id: String) -> [Int: URL] {
        var urls: [Int: URL] = [:]
        for (index, name) in records[id]?.subtitleFiles ?? [:] {
            guard let number = Int(index) else { continue }
            let url = Self.folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { urls[number] = url }
        }
        return urls
    }

    /// Everything on the device, in bytes.
    var bytesUsed: Int64 {
        records.values.filter { $0.state == .done }.reduce(0) { $0 + max($1.bytesExpected, $1.bytesWritten) }
    }

    // MARK: Downloading

    /// What a Download button or menu row does, decided now rather than when
    /// it was drawn: a failed download starts over, one already coming down or
    /// already here is left alone. Nil on success (or nothing to do),
    /// otherwise what to tell the viewer.
    func download(_ target: BaseItem, client: MediaBrowserClient) async -> String? {
        if records[target.id]?.state == .failed { remove(target.id) }
        return await start(target, client: client)
    }

    /// Takes a finished download off the device. A menu drawn before it
    /// finished, or before it was started again, doesn't reach one that's
    /// coming down.
    func removeFinished(_ id: String) {
        guard records[id]?.state != .downloading else { return }
        remove(id)
    }

    /// Starts a download of a film or episode's original file. Nil on success,
    /// otherwise what to tell the viewer.
    func start(_ target: BaseItem, client: MediaBrowserClient) async -> String? {
        switch await begin(target, client: client, startingOver: false, standalone: true) {
        case nil: nil
        case .unreachable: String(localized: "Couldn't start the download. Check the connection to your server.")
        case .noSpace(let message): message
        }
    }

    /// Why a download didn't begin.
    private enum Refusal {
        case unreachable
        case noSpace(String)
    }

    /// `startingOver` is for a download whose record says it's coming down
    /// with nothing bringing it (see `carryOn`): it begins again from nothing.
    /// `standalone` false for a song or part brought down for its album,
    /// playlist or book.
    private func begin(_ target: BaseItem, client: MediaBrowserClient, startingOver: Bool, standalone: Bool) async -> Refusal? {
        // Asked for by itself now, though it came for an album: it stays when the album goes.
        if standalone, records[target.id]?.isStandalone == false {
            records[target.id]?.standalone = true
            save()
        }
        guard startingOver || records[target.id]?.state != .downloading, fileURL(target.id) == nil else { return nil }
        guard starting.insert(target.id).inserted else { return nil }
        defer { starting.remove(target.id) }
        guard let (data, item) = try? await client.itemData(id: target.id),
              let source = item.mediaSources?.first,
              let plan = Self.fetch(item: item, source: source, client: client) else {
            return .unreachable
        }
        let (url, ext) = (plan.url, plan.ext)
        // A smaller copy's size, as near as can be said before it's made.
        let size = plan.quality.map { quality in
            Int64(quality.videoBitrate + quality.audioBitrate) * (item.runTimeTicks ?? source.runTimeTicks ?? 0) / 10_000_000 / 8
        } ?? source.size
        // Not started if it can't fit: a download that fills the device fails
        // at the end, after hours, and takes the device's space with it.
        if let size, size > 0, let free = Self.freeSpace, size + 1_000_000_000 > free {
            let needed = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return .noSpace(String(localized: "Not enough space: this needs \(needed), and \(available) is free.",
                                   comment: "The placeholders are sizes, like 42 GB and 12 GB"))
        }
        let wifiOnly = PlaybackPreferences.downloadsWiFiOnly
        let record = DownloadRecord(id: item.id, itemJSON: data, fileName: "\(item.id).\(ext)",
                                    state: .downloading, bytesExpected: size ?? 0,
                                    positionTicks: item.resumeTicks, wifiOnly: wifiOnly, addedAt: Date(),
                                    standalone: standalone, converted: plan.quality?.rawValue)
        records[item.id] = record
        decoded[item.id] = item
        savedPositions[item.id] = item.resumeTicks
        save()

        var request = URLRequest(url: url)
        request.setValue(MediaBrowserClient.streamUserAgent, forHTTPHeaderField: "User-Agent")
        // Wi-Fi only: the system holds it until there is Wi-Fi (and keeps it
        // off a phone's hotspot too), then carries on by itself.
        request.allowsCellularAccess = !wifiOnly
        request.allowsExpensiveNetworkAccess = !wifiOnly
        // So the finish can be announced, even with the app put away. Asked
        // before the download starts: a small one could finish before the
        // question was answered, and go unannounced.
        await DownloadNotices.shared.askLeave()
        let task = session.downloadTask(with: request)
        task.taskDescription = item.id
        task.resume()

        // A smaller copy has no subtitles inside it: each comes as a file.
        if plan.quality != nil { Task { await fetchSubtitles(item.id, client: client) } }

        // The picture for the list, while the film comes down. A song's is
        // its album's cover, big enough for Now Playing.
        let imageItem = item
        let picture = item.isPlayableAudio ? client.imageURL(for: item, type: "Primary", maxWidth: 1000)
                                           : client.imageURL(for: item, maxWidth: 600)
        if let imageURL = picture {
            Task {
                guard let bytes = await Self.picture(imageURL) else { return }
                let name = "\(imageItem.id).jpg"
                try? bytes.write(to: Self.folder.appendingPathComponent(name))
                records[imageItem.id]?.imageFileName = name
                save()
            }
        }
        return nil
    }

    /// Stops a download that's coming down, and forgets it. One that finished
    /// meanwhile (the button or menu row was drawn before it did) is kept.
    func cancel(_ id: String) async {
        guard records[id]?.state == .downloading else { return }
        let tasks = await session.allTasks
        tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() }
        remove(id)
    }

    /// Deletes the file and forgets it, and takes it out of any album,
    /// playlist or book it came down for.
    func remove(_ id: String) {
        discard(id)
        var changed = false
        for (key, group) in groups where group.itemIds.contains(id) {
            groups[key]?.itemIds.removeAll { $0 == id }
            if groups[key]?.itemIds.isEmpty == true { dropGroup(key) }
            changed = true
        }
        if changed { saveGroups() }
    }

    /// The file and its record gone, nothing else.
    private func discard(_ id: String) {
        guard let record = records[id] else { return }
        for name in (record.subtitleFiles ?? [:]).values {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(record.fileName))
        if let image = record.imageFileName {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(image))
        }
        records[id] = nil
        decoded[id] = nil
        savedPositions[id] = nil
        stalled.remove(id)
        save()
    }

    // MARK: Albums, playlists and books

    /// How an album, a playlist or a book stands on the device.
    enum GroupState: Equatable {
        case none
        case downloading(Double)
        case done
        /// Some of it didn't come down, and nothing more is coming.
        case failed
    }

    func groupState(_ id: String) -> GroupState {
        guard let group = groups[id], !group.itemIds.isEmpty else { return .none }
        let members = group.itemIds.map { records[$0] }
        if members.contains(where: { $0?.state == .downloading }) {
            let written = members.reduce(Int64(0)) { $0 + ($1?.bytesWritten ?? 0) }
            let expected = members.reduce(Int64(0)) { $0 + max($1?.bytesExpected ?? 0, $1?.bytesWritten ?? 0) }
            return .downloading(expected > 0 ? Double(written) / Double(expected) : 0)
        }
        if members.allSatisfy({ $0?.state == .done }) { return .done }
        return .failed
    }

    /// Songs or parts here so far, of how many.
    func groupCounts(_ id: String) -> (done: Int, total: Int) {
        guard let group = groups[id] else { return (0, 0) }
        return (group.itemIds.filter { records[$0]?.state == .done }.count, group.itemIds.count)
    }

    /// A group's songs or parts that are here, in its order.
    func groupItems(_ id: String) -> [BaseItem] {
        (groups[id]?.itemIds ?? []).compactMap { fileURL($0) != nil ? item($0) : nil }
    }

    /// Bytes an album, playlist or book takes here.
    func groupBytes(_ id: String) -> Int64 {
        (groups[id]?.itemIds ?? []).reduce(0) { total, itemId in
            guard let record = records[itemId], record.state == .done else { return total }
            return total + max(record.bytesExpected, record.bytesWritten)
        }
    }

    /// Downloads an album, a playlist or a book: each of `items` not already
    /// here. Nil on success (or nothing to do), otherwise what to tell the
    /// viewer. `art` is whose cover to keep for it.
    func download(group id: String, kind: DownloadGroup.Kind, name: String, byLine: String? = nil, pageId: String,
                  items: [BaseItem], art: BaseItem?, client: MediaBrowserClient) async -> String? {
        let items = items.filter(\.isPlayableAudio)
        guard !items.isEmpty else { return nil }
        var group = groups[id] ?? DownloadGroup(id: id, kind: kind, name: name, byLine: byLine, pageId: pageId,
                                                itemIds: [], addedAt: Date())
        group.itemIds = items.map(\.id)
        group.announced = false
        groups[id] = group
        saveGroups()
        if group.imageFileName == nil, let art, let imageURL = client.imageURL(for: art, type: "Primary", maxWidth: 1000) {
            Task {
                guard let bytes = await Self.picture(imageURL) else { return }
                let file = "group-" + id.filter { $0.isLetter || $0.isNumber }.prefix(64) + ".jpg"
                try? bytes.write(to: Self.folder.appendingPathComponent(file))
                groups[id]?.imageFileName = file
                saveGroups()
            }
        }
        await DownloadNotices.shared.askLeave()
        for item in items {
            // One that failed before starts again.
            if records[item.id]?.state == .failed { discard(item.id) }
            switch await begin(item, client: client, startingOver: false, standalone: false) {
            case nil: continue
            case .unreachable: return String(localized: "Couldn't start the download. Check the connection to your server.")
            case .noSpace(let message): return message
            }
        }
        // All of it here already (downloaded before, for itself or another album).
        announce(groupsHolding: items[0].id)
        return nil
    }

    /// An album, playlist or book whose songs didn't all come down: the rest
    /// asked for again.
    func retry(group id: String, client: MediaBrowserClient) async -> String? {
        guard let group = groups[id] else { return nil }
        var items: [BaseItem] = []
        for itemId in group.itemIds where fileURL(itemId) == nil && records[itemId]?.state != .downloading {
            if let kept = item(itemId) {
                items.append(kept)
            } else if let (_, fetched) = try? await client.itemData(id: itemId) {
                items.append(fetched)
            }
        }
        for item in items {
            if records[item.id]?.state == .failed { discard(item.id) }
            switch await begin(item, client: client, startingOver: false, standalone: false) {
            case nil: continue
            case .unreachable: return String(localized: "Couldn't start the download. Check the connection to your server.")
            case .noSpace(let message): return message
            }
        }
        return nil
    }

    /// Takes an album, a playlist or a book off the device: each of its songs
    /// or parts that isn't also kept for itself or for another, stopped if
    /// it's coming down.
    func remove(group id: String) async {
        guard let group = groups[id] else { return }
        dropGroup(id)
        saveGroups()
        let tasks = await session.allTasks
        for itemId in group.itemIds where !isKeptElsewhere(itemId) {
            tasks.filter { $0.taskDescription == itemId }.forEach { $0.cancel() }
            discard(itemId)
        }
    }

    private func dropGroup(_ id: String) {
        if let image = groups[id]?.imageFileName {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(image))
        }
        groups[id] = nil
    }

    private func isKeptElsewhere(_ itemId: String) -> Bool {
        records[itemId]?.isStandalone == true || groups.values.contains { $0.itemIds.contains(itemId) }
    }

    /// Each album, playlist or book holding `itemId` that has now all come
    /// down, told once.
    private func announce(groupsHolding itemId: String) {
        for (key, group) in groups where !group.announced && group.itemIds.contains(itemId) {
            guard group.itemIds.allSatisfy({ records[$0]?.state == .done }) else { continue }
            groups[key]?.announced = true
            saveGroups()
            DownloadNotices.shared.finished(name: group.name, pageId: group.pageId,
                                            picture: group.imageFileName.map { Self.folder.appendingPathComponent($0) })
        }
    }


    // MARK: Where the viewer got to

    /// Called with every progress report, and when playback stops. `sent` is
    /// whether the server heard it; if not (offline), it's sent the next time
    /// the app can reach it.
    func notePosition(_ id: String, ticks: Int64, sent: Bool) {
        guard let record = records[id] else { return }
        records[id]?.positionTicks = ticks
        records[id]?.positionUnsent = !sent
        // The index holds every download's item, so it isn't rewritten every
        // ten seconds of playback. It is when the server didn't hear (the
        // position has to outlast the app to reach it later), when that
        // changes, and at least every minute of film, so resuming offline
        // after the app was stopped lands close.
        let moved = abs(ticks - (savedPositions[id] ?? 0))
        if !sent || record.positionUnsent || moved >= 60 * 10_000_000 {
            savedPositions[id] = ticks
            save()
        }
    }

    /// Tells the server where downloads watched offline got to.
    func sendPositions(client: MediaBrowserClient) async {
        for record in records.values where record.positionUnsent {
            if (try? await client.setResumePosition(record.id, ticks: record.positionTicks)) != nil {
                records[record.id]?.positionUnsent = false
            }
        }
        save()
    }

    /// Space the system would give an important download, in bytes.
    private static var freeSpace: Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A picture the server has, or nil: one it hasn't answers with an error
    /// page, which kept as a .jpg showed as a broken picture.
    nonisolated private static func picture(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !bytes.isEmpty else { return nil }
        return bytes
    }

    /// What to fetch for an item and the file's extension. A film or episode:
    /// its original file. A song or a part of a book: its original file where
    /// Apple's player reads it, named by its kind so the player knows it;
    /// otherwise (Ogg, Opus, WMA) the server makes an MP3 of it.
    struct Plan {
        let url: URL
        let ext: String
        /// The quality of a smaller copy the server makes; nil for the file as it is.
        var quality: DownloadQuality? = nil
    }

    private static func fetch(item: BaseItem, source: MediaSource, client: MediaBrowserClient) -> Plan? {
        guard item.isPlayableAudio else {
            // The quality chosen for downloads, where the file is bigger than it.
            let quality = PlaybackPreferences.downloadQuality
            if quality.converts(source), let url = client.convertedDownloadURL(item: item, source: source, quality: quality) {
                return Plan(url: url, ext: "mp4", quality: quality)
            }
            return client.downloadURL(item: item, source: source).map { Plan(url: $0, ext: fileExtension(source.container)) }
        }
        let containers = Set((source.container ?? item.container ?? "").lowercased().split(separator: ",").map(String.init))
        let codecs = (source.mediaStreams ?? []).filter { $0.type == "Audio" }.compactMap { $0.codec?.lowercased() }
        if let kind = containers.first(where: { MediaBrowserClient.playableSongContainers.contains($0) }),
           codecs.allSatisfy({ MediaBrowserClient.playableSongCodecs.contains($0) }) {
            let ext = kind == "mov" || kind == "mp4" ? "m4a" : kind
            return client.downloadURL(item: item, source: source).map { Plan(url: $0, ext: ext) }
        }
        return client.audioDownloadURL(item: item, source: source).map { Plan(url: $0, ext: "mp3") }
    }

    /// A converted copy's text subtitles, each as a WebVTT file beside it. The
    /// server may take minutes to extract one from a big file the first time.
    private func fetchSubtitles(_ id: String, client: MediaBrowserClient) async {
        guard let item = item(id), let source = item.mediaSources?.first else { return }
        var files: [String: String] = records[id]?.subtitleFiles ?? [:]
        for (index, url) in client.subtitleDownloads(item: item, source: source) where files[String(index)] == nil {
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.setValue(MediaBrowserClient.streamUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { continue }
            let name = "\(id).sub\(index).vtt"
            guard (try? data.write(to: Self.folder.appendingPathComponent(name))) != nil else { continue }
            files[String(index)] = name
        }
        guard records[id] != nil else {
            // Removed meanwhile: what came is thrown away.
            for name in files.values { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name)) }
            return
        }
        records[id]?.subtitleFiles = files
        save()
    }

    /// "mkv", or "mp4" for the list of names MP4 goes by.
    private static func fileExtension(_ container: String?) -> String {
        let first = container?.split(separator: ",").first.map(String.init)?.lowercased() ?? "mkv"
        switch first {
        case "mov", "mp4", "m4v": return first == "mov" ? "mov" : "mp4"
        case "": return "mkv"
        default: return first
        }
    }
}

extension Downloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            guard var record = records[id], record.state == .downloading else { return }
            // Published once a whole percent: every download's row and every
            // episode card's badge redraws on each change, and the session
            // reports every few kilobytes.
            let shown = Self.percent(record.bytesWritten, of: record.bytesExpected)
            record.bytesWritten = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { record.bytesExpected = totalBytesExpectedToWrite }
            guard Self.percent(record.bytesWritten, of: record.bytesExpected) != shown else { return }
            // Getting somewhere again: the tries at picking it up are for a
            // download that keeps breaking off where it is, not for every
            // break in a long one.
            record.resumeAttempts = nil
            records[id] = record
        }
    }

    /// Whole percent, or nil while the size isn't known.
    private static func percent(_ written: Int64, of expected: Int64) -> Int64? {
        expected > 0 ? written * 100 / expected : nil
    }

    /// The file is only there until this returns, so it's moved here, now.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            guard var record = records[id] else {
                try? FileManager.default.removeItem(at: location)
                return
            }
            guard (200..<300).contains(status) else {
                record.state = .failed
                records[id] = record
                save()
                if let item = item(id), record.isStandalone { DownloadNotices.shared.failed(item) }
                return
            }
            let destination = Self.folder.appendingPathComponent(record.fileName)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                record.bytesWritten = size
                record.bytesExpected = size
                record.state = .done
            } catch {
                record.state = .failed
            }
            records[id] = record
            save()
            // A song or part that came for an album, playlist or book is told
            // with the rest of it, once, not by itself.
            if let item = item(id), record.isStandalone {
                if record.state == .done {
                    DownloadNotices.shared.finished(item, picture: record.imageFileName.map { Self.folder.appendingPathComponent($0) })
                } else {
                    DownloadNotices.shared.failed(item)
                }
            }
            if record.state == .done { announce(groupsHolding: id) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let failure = error as NSError
        let cancelled = failure.code == NSURLErrorCancelled
        // The system hands back what it had when a download breaks off: the
        // app force-quit while it ran, the connection gone, a server that
        // stopped answering. Enough to carry on from there.
        let resumeData = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            // Cancelled on purpose: the record is already gone.
            guard records[id]?.state == .downloading else { return }
            if let resumeData {
                records[id]?.resumeData = resumeData
                save()
                // A moment, in case the connection is still settling. Not with
                // the app put away: the system woke it only to hear this, and
                // has it asleep again before the moment is up.
                if UIApplication.shared.applicationState == .background {
                    resumeDownload(id)
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        resumeDownload(id)
                    }
                }
                return
            }
            // Stopped by the system with nothing to carry on from (the app
            // force-quit before any of it had come): it starts over when the
            // server is next reached.
            guard !cancelled else {
                stalled.insert(id)
                return
            }
            records[id]?.state = .failed
            save()
            if let item = item(id), records[id]?.isStandalone == true { DownloadNotices.shared.failed(item) }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }
}
#endif
