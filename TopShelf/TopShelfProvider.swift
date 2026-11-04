import TVServices

/// What the Apple TV home screen shows above the app when JellyGoose sits in the
/// top row: what you were part-way through, then what's next in your shows.
///
/// This runs as a separate process, on tvOS's schedule rather than the app's, and
/// gets a short while to answer. It reads the session out of the shared keychain,
/// asks the server two questions, and answers with whatever came back — a server
/// that is off, or a viewer who isn't signed in, means an empty shelf rather than
/// a wait.
final class TopShelfProvider: TVTopShelfContentProvider {
    /// Sixteen fits the row on a 4K screen without asking the server for a page
    /// nobody scrolls to.
    private static let perSection = 16

    /// Long enough for a server waking a spun-down disk, short enough that the
    /// home screen isn't left waiting on one that will never answer.
    private static let budget: Double = 8

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task {
            completionHandler(await withinDeadline(Self.budget) { await Self.shelf() })
        }
    }

    private static func shelf() async -> TVTopShelfContent? {
        // The session read once: each read is a trip to the keychain.
        guard let session = SharedSession.current(), session.showsOnHomeScreen else { return nil }
        let client = session.client

        // Both at once: the shelf is one answer, so its slowest half sets the pace.
        async let resuming = try? client.resumeItems(limit: perSection)
        async let next = try? client.nextUp(limit: perSection)
        let resumeItems = await resuming ?? []
        // Less what the viewer took off Next Up in the app.
        let hidden = session.hiddenNextUp
        let nextItems = (await next ?? []).filter { !hidden.contains($0.id) }
        // Recordings come with no artwork of their own: borrowed, as the app borrows it.
        let borrowed = await recordingArt(for: resumeItems + nextItems, client)

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !resumeItems.isEmpty {
            sections.append(section(String(localized: "Continue Watching", comment: "Top Shelf row: things part-way through"), resumeItems, client, borrowed))
        }
        if !nextItems.isEmpty {
            sections.append(section(String(localized: "Next Up", comment: "Top Shelf row: the next episode of shows being watched"), nextItems, client, borrowed))
        }
        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }

    private static func section(_ title: String, _ items: [BaseItem], _ client: MediaBrowserClient,
                                _ borrowed: [String: URL]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        let collection = TVTopShelfItemCollection(items: items.map { shelfItem($0, client, borrowed[$0.id]) })
        collection.title = title
        return collection
    }

    /// What a recording wears on the shelf. Jellyfin gives one no artwork of its own,
    /// so its tile was blank; the app's cards borrow some (AppState.recordingCover),
    /// and so does the shelf, the same way: the show's or film's backdrop where the
    /// library has it, else the programme's picture the server kept in the
    /// recording's folder as it recorded. Asked only for what has no wide picture of
    /// its own, and only of a server that keeps recordings, so a shelf of films and
    /// episodes costs no more than before.
    private static func recordingArt(for items: [BaseItem], _ client: MediaBrowserClient) async -> [String: URL] {
        let bare = items.filter {
            client.imageURL(for: $0, type: "Thumb", maxWidth: 100) == nil
                && client.imageURL(for: $0, type: "Backdrop", maxWidth: 100) == nil
        }
        guard !bare.isEmpty else { return [:] }
        let folders = await client.liveRecordingFolders()
        guard !folders.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, URL?).self) { group in
            for item in bare {
                group.addTask { (item.id, await recordingCover(for: item, among: folders, client)) }
            }
            var found: [String: URL] = [:]
            for await (id, url) in group { if let url { found[id] = url } }
            return found
        }
    }

    private static func recordingCover(for item: BaseItem, among folders: Set<String>, _ client: MediaBrowserClient) async -> URL? {
        let place = await client.recordingPlace(item.id, among: folders)
        guard place.isRecording else { return nil }
        // A recording of a show is by the show's name; one with no series may be a film.
        let name = item.showName ?? ""
        var title: BaseItem?
        if !name.isEmpty {
            title = await client.libraryTitle(named: name, film: false)
            if title == nil, item.seriesName == nil { title = await client.libraryTitle(named: name, film: true) }
        }
        if let title, let url = client.imageURL(for: title, type: "Backdrop", maxWidth: 1920) { return url }
        if let folder = place.pictured { return client.imageURL(for: folder, maxWidth: 1920) }
        return nil
    }

    private static func shelfItem(_ item: BaseItem, _ client: MediaBrowserClient, _ borrowed: URL?) -> TVTopShelfSectionedItem {
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
        shelf.title = caption(for: item)
        shelf.imageShape = .hdtv

        // The tile is 16:9, and the first of these that exists fits it. An
        // episode's Primary image is its own still, already the right shape and
        // more use than the series' backdrop; a film's is a 2:3 poster, which
        // belongs here only when there is nothing else. A recording's borrowed
        // picture comes before its own, which is at best a frame from the file.
        let order = item.type == "Episode"
            ? ["Thumb", "Primary", "Backdrop"]
            : ["Thumb", "Backdrop", "Primary"]
        let artwork = borrowed ?? order.lazy
            .compactMap { client.imageURL(for: item, type: $0, maxWidth: 1920) }
            .first
        shelf.setImageURL(artwork, for: .screenScale1x)
        shelf.setImageURL(artwork, for: .screenScale2x)

        // The bar across the bottom of the tile, so a half-watched film looks it.
        if let percent = item.userData?.playedPercentage {
            shelf.playbackProgress = percent / 100
        }

        // Select opens the page; Play starts it. Both land in the app, which is
        // the only thing that can actually play anything.
        shelf.displayAction = TVTopShelfAction(url: DeepLink.display(item.id))
        shelf.playAction = TVTopShelfAction(url: DeepLink.play(item.id))
        return shelf
    }

    /// "The Cosby Show · S1E13" reads better on a shelf than an episode title
    /// nobody recognises out of context; films are just themselves.
    private static func caption(for item: BaseItem) -> String {
        let name = item.name ?? ""
        guard let series = item.seriesName else { return name }
        if let season = item.parentIndexNumber, let episode = item.indexNumber {
            return String(localized: "\(series) · S\(season)E\(episode)",
                          comment: "Top Shelf caption: series name, then S = season number, E = episode number")
        }
        return series
    }
}
