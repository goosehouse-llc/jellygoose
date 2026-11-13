import CarPlay

/// JellyGoose on the car's display: Home, the libraries and a search as
/// CarPlay lists, for choosing something to watch while parked.
///
/// A CarPlay video app (iOS 27) browses with CarPlay's own templates and plays
/// through AirPlay video; the car shows the picture when it allows one and the
/// sound alone otherwise. Nothing here draws on the car's screen itself.
///
/// The car can connect with the phone locked and the app's own window never
/// opened, so this reads the signed-in session the way the Apple TV's Top
/// Shelf does (`SharedSession`) rather than through the app's state.
///
/// The car allows five screens deep and no more. The deepest ways through are
/// Libraries, a library, a letter, a show, a season, and Libraries,
/// Collections, a collection, a show, a season: five each.
///
/// It also shows only so many rows in a list (`rowLimit`) and drops the rest
/// without a word. So no list is given more than that: a letter with many
/// titles is offered in stretches ("Sa – Sc"), and any other long list a
/// screenful at a time, both by changing the rows of the screen that's up
/// rather than opening another, which would use up the five (see
/// `CarPlayBrowse`).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPSearchTemplateDelegate,
                                  CPSessionConfigurationDelegate, CPNowPlayingTemplateObserver {
    private var interface: CPInterfaceController?
    /// What the connected car can do: show a picture, or only play sound.
    private var carSession: CPSessionConfiguration?
    private var client: MediaBrowserClient?
    private let home = CPListTemplate(title: String(localized: "Home", comment: "Menu section: the home screen"), sections: [])
    private let libraries = CPListTemplate(title: String(localized: "Libraries"), sections: [])
    /// The server's channels, where the account has any: a tab of its own.
    private let liveTV = CPListTemplate(title: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                                        sections: [])
    /// The account's music, where it has any: a tab of its own.
    let music = CPListTemplate(title: String(localized: "Music", comment: "Eyebrow above a music library's name"), sections: [])
    var hasMusic = false
    private var hasChannels = false
    private var tabBar: CPTabBarTemplate?
    /// What each row of the search's results stands for.
    private var searchResults: [ObjectIdentifier: BaseItem] = [:]
    private var searching: Task<Void, Never>?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        carSession = CPSessionConfiguration(delegate: self)
        home.tabImage = UIImage(systemName: "house")
        libraries.tabImage = UIImage(systemName: "film.stack")
        liveTV.tabImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
        music.tabImage = UIImage(systemName: "music.note")
        // A search, from either tab: a library of thousands is more than the
        // car will list. Video apps may show one from iOS 27.
        for list in [home, libraries, music] { addSearch(to: list) }
        let tabs = CPTabBarTemplate(templates: [home, libraries])
        tabBar = tabs
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        // On Now Playing: the audio track and the subtitle of what's playing,
        // or for music, shuffle, repeat and what's to come.
        CPNowPlayingTemplate.shared.add(self)
        nowPlayingButtons(forMusic: MusicPlayer.shared.isActive && CarPlayPlayer.shared.current == nil)
        reload()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        interface = nil
        carSession = nil
        // Nobody's listening to a channel in a car that's gone, and it holds
        // a tuner: let go. (A film pauses on its own, the sound having
        // nowhere to go, and can be carried on.)
        if CarPlayPlayer.shared.isLive { Task { await CarPlayPlayer.shared.stop() } }
    }

    /// Whether the car can show a picture at all (it may not at the moment,
    /// while driving, and then plays the sound of the same stream). One that
    /// can't is given the sound alone. Before iOS 26.4 no car shows an app's
    /// video.
    private var showsPicture: Bool {
        guard #available(iOS 26.4, *) else { return false }
        return carSession?.supportsVideoPlayback ?? false
    }

    /// The scene comes forward again (the app's icon chosen on the car's
    /// screen): what's in progress may have moved on since.
    func sceneWillEnterForeground(_ scene: UIScene) {
        if interface != nil { reload() }
    }

    // MARK: Home and the libraries

    private func reload() {
        guard let session = SharedSession.current() else {
            // Signing in is done on the phone: there's no typing an address here.
            client = nil
            let message = [String(localized: "Open JellyGoose on your iPhone to sign in",
                                  comment: "Shown on the car's display when nobody is signed in")]
            for list in [home, libraries] {
                list.emptyViewTitleVariants = message
                list.updateSections([])
            }
            hasMusic = false
            hasChannels = false
            updateTabs()
            return
        }
        client = session.client
        let hidden = session.hiddenNextUp
        Task {
            // Both shelves on the one list: half the car's rows each, at most.
            let each = min(12, max(1, Self.rowLimit / 2))
            async let resume = try? session.client.resumeItems(limit: each)
            async let next = try? session.client.nextUp(limit: each)
            // What's part-watched plays when chosen: it's why it's on this list.
            let sections = [
                section(String(localized: "Continue Watching"), await resume ?? [], opens: false),
                section(String(localized: "Next Up"),
                        Array((await next ?? []).filter { !hidden.contains($0.id) }.prefix(each)), opens: false),
            ].compactMap { $0 }
            home.emptyViewTitleVariants = [String(localized: "Nothing in progress",
                                                  comment: "Shown on the car's display when Home has no rows")]
            home.updateSections(sections)
        }
        Task {
            async let views = try? session.client.userViews()
            // Favourites and Collections only when there's something in them,
            // as in the app's own menu.
            async let favourite = try? session.client.favorites(limit: 1)
            async let collected = try? session.client.videoCollections()
            // Music has a tab of its own.
            let all = await views ?? []
            loadMusic(all.filter(\.holdsMusic), from: session.client)
            let rows = all.filter { !$0.holdsMusic && !$0.holdsBooks }.map { library in
                row(title: library.displayTitle, symbol: library.librarySymbol) { [weak self] in
                    await self?.open(library)
                }
            }
            var more: [CPListItem] = []
            if await favourite?.isEmpty == false {
                more.append(row(title: String(localized: "Favourites"), symbol: "star") { [weak self] in
                    await self?.openFavourites()
                })
            }
            if await collected?.isEmpty == false {
                more.append(row(title: String(localized: "Collections"), symbol: "square.stack") { [weak self] in
                    await self?.openCollections()
                })
            }
            libraries.updateSections([rows, more].filter { !$0.isEmpty }.map { CPListSection(items: $0) })
        }
        Task { await loadChannels(from: session.client) }
    }

    // MARK: Live TV

    /// The channels, favourites first and then the rest in the tuner's
    /// order, each with what's on it now. The tab is there only while the
    /// account has channels to watch.
    private func loadChannels(from client: MediaBrowserClient) async {
        let all = (try? await client.liveChannels()) ?? []
        let channels = all.filter(\.isFavorite) + all.filter { !$0.isFavorite }
        hasChannels = !channels.isEmpty
        updateTabs()
        guard !channels.isEmpty else { return }
        fill(liveTV, with: channels) { [weak self] in self?.row(for: $0, among: channels) }
    }

    private func row(for channel: LiveChannel, among channels: [LiveChannel]) -> CPListItem {
        let detail = [channel.number, channel.now?.name].compactMap { $0 }.joined(separator: " · ")
        let row = CPListItem(text: channel.name, detailText: detail.isEmpty ? nil : detail, image: Self.blank)
        if #available(iOS 26.4, *) {
            // On the air: no duration, nothing to resume.
            row.playbackConfiguration = CPPlaybackConfiguration(preferredPresentation: showsPicture ? .video : .audio,
                                                                playbackAction: .play, elapsedTime: .zero, duration: .zero)
        }
        row.handler = { [weak self] _, done in
            Task {
                await self?.play(channel, among: channels)
                done()
            }
        }
        if let url = client?.channelLogoURL(channel, maxWidth: Int(CPListItem.maximumImageSize.width * 3)) {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
                row.setImage(image)
            }
        }
        return row
    }

    private func play(_ channel: LiveChannel, among channels: [LiveChannel]) async {
        guard let client else { return }
        guard await CarPlayPlayer.shared.playLive(channel, among: channels, client: client, audioOnly: !showsPicture) else {
            let alert = CPAlertTemplate(titleVariants: [Unlock.shared.mayPlay
                                                        ? String(localized: "Couldn't get this channel. Every tuner may be in use.",
                                                                 comment: "Live TV: the server had no stream to give for the channel")
                                                        : CarScreenModel.lockedNotice],
                                        actions: [CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
                                            self?.interface?.dismissTemplate(animated: true, completion: nil)
                                        }])
            interface?.presentTemplate(alert, animated: true, completion: nil)
            return
        }
        if #unavailable(iOS 26.4) {
            interface?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    /// Home and the libraries always; Music and Live TV while the account has some.
    func updateTabs() {
        guard let tabBar else { return }
        let wanted: [CPTemplate] = [home, libraries] + (hasMusic ? [music] : []) + (hasChannels ? [liveTV] : [])
        if tabBar.templates.map(ObjectIdentifier.init) != wanted.map(ObjectIdentifier.init) { tabBar.updateTemplates(wanted) }
    }

    /// Everything marked a favourite, newest first.
    private func openFavourites() async {
        guard let client else { return }
        let items = (try? await client.favorites()) ?? []
        let list = CPListTemplate(title: String(localized: "Favourites"), sections: [])
        fill(list, with: items) { [weak self] in self?.row(for: $0, opens: true) }
        push(list)
    }

    /// The server's collections and playlists; each opens to what's in it.
    private func openCollections() async {
        guard let client else { return }
        let collections = (try? await client.videoCollections()) ?? []
        let list = CPListTemplate(title: String(localized: "Collections"), sections: [])
        fill(list, with: collections) { [weak self] collection in
            guard let self else { return nil }
            let row = self.plainRow(for: collection)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, done in
                Task { await self?.open(collection: collection); done() }
            }
            return row
        }
        push(list)
    }

    private func open(collection: BaseItem) async {
        guard let client else { return }
        // A playlist keeps the order it was given, as when the app plays one
        // through; a collection's films and shows go by name.
        let inside: [BaseItem]
        if collection.type == "Playlist" {
            inside = (try? await client.playQueue(for: collection, shuffled: false)) ?? []
        } else {
            inside = (try? await client.libraryItems(parentId: collection.id, limit: 500,
                                                     itemTypes: "Movie,Series"))?.items ?? []
        }
        let list = CPListTemplate(title: collection.displayTitle, sections: [])
        list.emptyViewTitleVariants = [String(localized: "Nothing here yet.")]
        fill(list, with: inside) { [weak self] in self?.row(for: $0, opens: true) }
        push(list)
    }

    // MARK: A library

    /// A library: what was added lately, then the letters it's filed under,
    /// each saying how many titles it holds. Its titles all at once are more
    /// than the car will list, and more than anyone would scroll.
    private func open(_ library: BaseItem) async {
        guard let client else { return }
        let kind = Self.kind(of: library)
        // "#" is what's filed before A, and "…" what's filed after Z (names
        // in other alphabets).
        let alphabet = ["#"] + (65...90).map { String(UnicodeScalar($0)) } + ["…"]
        async let recent = try? client.latest(in: library, limit: 8)
        // How many under each letter, a few letters at a time. A letter with
        // none is left out; with no answer at all, every letter is offered.
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: alphabet.count, by: 9) {
            await withTaskGroup(of: (String, Int?).self) { group in
                for letter in alphabet[start..<min(start + 9, alphabet.count)] {
                    group.addTask {
                        (letter, try? await client.titleCount(parentId: library.id, letter: letter, itemTypes: kind))
                    }
                }
                for await (letter, count) in group { counts[letter] = count }
            }
        }
        let letters = counts.isEmpty ? alphabet : alphabet.filter { (counts[$0] ?? 0) > 0 }
        let latest = await recent ?? []

        let list = CPListTemplate(title: library.displayTitle, sections: [])
        list.emptyViewTitleVariants = [String(localized: "Nothing here yet.")]
        addSearch(to: list)
        showLetters(of: library, letters: letters, counts: counts, latest: latest, in: list)
        push(list)
    }

    /// The library's own screen: the letters, in groups ("A – C") when the
    /// car hasn't a row for each, and above them as much of what's new as
    /// there's room left for.
    private func showLetters(of library: BaseItem, letters: [String], counts: [String: Int],
                             latest: [BaseItem], in list: CPListTemplate) {
        let groups = CarPlayBrowse.letterGroups(letters, room: Self.rowLimit)
        let rows = groups.map { group -> CPListItem in
            let total = group.reduce(0) { $0 + (counts[$1] ?? 0) }
            let detail = counts.isEmpty ? nil : Self.count(total, in: library)
            guard group.count > 1, let first = group.first, let last = group.last else {
                let letter = group[0]
                return row(title: letter, symbol: nil, detail: detail) { [weak self] in
                    await self?.open(letter: letter, of: library, count: counts[letter])
                }
            }
            // Several letters to a row: chosen, the row's letters take the
            // screen, with a way back to them all.
            return row(title: "\(first) – \(last)", symbol: nil, detail: detail) { [weak self] in
                guard let self else { return }
                let back = self.row(title: String(localized: "All Titles"), symbol: "chevron.backward", discloses: false) { [weak self] in
                    self?.showLetters(of: library, letters: letters, counts: counts, latest: latest, in: list)
                }
                let inside = group.map { letter in
                    self.row(title: letter, symbol: nil, detail: counts.isEmpty ? nil : Self.count(counts[letter] ?? 0, in: library)) { [weak self] in
                        await self?.open(letter: letter, of: library, count: counts[letter])
                    }
                }
                list.updateSections([CPListSection(items: [back] + inside, header: "\(first) – \(last)", sectionIndexTitle: nil)])
            }
        }
        let room = max(0, Self.rowLimit - rows.count)
        let sections = [
            section(String(localized: "Recently Added"), Array(latest.prefix(room)), opens: true),
            rows.isEmpty ? nil : CPListSection(items: rows, header: "A–Z", sectionIndexTitle: nil),
        ].compactMap { $0 }
        list.updateSections(sections)
    }

    /// A letter's titles. A few go straight onto the list; many are marked
    /// out in stretches first (see `LetterShelf`).
    private func open(letter: String, of library: BaseItem, count: Int?) async {
        guard let client else { return }
        let kind = Self.kind(of: library)
        let list = CPListTemplate(title: "\(library.displayTitle) · \(letter)", sections: [])
        list.emptyViewTitleVariants = [String(localized: "Nothing here yet.")]
        addSearch(to: list)
        let shelf = LetterShelf(library: library, letter: letter, kind: kind, list: list)
        // Its names are only needed to mark out stretches: a letter known to
        // be short is listed without asking for them.
        if let count, count <= Self.titlesAtOnce {
            shelf.names = Array(repeating: "", count: count)
        } else {
            let titles = (try? await client.titleNames(parentId: library.id, letter: letter, itemTypes: kind)) ?? []
            shelf.names = titles.map { CarPlayBrowse.filedName(name: $0.displayTitle, sortName: $0.sortName) }
        }
        await show(shelf.names.indices, of: shelf)
        push(list)
    }

    /// One letter of a library on the car's display: the list its titles are
    /// shown in, and how the way through it has gone.
    private final class LetterShelf {
        let library: BaseItem
        let letter: String
        let kind: String
        let list: CPListTemplate
        /// Every title under the letter, by the name it's filed under, in order.
        var names: [String] = []
        /// The stretches gone into to reach what's on show, outermost first.
        var path: [Range<Int>] = []

        init(library: BaseItem, letter: String, kind: String, list: CPListTemplate) {
            self.library = library
            self.letter = letter
            self.kind = kind
            self.list = list
        }
    }

    /// Puts a stretch of a letter's titles on its list: the titles themselves
    /// when a list will hold them, or the stretches it divides into. Inside a
    /// stretch, the first row goes back out of it.
    private func show(_ range: Range<Int>, of shelf: LetterShelf) async {
        guard let client else { return }
        let whole = range == shelf.names.indices
        var rows: [CPListItem] = []
        if !whole {
            let outer = shelf.path.last ?? shelf.names.indices
            let title = outer == shelf.names.indices
                ? String(localized: "All of \(shelf.letter)", comment: "On the car's display: goes back from part of a letter's titles to all of them. The placeholder is the letter")
                : CarPlayBrowse.label(for: outer, names: shelf.names)
            rows.append(row(title: title, symbol: "chevron.backward", discloses: false) { [weak self] in
                if !shelf.path.isEmpty { shelf.path.removeLast() }
                await self?.show(outer, of: shelf)
            })
        }
        let room = Self.rowLimit - rows.count
        if range.count <= min(room, Self.titlesAtOnce) {
            let titles = (try? await client.libraryItems(parentId: shelf.library.id, letter: shelf.letter, itemTypes: shelf.kind,
                                                         startIndex: range.lowerBound, limit: range.count)) ?? []
            rows += titles.map { row(for: $0, opens: true) }
        } else {
            let stretches = CarPlayBrowse.stretches(of: range, names: shelf.names,
                                                    limit: min(room, Self.titlesAtOnce), fanout: room)
            rows += stretches.map { stretch in
                row(title: CarPlayBrowse.label(for: stretch, names: shelf.names), symbol: nil,
                    detail: Self.count(stretch.count, in: shelf.library)) { [weak self] in
                    shelf.path.append(range)
                    await self?.show(stretch, of: shelf)
                }
            }
        }
        let header = whole ? nil : CarPlayBrowse.label(for: range, names: shelf.names)
        shelf.list.updateSections([CPListSection(items: rows, header: header, sectionIndexTitle: nil)])
    }

    private func open(season: BaseItem, seriesId: String) async {
        guard let client else { return }
        let episodes = (try? await client.episodes(seriesId: seriesId, seasonId: season.id)) ?? []
        let list = CPListTemplate(title: season.displayTitle, sections: [])
        fill(list, with: episodes) { [weak self] in self?.row(for: $0, opens: false, inShow: true) }
        push(list)
    }

    // MARK: Fitting the car's lists

    /// How many rows the car shows in one list; it drops any past that. Never
    /// taken for less than a handful, whatever the car says.
    private static var rowLimit: Int {
        #if DEBUG
        if let rowLimitForTesting { return rowLimitForTesting }
        #endif
        return max(Int(CPListTemplate.maximumItemCount), 6)
    }

    /// The most titles put on a list at once where there's a choice: a
    /// letter with more is offered in stretches, though the car might list
    /// hundreds.
    private static var titlesAtOnce: Int { min(rowLimit - 1, CarPlayBrowse.comfortable * 3 / 2) }

    /// Films or shows, as the server calls them; or whatever else the
    /// library is of.
    private static func kind(of library: BaseItem) -> String {
        switch library.collectionType {
        case "movies": "Movie"
        case "tvshows": "Series"
        default: library.listedTypes
        }
    }

    /// "225 movies", "62 shows".
    private static func count(_ count: Int, in library: BaseItem) -> String {
        library.countText(count)
    }

    /// Fills a list from a run of things that may be longer than the car
    /// shows: a screenful at a time, the last row going on to the next and
    /// the first back to the one before, all on the list that's up. `row`
    /// is asked only for what's on show (each fetches its picture).
    private func fill<Element>(_ list: CPListTemplate, with elements: [Element], from start: Int = 0,
                               row: @escaping (Element) -> CPListItem?) {
        let shown = CarPlayBrowse.screenful(from: start, of: elements.count, room: Self.rowLimit)
        var rows = elements[shown].compactMap(row)
        let total = elements.count
        if shown.lowerBound > 0 {
            let before = CarPlayBrowse.screenful(from: max(0, shown.lowerBound - shown.count), of: total, room: Self.rowLimit)
            rows.insert(self.row(title: String(localized: "Previous", comment: "On the car's display: the row that goes back to the titles before these in a long list"),
                                 symbol: "chevron.up", detail: "\(before.lowerBound + 1)–\(before.upperBound) / \(total)", discloses: false) { [weak self] in
                self?.fill(list, with: elements, from: before.lowerBound, row: row)
            }, at: 0)
        }
        if shown.upperBound < total {
            let after = CarPlayBrowse.screenful(from: shown.upperBound, of: total, room: Self.rowLimit)
            rows.append(self.row(title: String(localized: "More", comment: "On the car's display: the row that goes on to the next titles in a long list"),
                                 symbol: "chevron.down", detail: "\(after.lowerBound + 1)–\(after.upperBound) / \(total)", discloses: false) { [weak self] in
                self?.fill(list, with: elements, from: after.lowerBound, row: row)
            })
        }
        list.updateSections([CPListSection(items: rows)])
    }

    /// A search from this screen too: the quickest way to a title whose name
    /// is known. Video apps may show one from iOS 27.
    private func addSearch(to list: CPListTemplate) {
        guard #available(iOS 27, *), let glass = UIImage(systemName: "magnifyingglass") else { return }
        list.trailingNavigationBarButtons = [CPBarButton(image: glass) { [weak self] _ in self?.openSearch() }]
    }

    private func push(_ template: CPTemplate) {
        #if DEBUG
        pushedForTesting.append(template)
        #endif
        interface?.pushTemplate(template, animated: true, completion: nil)
    }

    #if DEBUG
    // The car's screens can't be seen without the car (or Apple's leave to
    // use one), so a test walks through them instead: it reads these lists
    // and presses their rows' handlers. Debug builds only.
    var rootListsForTesting: [CPListTemplate] { [home, libraries, liveTV, music] }
    private(set) var pushedForTesting: [CPTemplate] = []
    static var rowLimitForTesting: Int?
    func reloadForTesting() { reload() }
    #endif

    // MARK: A title's page

    /// A film's page, or a show's: its picture, what it is and what it's
    /// about, with Resume or Play; a show's seasons are listed beneath.
    private func openDetails(_ item: BaseItem) async {
        guard let client else { return }
        // The lists carry no plot; the item in full does.
        let full = (try? await client.item(id: item.id)) ?? item
        var seasons: [BaseItem] = []
        var next: BaseItem?
        if full.isSeries {
            async let allSeasons = try? client.seasons(seriesId: full.id)
            async let upNext = client.nextEpisode(seriesId: full.id)
            seasons = await allSeasons ?? []
            next = await upNext
        }
        let seasonRow = { [weak self] (season: BaseItem) -> CPListItem? in
            self?.row(title: season.displayTitle, symbol: "rectangle.stack") { [weak self] in
                await self?.open(season: season, seriesId: full.id)
            }
        }
        let actions = playActions(for: full, nextEpisode: next)
        // A film's sound and subtitle can be chosen before it starts; an
        // episode's, from Now Playing once it has.
        // With the sound alone there's nothing to put a subtitle on: the
        // audio tracks only, where there's more than one.
        let soundTracks = full.mediaSources?.first?.mediaStreams?.filter { $0.type == "Audio" }.count ?? 0
        let trackRows = full.isSeries || (!showsPicture && soundTracks < 2) ? [] : [
            row(title: showsPicture ? String(localized: "Audio and Subtitles",
                                             comment: "On the car's display: opens the choice of audio track and subtitle")
                                    : String(localized: "Audio", comment: "Heading over the list of audio tracks"),
                symbol: showsPicture ? "captions.bubble" : "speaker.wave.2") { [weak self] in await self?.openTracks(for: full) },
        ]

        guard #available(iOS 26.4, *) else {
            // Before the details header: the same choices as rows of a list.
            let plays = actions.map { action in
                row(title: action.title, symbol: action.symbol, discloses: false) { await action.run() }
            }
            let seasonRows = seasons.prefix(max(0, Self.rowLimit - plays.count - trackRows.count)).compactMap(seasonRow)
            let sections = [plays, trackRows, seasonRows].filter { !$0.isEmpty }.map { CPListSection(items: $0) }
            return push(CPListTemplate(title: full.displayTitle, sections: sections))
        }

        let buttons: [CPButton] = actions.prefix(CPListTemplateDetailsHeader.maximumActionButtonCount).compactMap { action in
            guard let image = UIImage(systemName: action.symbol) else { return nil }
            let button = CPButton(image: image) { _ in Task { await action.run() } }
            button.title = action.title
            return button
        }
        let plot = (full.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let header = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: Self.blank),
            title: full.displayTitle,
            subtitle: Self.facts(about: full),
            bodyVariants: plot.isEmpty ? [] : [NSAttributedString(string: plot)],
            actionButtons: buttons)
        if !full.isSeries {
            header.playbackConfiguration = playback(of: full)
        }
        let template = CPListTemplate(title: full.displayTitle, sections: [])
        if full.isSeries {
            // A show of many seasons, a screenful at a time.
            fill(template, with: seasons, row: seasonRow)
        } else {
            template.updateSections([trackRows].filter { !$0.isEmpty }.map { CPListSection(items: $0) })
        }
        template.listHeader = header
        push(template)
        if let url = client.imageURL(for: full, type: "Primary", maxWidth: 600) {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                header.thumbnail = CPThumbnailImage(image: image)
            }
        }
    }

    private struct PlayAction {
        let title: String
        let symbol: String
        let run: () async -> Void
    }

    /// Resume and Play from Beginning for something part-watched, Play for
    /// anything else; for a show, the episode to carry on with.
    private func playActions(for item: BaseItem, nextEpisode: BaseItem?) -> [PlayAction] {
        if item.isSeries {
            guard let nextEpisode else { return [] }
            let label = nextEpisode.episodeLabel ?? nextEpisode.displayTitle
            let title = nextEpisode.resumeTicks > 0 ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
            return [PlayAction(title: title, symbol: "play.fill") { [weak self] in await self?.play(nextEpisode) }]
        }
        guard item.resumeTicks > 0 else {
            return [PlayAction(title: String(localized: "Play"), symbol: "play.fill") { [weak self] in await self?.play(item) }]
        }
        return [
            PlayAction(title: String(localized: "Resume"), symbol: "play.fill") { [weak self] in await self?.play(item) },
            PlayAction(title: String(localized: "Play from Beginning"), symbol: "arrow.counterclockwise") { [weak self] in
                await self?.play(item, fromBeginning: true)
            },
        ]
    }

    /// "2021 · 2h 27m · R": the year, how long it runs and its rating.
    private static func facts(about item: BaseItem) -> String? {
        var parts: [String] = []
        if let aired = Recorded.aired(item) {
            parts.append(aired)
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        if !item.isSeries, let runtime = item.runTimeTicks, runtime > 0 {
            parts.append(Duration.seconds(runtime / 10_000_000).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if let rating = item.officialRating, !rating.isEmpty { parts.append(rating) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Until a title's own picture arrives.
    private static let blank: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image { context in
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    }

    @available(iOS 26.4, *)
    private func playback(of item: BaseItem) -> CPPlaybackConfiguration {
        // Tells the car this plays video, so it readies its display; or, in
        // a car with no picture, that it's to be listened to.
        CPPlaybackConfiguration(preferredPresentation: showsPicture ? .video : .audio, playbackAction: .play,
                                elapsedTime: CMTime(value: item.resumeTicks, timescale: 10_000_000),
                                duration: CMTime(value: item.runTimeTicks ?? 0, timescale: 10_000_000))
    }

    // MARK: Audio and subtitles

    /// The audio tracks and subtitles of a title, the one in use ticked.
    /// Choosing another restarts what's playing from where it is: the tracks
    /// are part of the stream, and a subtitle is burnt into its picture.
    private func openTracks(for item: BaseItem) async {
        guard let client, let tracks = await CarPlayPlayer.shared.tracks(for: item, client: client) else { return }
        let list = CPListTemplate(title: String(localized: "Audio and Subtitles",
                                                comment: "On the car's display: opens the choice of audio track and subtitle"),
                                  sections: [])
        list.updateSections(trackSections(tracks, for: item, in: list))
        push(list)
    }

    private func trackSections(_ tracks: CarPlayPlayer.Tracks, for item: BaseItem, in list: CPListTemplate) -> [CPListSection] {
        func option(_ title: String, chosen: Bool, pick: @escaping () async -> Void) -> CPListItem {
            let row = CPListItem(text: title, detailText: nil, image: nil,
                                 accessoryImage: chosen ? UIImage(systemName: "checkmark") : nil, accessoryType: .none)
            row.handler = { [weak self] _, done in
                Task {
                    await pick()
                    // The tick moves to the new choice.
                    if let self, let client = self.client,
                       let now = await CarPlayPlayer.shared.tracks(for: item, client: client) {
                        list.updateSections(self.trackSections(now, for: item, in: list))
                    }
                    done()
                }
            }
            return row
        }
        func name(_ stream: MediaStream) -> String {
            stream.displayTitle ?? stream.title ?? stream.language ?? String(localized: "Unknown")
        }
        let audio = tracks.audio.compactMap { stream -> CPListItem? in
            guard let index = stream.index else { return nil }
            return option(name(stream), chosen: index == tracks.chosenAudio) {
                await CarPlayPlayer.shared.choose(audio: index, for: item.id)
            }
        }
        let off = option(String(localized: "Off", comment: "Subtitles are turned off"),
                         chosen: tracks.chosenSubtitle == PlaybackContext.subtitlesOff) {
            await CarPlayPlayer.shared.choose(subtitle: PlaybackContext.subtitlesOff, for: item.id)
        }
        let subtitles = tracks.subtitles.compactMap { stream -> CPListItem? in
            guard let index = stream.index else { return nil }
            return option(name(stream), chosen: index == tracks.chosenSubtitle) {
                await CarPlayPlayer.shared.choose(subtitle: index, for: item.id)
            }
        }
        var sections: [CPListSection] = []
        if audio.count > 1 {
            sections.append(CPListSection(items: audio, header: String(localized: "Audio", comment: "Heading over the list of audio tracks"),
                                          sectionIndexTitle: nil))
        }
        // Not with the sound alone: there's no picture to put one on.
        if showsPicture {
            sections.append(CPListSection(items: [off] + subtitles, header: String(localized: "Subtitles"), sectionIndexTitle: nil))
        }
        return sections
    }

    // MARK: Search

    private func openSearch() {
        let search = CPSearchTemplate()
        search.delegate = self
        push(search)
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        searching?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespaces)
        guard let client, term.count >= 2 else {
            searchResults = [:]
            return completionHandler([])
        }
        searching = Task { [weak self] in
            // A beat, so a word being typed isn't searched for a letter at a time.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return completionHandler([]) }
            var found = (try? await client.search(term)) ?? []
            if self.hasMusic, let music = try? await client.searchMusic(term) {
                found += music.artists + music.albums + music.songs
            }
            guard !Task.isCancelled else { return completionHandler([]) }
            var results: [ObjectIdentifier: BaseItem] = [:]
            let rows = found.prefix(Int(CPListTemplate.maximumItemCount)).map { item in
                let row = self.plainRow(for: item)
                results[ObjectIdentifier(row)] = item
                return row
            }
            self.searchResults = results
            completionHandler(Array(rows))
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let found = searchResults[ObjectIdentifier(item)] else { return completionHandler() }
        Task {
            if found.isMusic {
                await openMusic(found)
            } else {
                await openDetails(found)
            }
            completionHandler()
        }
    }

    // MARK: Rows

    private func section(_ title: String, _ items: [BaseItem], opens: Bool) -> CPListSection? {
        guard !items.isEmpty else { return nil }
        return CPListSection(items: items.map { row(for: $0, opens: opens) }, header: title, sectionIndexTitle: nil)
    }

    /// A title's row with nothing to do when chosen: its words and its picture.
    private func plainRow(for item: BaseItem, inShow: Bool = false) -> CPListItem {
        let title: String
        let detail: String?
        if item.isEpisode {
            title = inShow ? item.displayTitle : (item.seriesName ?? item.displayTitle)
            detail = inShow ? item.episodeLabel : [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        } else if item.type == "Season" {
            // A season on its own (several of its episodes arrived together):
            // the show's name over it, as an episode has.
            title = item.seriesName ?? item.displayTitle
            detail = item.seriesName == nil ? nil : item.displayTitle
        } else {
            title = item.displayTitle
            detail = Recorded.aired(item) ?? item.productionYear.map(String.init)
        }
        let row = CPListItem(text: title, detailText: detail)
        loadPicture(for: item, into: row)
        return row
    }

    /// A title in a list. With `opens`, choosing it shows its page; without,
    /// a film or an episode plays (a show always opens: there's no playing a
    /// show without saying which episode).
    private func row(for item: BaseItem, opens: Bool, inShow: Bool = false) -> CPListItem {
        let row = plainRow(for: item, inShow: inShow)
        if item.type == "Season", let seriesId = item.seriesId {
            // A season opens to its episodes: it has no page, and can't be played as one thing.
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, done in
                Task { await self?.open(season: item, seriesId: seriesId); done() }
            }
        } else if item.isSeries || (opens && !item.isEpisode) {
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, done in
                Task { await self?.openDetails(item); done() }
            }
        } else {
            if let runtime = item.runTimeTicks, runtime > 0, item.resumeTicks > 0 {
                row.playbackProgress = CGFloat(item.resumeTicks) / CGFloat(runtime)
            }
            if #available(iOS 26.4, *) {
                row.playbackConfiguration = playback(of: item)
            }
            row.handler = { [weak self] _, done in
                Task { await self?.play(item); done() }
            }
        }
        return row
    }

    private func row(title: String, symbol: String?, detail: String? = nil, discloses: Bool = true,
                     action: @escaping () async -> Void) -> CPListItem {
        let row = CPListItem(text: title, detailText: detail, image: symbol.flatMap { UIImage(systemName: $0) })
        if discloses { row.accessoryType = .disclosureIndicator }
        row.handler = { _, done in
            Task { await action(); done() }
        }
        return row
    }

    /// The poster (an episode's still), fetched after the row is up.
    private func loadPicture(for item: BaseItem, into row: CPListItem) {
        let width = Int(CPListItem.maximumImageSize.width * 3)
        guard let url = client?.imageURL(for: item, type: "Primary", maxWidth: max(width, 120)) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            row.setImage(image)
        }
    }

    // MARK: Playing

    private func play(_ item: BaseItem, fromBeginning: Bool = false) async {
        guard let client else { return }
        nowPlayingButtons(forMusic: false)
        let started = await CarPlayPlayer.shared.play(item, client: client, fromBeginning: fromBeginning,
                                                      audioOnly: !showsPicture)
        guard started else {
            let alert = CPAlertTemplate(titleVariants: [Unlock.shared.mayPlay
                                                        ? String(localized: "Couldn't play this",
                                                                 comment: "Shown on the car's display when a title won't start")
                                                        : CarScreenModel.lockedNotice],
                                        actions: [CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
                                            self?.interface?.dismissTemplate(animated: true, completion: nil)
                                        }])
            interface?.presentTemplate(alert, animated: true, completion: nil)
            return
        }
        // Before iOS 26.4 nothing presents playback for the app: the Now
        // Playing screen is shown here. From 26.4 the row says how it plays
        // and the car presents the picture, or Now Playing, itself.
        if #unavailable(iOS 26.4) {
            interface?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }
}

// MARK: - Music

extension CarPlaySceneDelegate {
    /// The Music tab: Shuffle All and the ways into the library, then the
    /// songs played last and the albums added lately. (The first music
    /// library's, where there are several.)
    func loadMusic(_ libraries: [BaseItem], from client: MediaBrowserClient) {
        hasMusic = !libraries.isEmpty
        updateTabs()
        guard let library = libraries.first else { return }
        Task {
            async let played = try? client.recentlyPlayedSongs(limit: 8)
            async let recent = try? client.latest(in: library.id, limit: 8, types: nil)
            let ways = [
                row(title: String(localized: "Shuffle All", comment: "Plays a whole music library in no order"), symbol: "shuffle",
                    discloses: false) { [weak self] in
                    self?.playMusic(source: library.displayTitle, shuffled: true) {
                        try await client.shuffledSongs(in: library.id, limit: 300)
                    }
                },
                row(title: String(localized: "Playlists", comment: "Music library: the server's playlists of songs"), symbol: "music.note.list") { [weak self] in
                    await self?.openPlaylists()
                },
                row(title: String(localized: "Artists", comment: "Music library: who made its albums"), symbol: "music.mic") { [weak self] in
                    await self?.openArtists(of: library)
                },
                row(title: String(localized: "Albums", comment: "Music library: its albums"), symbol: "square.stack") { [weak self] in
                    await self?.openAlbums(of: library)
                },
            ]
            let room = max(0, Self.rowLimit - ways.count)
            let songs = Array((await played ?? []).prefix(room / 2))
            let albums = Array((await recent ?? []).prefix(room - songs.count))
            var sections = [CPListSection(items: ways)]
            if !songs.isEmpty {
                sections.append(CPListSection(items: songs.enumerated().map { place, song in
                    songRow(song, among: songs, at: place, source: String(localized: "Recently Played", comment: "Music: the songs played last"))
                }, header: String(localized: "Recently Played", comment: "Music: the songs played last"), sectionIndexTitle: nil))
            }
            if !albums.isEmpty {
                sections.append(CPListSection(items: albums.map(musicRow), header: String(localized: "Recently Added"), sectionIndexTitle: nil))
            }
            music.updateSections(sections)
        }
    }

    /// An album, a playlist or an artist: its row, opening it.
    func musicRow(_ item: BaseItem) -> CPListItem {
        let row = CPListItem(text: item.displayTitle, detailText: item.isArtist ? nil : item.byLine)
        row.accessoryType = .disclosureIndicator
        loadPicture(for: item, into: row)
        row.handler = { [weak self] _, done in
            Task { await self?.openMusic(item); done() }
        }
        return row
    }

    /// A song in a list: chosen, it plays and the rest of the list follows.
    func songRow(_ song: BaseItem, among songs: [BaseItem], at place: Int, source: String?) -> CPListItem {
        let detail = [song.byLine, song.songLength].compactMap { $0 }.joined(separator: " · ")
        let row = CPListItem(text: song.displayTitle, detailText: detail.isEmpty ? nil : detail)
        loadPicture(for: song, into: row)
        row.isPlaying = MusicPlayer.shared.current?.id == song.id
        row.handler = { [weak self] _, done in
            self?.playMusic(songs, from: place, source: source)
            done()
        }
        return row
    }

    func openMusic(_ item: BaseItem) async {
        if item.isArtist { await openArtist(item) }
        else if item.isSong { playMusic([item], source: item.album) }
        else { await openSongs(of: item) }
    }

    /// An album's songs or a playlist's, under Play and Shuffle.
    func openSongs(of container: BaseItem) async {
        guard let client else { return }
        let playlist = container.type == "Playlist"
        let songs = ((try? await client.tracks(of: container.id, playlist: playlist)) ?? []).filter(\.isSong)
        let list = CPListTemplate(title: container.displayTitle, sections: [])
        list.emptyViewTitleVariants = [String(localized: "Nothing here yet.")]
        let source = container.displayTitle
        let top = [
            row(title: String(localized: "Play"), symbol: "play.fill", discloses: false) { [weak self] in
                self?.playMusic(songs, source: source)
            },
            row(title: String(localized: "Shuffle"), symbol: "shuffle", discloses: false) { [weak self] in
                self?.playMusic(songs, shuffled: true, source: source)
            },
        ]
        // The first screenful under Play and Shuffle; the rest a screenful at a time.
        let room = max(1, Self.rowLimit - top.count)
        if songs.count <= room {
            list.updateSections([CPListSection(items: top),
                                 CPListSection(items: songs.enumerated().map { songRow($1, among: songs, at: $0, source: source) })])
        } else {
            fill(list, with: Array(songs.enumerated())) { [weak self] pair in
                self?.songRow(pair.element, among: songs, at: pair.offset, source: source)
            }
            list.updateSections([CPListSection(items: top)] + list.sections)
        }
        push(list)
    }

    /// Someone's albums, theirs then the ones they're on, under Play and Shuffle.
    func openArtist(_ artist: BaseItem) async {
        guard let client else { return }
        async let own = try? client.albums(by: artist.id)
        async let others = try? client.albums(featuring: artist.id)
        let albums = (await own ?? []) + (await others ?? [])
        let list = CPListTemplate(title: artist.displayTitle, sections: [])
        let id = artist.id
        let top = [
            row(title: String(localized: "Play"), symbol: "play.fill", discloses: false) { [weak self] in
                self?.playMusic(source: artist.displayTitle) { try await client.songs(by: id, shuffled: false, limit: 1000) }
            },
            row(title: String(localized: "Shuffle"), symbol: "shuffle", discloses: false) { [weak self] in
                self?.playMusic(source: artist.displayTitle, shuffled: true) { try await client.songs(by: id, shuffled: false, limit: 1000) }
            },
        ]
        fill(list, with: albums) { [weak self] in self?.musicRow($0) }
        list.updateSections([CPListSection(items: top)] + list.sections)
        push(list)
    }

    func openAlbums(of library: BaseItem) async {
        guard let client else { return }
        let albums = (try? await client.music(.albums, in: library.id, startIndex: 0, limit: 500,
                                               sortBy: "SortName", sortOrder: "Ascending"))?.items ?? []
        let list = CPListTemplate(title: String(localized: "Albums", comment: "Music library: its albums"), sections: [])
        fill(list, with: albums) { [weak self] in self?.musicRow($0) }
        push(list)
    }

    func openArtists(of library: BaseItem) async {
        guard let client else { return }
        let artists = (try? await client.music(.artists, in: library.id, startIndex: 0, limit: 500,
                                                sortBy: "SortName", sortOrder: "Ascending"))?.items ?? []
        let list = CPListTemplate(title: String(localized: "Artists", comment: "Music library: who made its albums"), sections: [])
        fill(list, with: artists) { [weak self] in self?.musicRow($0) }
        push(list)
    }

    func openPlaylists() async {
        guard let client else { return }
        let playlists = ((try? await client.collections(limit: 200)) ?? []).filter(\.isSongPlaylist)
        let list = CPListTemplate(title: String(localized: "Playlists", comment: "Music library: the server's playlists of songs"), sections: [])
        list.emptyViewTitleVariants = [String(localized: "No playlists of songs on this server yet.")]
        fill(list, with: playlists) { [weak self] in self?.musicRow($0) }
        push(list)
    }

    // MARK: Playing music

    func playMusic(_ songs: [BaseItem], from start: Int = 0, shuffled: Bool = false, source: String?) {
        guard let client, !songs.isEmpty else { return }
        guard Unlock.shared.mayPlay else { return musicLocked() }
        MusicPlayer.shared.play(songs, from: start, shuffled: shuffled, source: source, client: client)
        showNowPlaying()
    }

    func playMusic(source: String?, shuffled: Bool = false, songs: @escaping () async throws -> [BaseItem]) {
        guard let client else { return }
        guard Unlock.shared.mayPlay else { return musicLocked() }
        MusicPlayer.shared.play(source: source, shuffled: shuffled, client: client, songs: songs)
        showNowPlaying()
    }

    private func musicLocked() {
        let alert = CPAlertTemplate(titleVariants: [CarScreenModel.lockedNotice],
                                    actions: [CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
                                        self?.interface?.dismissTemplate(animated: true, completion: nil)
                                    }])
        interface?.presentTemplate(alert, animated: true, completion: nil)
    }

    /// CarPlay's own Now Playing, with music's buttons on it.
    private func showNowPlaying() {
        nowPlayingButtons(forMusic: true)
        guard interface?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interface?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    /// Now Playing's own buttons: shuffle and repeat, and Up Next, for
    /// music; the audio and subtitle tracks for a film.
    func nowPlayingButtons(forMusic music: Bool) {
        let now = CPNowPlayingTemplate.shared
        if music {
            // Shuffle and repeat speak to the remote commands the music
            // player answers (see `MusicPlayer`).
            now.updateNowPlayingButtons([CPNowPlayingShuffleButton { _ in }, CPNowPlayingRepeatButton { _ in }])
            now.isUpNextButtonEnabled = true
            now.upNextTitle = String(localized: "Up Next", comment: "Now Playing: the songs to come")
        } else {
            now.isUpNextButtonEnabled = false
            guard let captions = UIImage(systemName: "captions.bubble") else { return }
            now.updateNowPlayingButtons([
                CPNowPlayingImageButton(image: captions) { [weak self] _ in
                    guard let playing = CarPlayPlayer.shared.current else { return }
                    Task { await self?.openTracks(for: playing) }
                },
            ])
        }
    }

    /// Up Next on Now Playing: the songs to come; one chosen plays from there.
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let player = MusicPlayer.shared
        let coming = Array(player.upNext)
        let list = CPListTemplate(title: String(localized: "Up Next", comment: "Now Playing: the songs to come"), sections: [])
        list.emptyViewTitleVariants = [String(localized: "Nothing after this song.")]
        fill(list, with: coming) { [weak self] entry in
            let detail = [entry.song.byLine, entry.song.songLength].compactMap { $0 }.joined(separator: " · ")
            let row = CPListItem(text: entry.song.displayTitle, detailText: detail.isEmpty ? nil : detail)
            self?.loadPicture(for: entry.song, into: row)
            row.handler = { [weak self] _, done in
                if let place = player.queue.firstIndex(of: entry) { player.jump(to: place) }
                self?.interface?.popTemplate(animated: true, completion: nil)
                done()
            }
            return row
        }
        push(list)
    }
}

