import CoreSpotlight
import UIKit
import UniformTypeIdentifiers

/// The library in the device's own search: a film, a show, an album or an
/// artist typed on the Home Screen finds it, with its poster, and opens its
/// page. The account signed in's alone; gone when it signs out.
///
/// Gone through once a day as the app comes forward: what's new is added
/// (pictures fetched for those alone), what's left the server is taken out.
@MainActor
enum SpotlightIndex {
    private static let accountKey = "goosetv.spotlight.account"
    private static let doneKey = "goosetv.spotlight.done"
    private static let renewedKey = "goosetv.spotlight.renewed"
    private static var running = false
    /// Moved on by signing out: a run under way stops, rather than putting
    /// the account's titles back.
    private static var generation = 0
    /// The app's own index: its titles kept apart from anything else's.
    private static let index = CSSearchableIndex(name: "JellyGooseLibrary")

    /// What's been put in the index, by id, for the account in `accountKey`.
    private nonisolated static var listFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spotlight-indexed.json")
    }

    static func refresh(client: MediaBrowserClient, force: Bool = false) async {
        guard CSSearchableIndex.isIndexingAvailable(), !running, let userId = client.userId else { return }
        let account = client.baseURL.absoluteString + "|" + userId
        let defaults = UserDefaults.standard
        // Another account's titles out first: the search is this one's.
        if defaults.string(forKey: accountKey) != account {
            await clearAll()
            defaults.set(account, forKey: accountKey)
        }
        if !force, let done = defaults.object(forKey: doneKey) as? Date, Date().timeIntervalSince(done) < 24 * 3600 { return }
        running = true
        defer { running = false }
        let run = generation

        // Everything there is now, a thousand at a time.
        var all: [BaseItem] = []
        var start = 0
        while true {
            guard let page = try? await client.searchableTitles(startIndex: start, limit: 1000), run == generation else { return }
            all += page.items
            start += page.items.count
            if page.items.isEmpty || start >= (page.totalRecordCount ?? start) { break }
        }
        // Each title is kept a year, so every half year all of them go in again.
        let renewing = (defaults.object(forKey: renewedKey) as? Date).map { Date().timeIntervalSince($0) > 182 * 24 * 3600 } ?? true
        let had = await indexed()
        let now = Set(all.map(\.id))
        let gone = had.subtracting(now)
        // Sent, not waited on: the index's answers don't always come.
        if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: Array(gone), completionHandler: nil) }
        // New ones with their pictures, a few at a time. What's in is kept
        // here and written now and then (so a run cut short carries on where
        // it stopped), not read and written again for every few.
        var done = had.subtracting(gone)
        let fresh = renewing ? all : all.filter { !had.contains($0.id) }
        let chunks = stride(from: 0, to: fresh.count, by: 40).map { Array(fresh[$0..<min($0 + 40, fresh.count)]) }
        for (place, chunk) in chunks.enumerated() {
            let items = await withTaskGroup(of: CSSearchableItem.self) { group in
                for item in chunk { group.addTask { await searchable(item, client: client) } }
                var made: [CSSearchableItem] = []
                for await one in group { made.append(one) }
                return made
            }
            guard run == generation else { return }
            index.indexSearchableItems(items, completionHandler: nil)
            done.formUnion(chunk.map(\.id))
            if place % 25 == 24 { await save(done) }
        }
        await save(now)
        defaults.set(Date(), forKey: doneKey)
        if renewing { defaults.set(Date(), forKey: renewedKey) }
    }

    /// Signed out: none of it findable.
    static func clear() {
        generation += 1
        Task { await clearAll() }
        UserDefaults.standard.removeObject(forKey: accountKey)
        UserDefaults.standard.removeObject(forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: renewedKey)
    }

    private static func clearAll() async {
        index.deleteAllSearchableItems(completionHandler: nil)
        await save([])
    }

    /// One title as the search shows it: its name, what it is and when, its
    /// genres to be found by, and its poster.
    private nonisolated static func searchable(_ item: BaseItem, client: MediaBrowserClient) async -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: item.isMovie || item.isSeries ? .movie : .audio)
        attributes.title = item.displayTitle
        attributes.displayName = item.displayTitle
        attributes.contentDescription = describe(item)
        attributes.keywords = (item.genres ?? []) + [item.albumArtist].compactMap { $0 }
        if let url = client.imageURL(for: item, type: "Primary", maxWidth: 180),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            attributes.thumbnailData = data
        }
        let searchable = CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: "library", attributeSet: attributes)
        // Kept a year (by default the system forgets an item after a month);
        // the whole library goes in again every half year.
        searchable.expirationDate = Date(timeIntervalSinceNow: 365 * 24 * 3600)
        return searchable
    }

    /// "Film · 2021 · Drama", "Show · 2005", "Album · The Geese", "Artist".
    private nonisolated static func describe(_ item: BaseItem) -> String {
        let kind = item.isMovie ? String(localized: "Movie", comment: "Kind of item, shown in capitals above its title")
            : item.isSeries ? String(localized: "Series", comment: "Kind of item, shown in capitals above its title")
            : item.isAlbum ? String(localized: "Album", comment: "Kind of item, shown in capitals above its title")
            : String(localized: "Artist", comment: "Kind of item, shown in capitals above its title")
        let parts = [kind, item.isAlbum ? item.albumArtist : nil, item.productionYear.map(String.init), item.genres?.first]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Read and written off the main thread: the list is as long as the library.
    private static func indexed() async -> Set<String> {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: listFile), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(ids)
        }.value
    }

    private static func save(_ ids: Set<String>) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
            try? data.write(to: listFile, options: .atomic)
        }.value
    }
}
