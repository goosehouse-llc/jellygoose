import Combine
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath
    /// Incremented by the parent to ask Home to jump back to the top.
    let scrollToTopRequest: Int

    /// Held by the parent, so leaving Home and coming back doesn't blank the
    /// shelves while they load all over again; watched only here. Whether
    /// focus is below the top is noted there too, for back to read.
    @ObservedObject var shelves: HomeShelves
    @State private var playingItem: BaseItem?
    /// A channel chosen from the row of what's on now.
    @State private var watchingLive: BaseItem?
    #if !os(tvOS)
    // The banner that turns between titles (iPhone and iPad; the Apple TV's
    // Home is SpotlightHome).
    @State private var heroPosition: String?
    /// The banner on show, as it was before the screen last changed width
    /// (see `realignHero`).
    @State private var heroKept: String?
    @State private var heroTurning = false
    @State private var heroPaused = false
    @FocusState private var heroFocus: String?
    @FocusState private var pauseFocused: Bool

    private let heroInterval: Double = 8

    private var heroItems: [BaseItem] { shelves.hero }

    private var heroIndex: Int {
        heroItems.firstIndex { $0.id == heroPosition } ?? 0
    }
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            homeContent
                .sectionDestinations()
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .resume:
                        ItemListGridView(title: String(localized: "Continue Watching"), eyebrow: String(localized: "In progress"), accent: Theme.palette[0],
                                         showDetails: showDetails) {
                            try await $0.resumeItems(limit: 100)
                        }
                    case .nextUp:
                        ItemListGridView(title: String(localized: "Next Up"), eyebrow: String(localized: "Your shows"), accent: Theme.palette[2],
                                         showDetails: showDetails, removesFromNextUp: true) {
                            app.visibleNextUp(try await $0.nextUp(limit: 100))
                        }
                    case .library(let library):
                        LibraryGridView(library: library)
                    case .details(let itemId):
                        ItemDetailView(itemId: itemId)
                    case .recentMusic:
                        AlbumGridView(title: HomeLayout.musicRecentTitle, eyebrow: HomeLayout.musicEyebrow) {
                            try await $0.recentlyPlayedAlbums(limit: 60)
                        }
                    case .topSongs:
                        SongListView(title: HomeLayout.musicTopTitle, eyebrow: HomeLayout.musicEyebrow) {
                            try await $0.mostPlayedSongs(limit: 100)
                        }
                    case .upcoming:
                        ComingSoonView()
                    case .pinned(let id):
                        PinnedGridView(pinId: id)
                    case .liveTV:
                        // Never pushed: see `seeAll`.
                        EmptyView()
                    }
                }
        }
        .sectionNavigation(path: $path, section: "home")
        .task {
            // Home only hears of changes while it's on screen. A film watched
            // from a library, or marked on its page there, changed Continue
            // Watching while Home was away, and coming back showed the shelves
            // as they were; so it refreshes if anything changed meanwhile.
            await load(force: shelves.loaded && shelves.fetchedAtRevision != app.userDataRevision)
            // What was played last changes with listening, which tells Home
            // nothing: asked each time Home comes on screen.
            await refreshAsked()
            if let debugID = Self.launchItemID, path.isEmpty,
               let item = try? await app.client?.item(id: debugID) {
                path.append(item)
            }
            // A cold launch from the shelf: the URL arrived before this screen did.
            await openFromShelf()
        }
        .onChange(of: app.openedFromShelf) { _, _ in
            Task { await openFromShelf() }
        }
        .playerCover(item: $playingItem) { item in
            PlayerView(item: item)
        }
        // The channel's full screen, from a view of its own behind Home:
        // two covers on the one view aren't to be relied on.
        .background {
            Color.clear.fullScreenCover(item: $watchingLive) { channel in
                if let client = app.client { LiveWatchHost(channel: channel, client: client) }
            }
        }
        // Including when any player closes, wherever it was opened.
        .onChange(of: app.userDataRevision) { _, _ in
            Task { await load(force: true) }
        }
        // Recordings arrive while Home is away, as other titles don't: their
        // row is asked again each time it comes on screen.
        .task { await refreshRecordings() }
        // Which libraries hold recordings is known only once Live TV has been
        // asked about, which may be after the rows were fetched.
        .onChange(of: app.recordingFolders) { _, _ in Task { await refreshRecordings(now: true) } }
        // What's on moves with the clock: asked when Home comes on screen
        // and every few minutes while it's there, and again when the server
        // turns out to have channels or the row is switched on or off.
        .task {
            while !Task.isCancelled {
                await loadOnNow()
                try? await Task.sleep(for: .seconds(180))
            }
        }
        .onChange(of: [app.hasLiveTV, app.showsLiveTV, app.showsOnNow]) { _, _ in
            Task { await loadOnNow() }
        }
        // A recording set or taken off from one of its cards: read again,
        // for the card to say so.
        .onChange(of: app.liveRecordingChanges) { _, _ in
            Task { await loadOnNow() }
        }
        // A recording deleted from a long press goes from the rows at once:
        // what's new in a library is otherwise kept ten minutes.
        .onChange(of: app.lastDeleted) { _, ids in
            let gone = Set(ids)
            guard !gone.isEmpty else { return }
            if shelves.resume.contains(where: { gone.contains($0.id) }) { shelves.resume.removeAll { gone.contains($0.id) } }
            if shelves.nextUp.contains(where: { gone.contains($0.id) }) { shelves.nextUp.removeAll { gone.contains($0.id) } }
            if shelves.pinned.contains(where: { $0.items.contains { gone.contains($0.id) } }) {
                shelves.pinned = shelves.pinned.compactMap { entry in
                    let kept = entry.items.filter { !gone.contains($0.id) }
                    return kept.isEmpty ? nil : (pin: entry.pin, library: entry.library, items: kept)
                }
            }
            if shelves.latest.contains(where: { $0.items.contains { gone.contains($0.id) } }) {
                app.holdMenuFocus()
                shelves.latest = shelves.latest.compactMap { entry in
                    let kept = entry.items.filter { !gone.contains($0.id) }
                    return kept.isEmpty ? nil : (library: entry.library, items: kept)
                }
            }
        }
        // A view pinned to Home, or taken off, or renamed.
        .onChange(of: app.homePins) { _, _ in
            Task { await refreshPinned() }
        }
        // The rows as arranged in Settings.
        .onChange(of: app.homeOrder, initial: true) { _, order in
            if shelves.order != order { shelves.order = order }
        }
        .onChange(of: app.homeHidden, initial: true) { _, hidden in
            if shelves.hidden != hidden { shelves.hidden = hidden }
        }
    }

    /// A card was chosen: a film or an episode plays, a channel is tuned, a
    /// song plays with the rest of the row after it.
    private func play(_ item: BaseItem) {
        // Nothing to play yet: its show's page, which says when. A season
        // (Recently Added's word for several of its episodes at once): its
        // show's page, opened on it.
        if AirDay.isComing(item) || item.type == "Season" {
            showDetails(item)
        } else if item.isAudiobook {
            // A book part-way through: carried on.
            if let client = app.client { Audiobooks.resume(item, client: client) }
        } else if item.isSong {
            guard let client = app.client else { return }
            let songs = shelves.topSongs.contains(item) ? shelves.topSongs : [item]
            MusicPlayer.shared.play(songs, from: songs.firstIndex(of: item) ?? 0, source: HomeLayout.musicTopTitle, client: client)
        } else if item.isLiveChannel {
            watchingLive = item
        } else {
            playingItem = item
        }
    }

    /// The rows asked each time Home comes on screen, since nothing tells
    /// Home of their changing: the albums played last and the songs played
    /// most (emptied where the server has no music), Coming Soon (it changes
    /// by the day) and Continue Listening (where the server has books). Asked
    /// together, and written in one go, only where something changed.
    private func refreshAsked() async {
        guard let client = app.client else { return }
        let music = app.libraries.contains(where: \.holdsMusic)
        let books = app.libraries.first(where: \.holdsBooks)
        async let recent: [BaseItem] = music ? ((try? await client.recentlyPlayedAlbums(limit: 16)) ?? []) : []
        async let top: [BaseItem] = music ? ((try? await client.mostPlayedSongs(limit: 16)) ?? []) : []
        async let airing: [BaseItem] = (try? await client.upcomingEpisodes(limit: 24)) ?? []
        async let resuming: [BaseItem] = books == nil ? [] : ((try? await client.resumeAudiobooks(limit: 16)) ?? [])
        let (albums, songs, upcoming, listening) = await (recent, top, airing.filter { AirDay.isComing($0) }, resuming)
        guard client === app.client else { return }
        // A book's place counts as well as which books: their bars move.
        let places = { (items: [BaseItem]) in items.map { "\($0.id)@\($0.userData?.playbackPositionTicks ?? 0)" } }
        let newAlbums = albums.map(\.id) != shelves.recentMusic.map(\.id)
        let newSongs = songs.map(\.id) != shelves.topSongs.map(\.id)
        let newUpcoming = upcoming.map(\.id) != shelves.upcoming.map(\.id)
        let newListening = places(listening) != places(shelves.listening) || books?.id != shelves.listeningLibrary?.id
        guard newAlbums || newSongs || newUpcoming || newListening else { return }
        app.holdMenuFocus()
        if newAlbums { shelves.recentMusic = albums }
        if newSongs { shelves.topSongs = songs }
        if newUpcoming { shelves.upcoming = upcoming }
        if newListening {
            shelves.listeningLibrary = books
            shelves.listening = listening
        }
    }

    /// A row's See all: its page, or for the row of what's on, the Live TV
    /// section with its guide.
    private func seeAll(_ route: HomeRoute) {
        if route == .liveTV { app.askForLiveTV() } else { path.append(route) }
    }

    /// The rows of recordings asked again, apart from the rest, which are
    /// kept ten minutes (see `load`). Not straight after a load has fetched them.
    private func refreshRecordings(now: Bool = false) async {
        guard let client = app.client, shelves.fetched, !app.recordingFolders.isEmpty,
              now || shelves.latestFetched.map({ Date().timeIntervalSince($0) > 20 }) ?? true else { return }
        for entry in shelves.latest where app.recordingFolders.contains(entry.library.id) {
            guard let fresh = try? await client.recentRecordings(in: entry.library.id, limit: 16),
                  fresh.map(\.id) != entry.items.map(\.id),
                  let index = shelves.latest.firstIndex(where: { $0.library.id == entry.library.id }) else { continue }
            app.holdMenuFocus()
            shelves.latest[index] = (library: entry.library, items: fresh)
        }
    }

    private func loadOnNow() async {
        guard let client = app.client, app.hasLiveTV, app.showsLiveTV, app.showsOnNow else {
            if !shelves.onNow.isEmpty {
                app.holdMenuFocus()
                shelves.onNow = []
            }
            return
        }
        let last = UserDefaults.standard.string(forKey: LiveTVModel.lastKey)
        guard let found = try? await client.liveOnNow(first: last, limit: 24), client === app.client else { return }
        // Written only when something's different: the row is rebuilt when
        // it is, and nothing is when it isn't.
        // What's set to record is part of it: the cards mark it.
        func mark(_ items: [BaseItem]) -> [String] {
            items.map { [$0.id, $0.currentProgram?.id ?? "", $0.currentProgram?.timerId ?? "", $0.currentProgram?.seriesTimerId ?? ""].joined(separator: "|") }
        }
        if mark(found) != mark(shelves.onNow) {
            app.holdMenuFocus()
            shelves.onNow = found
        }
    }

    /// Dev convenience: GOOSETV_ITEM=<id> opens that item's detail page.
    /// Read once, not on every visit to Home.
    private static let launchItemID = ProcessInfo.processInfo.environment["GOOSETV_ITEM"]

    #if os(tvOS)
    /// The Apple TV's Home: the highlighted title across the top, and the rows
    /// in a band beneath it, moved a row at a time (see SpotlightHome).
    @ViewBuilder
    private var homeContent: some View {
        if shelves.fetched, shelves.spotlightRows.isEmpty {
            HomeEmpty { app.askForHomeSettings() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The top isn't left describing a card of a row that's gone.
                .onAppear { shelves.spotlight.clear() }
        } else {
            SpotlightHome(rows: shelves.spotlightRows, shelves: shelves,
                          scrollToTopRequest: scrollToTopRequest,
                          play: play, showDetails: showDetails, seeAll: seeAll)
        }
    }
    #else
    private var homeContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 1).id("home-top")
                    if !heroItems.isEmpty {
                        // Paged carousel: left/right on the remote slides between items.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 0) {
                                ForEach(heroItems) { item in
                                    HeroBanner(item: item, focusID: item.id, focus: $heroFocus,
                                               showDetails: { showDetails(item) }) {
                                        playingItem = item
                                    }
                                    .containerRelativeFrame(.horizontal)
                                    .id(item.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: $heroPosition)
                        .onChange(of: heroPosition) { _, shown in
                            if !heroTurning { heroKept = shown }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in realignHero() }
                        .overlay(alignment: .bottom) {
                            if heroItems.count > 1 {
                                HStack(spacing: 16) {
                                    HeroCycleDots(count: heroItems.count,
                                                  index: heroIndex,
                                                  interval: heroInterval,
                                                  // Nor while a page is pushed over Home: turning the
                                                  // banners there redrew a screen nobody could see.
                                                  held: heroPaused || heroFocus != nil || playingItem != nil
                                                      || !path.isEmpty) {
                                        let next = heroItems[(heroIndex + 1) % heroItems.count].id
                                        withAnimation(.easeInOut(duration: 0.8)) {
                                            heroPosition = next
                                        }
                                    }
                                    Button {
                                        heroPaused.toggle()
                                    } label: {
                                        Image(systemName: heroPaused ? "play.fill" : "pause.fill")
                                    }
                                    .buttonStyle(.circleIcon)
                                    .focused($pauseFocused)
                                    // It stops the banners turning, not a film playing.
                                    .accessibilityLabel(heroPaused ? String(localized: "Resume slideshow") : String(localized: "Pause slideshow"))
                                }
                                .padding(.bottom, 18)
                            }
                        }
                    }

                    // The rows, as arranged in Settings.
                    ForEach(rows, id: \.self) { row($0) }

                    if shelves.fetched, heroItems.isEmpty, rows.isEmpty {
                        HomeEmpty { app.askForHomeSettings() }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.bottom, 60)
            }
            .pageSides()
            .onChange(of: heroFocus) { _, _ in updateAwayFromTop() }
            .onChange(of: pauseFocused) { _, _ in updateAwayFromTop() }
            .onChange(of: heroItems.isEmpty) { _, _ in updateAwayFromTop() }
            .onChange(of: scrollToTopRequest) { _, _ in
                // Focus first, so the focus engine doesn't scroll back to the old card,
                // then settle the scroll at the very top once focus has moved.
                heroFocus = heroPosition ?? heroItems.first?.id
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation { proxy.scrollTo("home-top", anchor: .top) }
                }
            }
        }
    }
    #endif

    #if !os(tvOS)
    /// Puts the banners back on the one that was showing, after the screen
    /// has changed width: the device turned on its side, or back. Each
    /// banner is as wide as the screen, and the row of them kept its place
    /// by the point, not by the banner: after a turn it stood part-way
    /// between two, the end of one and the start of the next, the one that
    /// had been showing cut off at the side.
    private func realignHero() {
        guard let kept = heroKept, heroItems.contains(where: { $0.id == kept }) else { return }
        heroTurning = true
        Task { @MainActor in
            // Once the new width is laid out. Told the banner it already
            // has, the scroll does nothing, so it's told none and then
            // that one again.
            try? await Task.sleep(for: .milliseconds(60))
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { heroPosition = nil }
            try? await Task.sleep(for: .milliseconds(1))
            withTransaction(jump) { heroPosition = kept }
            try? await Task.sleep(for: .milliseconds(120))
            heroTurning = false
        }
    }

    /// The rows that have anything in them, in the order they're to stand,
    /// less the ones switched off.
    private var rows: [String] {
        var filled: Set<String> = []
        if !shelves.resume.isEmpty { filled.insert(HomeLayout.resume) }
        if !shelves.nextUp.isEmpty { filled.insert(HomeLayout.nextUp) }
        if !shelves.onNow.isEmpty { filled.insert(HomeLayout.onNow) }
        if !shelves.listening.isEmpty { filled.insert(HomeLayout.listening) }
        if !shelves.upcoming.isEmpty { filled.insert(HomeLayout.upcoming) }
        if !shelves.recentMusic.isEmpty { filled.insert(HomeLayout.musicRecent) }
        if !shelves.topSongs.isEmpty { filled.insert(HomeLayout.musicTop) }
        let latest = shelves.latest.map { HomeLayout.latest($0.library) }
        let pinned = shelves.pinned.map { HomeLayout.pinned($0.pin.id) }
        filled.formUnion(latest + pinned)
        let there = HomeLayout.usualOrder(latest: latest, pinned: pinned).filter(filled.contains)
        return HomeLayout.arranged(there, by: shelves.order).filter { !shelves.hidden.contains($0) }
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        switch id {
        case HomeLayout.resume:
            Shelf(title: String(localized: "Continue Watching"), eyebrow: String(localized: "In progress"), accent: Theme.palette[0],
                  seeAll: { path.append(HomeRoute.resume) }) {
                ForEach(shelves.resume) { item in
                    LandscapeCard(item: item, showDetails: { showDetails(item) }) { playingItem = item }
                }
            }
        case HomeLayout.nextUp:
            Shelf(title: String(localized: "Next Up"), eyebrow: String(localized: "Your shows"), accent: Theme.palette[2],
                  seeAll: { path.append(HomeRoute.nextUp) }) {
                ForEach(shelves.nextUp) { item in
                    LandscapeCard(item: item, showDetails: { showDetails(item) },
                                  removesFromNextUp: true) { playingItem = item }
                }
            }
        case HomeLayout.onNow:
            Shelf(title: String(localized: "On Now", comment: "Home row: what's on the television channels at this moment"),
                  eyebrow: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                  accent: Theme.palette[3 % Theme.palette.count],
                  seeAll: { seeAll(.liveTV) }) {
                ForEach(shelves.onNow) { channel in
                    LiveNowCard(item: channel) { play(channel) }
                }
            }
        case HomeLayout.listening:
            Shelf(title: HomeLayout.listeningTitle, eyebrow: HomeLayout.listeningEyebrow,
                  accent: Theme.palette[3 % Theme.palette.count],
                  seeAll: shelves.listeningLibrary.map { library in { path.append(HomeRoute.library(library)) } }) {
                ForEach(shelves.listening) { file in
                    ListeningCard(item: file, width: Theme.posterWidth) { play(file) }
                }
            }
        case HomeLayout.upcoming:
            Shelf(title: HomeLayout.upcomingTitle, eyebrow: String(localized: "Your shows"), accent: Theme.palette[2],
                  seeAll: { path.append(HomeRoute.upcoming) }) {
                ForEach(shelves.upcoming) { episode in
                    LandscapeCard(item: episode, showDetails: { showDetails(episode) }) { showDetails(episode) }
                }
            }
        case HomeLayout.musicRecent:
            Shelf(title: HomeLayout.musicRecentTitle, eyebrow: HomeLayout.musicEyebrow,
                  accent: Theme.palette[4 % Theme.palette.count],
                  seeAll: { path.append(HomeRoute.recentMusic) }) {
                ForEach(shelves.recentMusic) { AlbumCard(item: $0, width: Theme.posterWidth) }
            }
        case HomeLayout.musicTop:
            Shelf(title: HomeLayout.musicTopTitle, eyebrow: HomeLayout.musicEyebrow,
                  accent: Theme.palette[5 % Theme.palette.count],
                  seeAll: { path.append(HomeRoute.topSongs) }) {
                ForEach(shelves.topSongs) { song in
                    SongCard(item: song, width: Theme.posterWidth) { play(song) }
                }
            }
        default:
            if let index = shelves.pinned.firstIndex(where: { HomeLayout.pinned($0.pin.id) == id }) {
                let entry = shelves.pinned[index]
                Shelf(title: entry.pin.title, eyebrow: entry.library.displayTitle,
                      accent: Theme.palette[(index + 2) % Theme.palette.count],
                      seeAll: { path.append(HomeRoute.pinned(entry.pin.id)) }) {
                    ForEach(entry.items) { item in
                        if entry.pin.filters.episodes || entry.library.holdsVideos {
                            LandscapeCard(item: item, showDetails: { showDetails(item) }) { playingItem = item }
                        } else {
                            PosterNavCard(item: item, width: Theme.posterWidth)
                        }
                    }
                }
            } else if let index = shelves.latest.firstIndex(where: { HomeLayout.latest($0.library) == id }) {
                let entry = shelves.latest[index]
                Shelf(title: entry.library.displayTitle,
                      eyebrow: String(localized: "Recently added"),
                      accent: Theme.palette[(index + 1) % Theme.palette.count],
                      seeAll: { path.append(HomeRoute.library(entry.library)) }) {
                    ForEach(entry.items) { item in
                        if entry.library.holdsMusic {
                            AlbumCard(item: item, width: Theme.posterWidth)
                        } else if entry.library.holdsVideos {
                            LandscapeCard(item: item, showDetails: { showDetails(item) }) { playingItem = item }
                        } else {
                            PosterNavCard(item: item, width: Theme.posterWidth)
                        }
                    }
                }
                // The newest of the server's recordings can be deleted from here too.
                .environment(\.recordingsDeletable, app.recordingLibraries.contains(entry.library.id))
            }
        }
    }
    #endif

    /// Opens an item's page; an episode opens its show.
    private func showDetails(_ item: BaseItem) {
        path.append(HomeRoute.details(itemId: item.isEpisode ? (item.seriesId ?? item.id) : item.id))
    }

    #if !os(tvOS)
    /// "At the top" means focus is on the hero (Resume or pause). With no hero there's
    /// nothing to return to, so back goes straight to the menu.
    private func updateAwayFromTop() {
        shelves.scrolledDown = !heroItems.isEmpty && heroFocus == nil && !pauseFocused
    }
    #endif

    private func load(force: Bool = false) async {
        guard let client = app.client, (!shelves.loaded || force) else { return }
        shelves.loaded = true
        shelves.fetchedAtRevision = app.userDataRevision
        // Two reloads close together (a film marked watched, then its player
        // closing) could finish in either order, and the older one's shelves
        // would stay; a load that finds a later one has begun leaves it to that.
        shelves.loadGeneration += 1
        let generation = shelves.loadGeneration
        var superseded: Bool { shelves.loadGeneration != generation }
        async let resumeTask = try? client.resumeItems()
        async let nextUpTask = try? client.nextUp()
        async let librariesTask: () = app.loadLibraries()
        let newResume = await resumeTask ?? []
        let newNextUp = app.visibleNextUp(await nextUpTask ?? [])
        // First load: the hero and top shelves paint now rather than waiting
        // for every library's "recently added" fetch below.
        if !force, !superseded {
            shelves.resume = newResume
            shelves.nextUp = newNextUp
        }
        await librariesTask
        guard !superseded else { return }
        // The pinned rows: asked each time, since what they hold may be what's
        // unwatched or a favourite.
        await refreshPinned()

        // "Recently added" changes when files arrive, not when something is
        // watched; refetching five libraries' worth on every film closed was
        // most of this reload. Kept for ten minutes between those refreshes.
        guard !force || shelves.latestFetched.map({ Date().timeIntervalSince($0) > 600 }) ?? true else {
            app.holdMenuFocus()
            shelves.resume = newResume
            shelves.nextUp = newNextUp
            if !shelves.fetched { shelves.fetched = true }
            return
        }

        // One shelf per library Home has room for, fetched in parallel,
        // kept in library order.
        let shelfLibraries = HomeLayout.shelfLibraries(app.libraries)
        let recordingFolders = app.recordingFolders
        let newLatest = await withTaskGroup(of: (Int, [BaseItem]).self) { group in
            for (index, library) in shelfLibraries.enumerated() {
                group.addTask {
                    // Recordings each their own, not a show's under the show.
                    let items = recordingFolders.contains(library.id)
                        ? try? await client.recentRecordings(in: library.id, limit: 16)
                        : try? await client.latest(in: library)
                    return (index, items ?? [])
                }
            }
            var byIndex = [[BaseItem]](repeating: [], count: shelfLibraries.count)
            for await (index, items) in group { byIndex[index] = items }
            return zip(shelfLibraries, byIndex)
                .filter { !$0.1.isEmpty }
                .map { (library: $0.0, items: $0.1) }
        }
        guard !superseded else { return }

        // A reload can pull the focused card out from under the user (e.g. one
        // just removed from Continue Watching); keep focus from falling to the menu.
        if force {
            app.holdMenuFocus()
            shelves.resume = newResume
            shelves.nextUp = newNextUp
        }
        shelves.latest = newLatest
        shelves.latestFetched = Date()
        if !shelves.fetched { shelves.fetched = true }
        // Fetched before the recordings' library was known for one: listed
        // again, a recording at a time (nothing if it was).
        if recordingFolders != app.recordingFolders { await refreshRecordings(now: true) }
    }

    /// The pinned views put on Home, each its first sixteen titles, asked
    /// together; written only where something changed.
    private func refreshPinned() async {
        guard let client = app.client else { return }
        let libraries = app.libraries
        let wanted = app.homePins.compactMap { pin in libraries.first { $0.id == pin.libraryId }.map { (pin: pin, library: $0) } }
        let recordings = app.recordingFolders
        let found = await withTaskGroup(of: (Int, [BaseItem]).self) { group in
            for (index, entry) in wanted.enumerated() {
                group.addTask {
                    let listed = try? await client.listing(of: entry.library, filters: entry.pin.filters,
                                                            recordings: recordings.contains(entry.library.id), startIndex: 0, limit: 16)
                    return (index, listed?.items ?? [])
                }
            }
            var byIndex = [[BaseItem]](repeating: [], count: wanted.count)
            for await (index, items) in group { byIndex[index] = items }
            return byIndex
        }
        guard client === app.client else { return }
        let entries = zip(wanted, found).filter { !$0.1.isEmpty }.map { (pin: $0.0.pin, library: $0.0.library, items: $0.1) }
        let signature = { (rows: [(pin: PinnedFilter, library: BaseItem, items: [BaseItem])]) in
            rows.map { "\($0.pin.id)\($0.pin.title)" + $0.items.map(\.id).joined() }
        }
        guard signature(entries) != signature(shelves.pinned) else { return }
        app.holdMenuFocus()
        shelves.pinned = entries
    }

    /// Opens whatever was chosen on the Apple TV home screen: its page for a
    /// select, the film itself for a press of play. Cleared either way, so a
    /// later launch doesn't reopen it.
    private func openFromShelf() async {
        guard let opened = app.openedFromShelf else { return }
        app.openedFromShelf = nil
        var found: BaseItem?
        #if !os(tvOS)
        // A download's notice was chosen: the device has what its page needs,
        // and may be out of the server's reach.
        found = Downloads.shared.item(opened.itemId)
        #endif
        if found == nil { found = try? await app.client?.item(id: opened.itemId) }
        guard let item = found else { return }
        if opened.play, item.isMusic, let client = app.client {
            // Siri's "play" of an album or an artist: in the music player.
            MusicPlayer.shared.play(source: item.isSong ? item.album : item.displayTitle, client: client,
                                    songs: MusicMenu.songs(of: item, client: client))
        } else if opened.play, item.isSeries {
            // A show: its next episode, where there's one; else its page.
            if let client = app.client as? MediaBrowserClient, let next = await client.nextEpisode(seriesId: item.id) {
                playingItem = next
            } else {
                path.append(item)
            }
        } else if opened.play, !item.isUpcoming, !item.isContainer {
            playingItem = item
        } else {
            path.append(item)
        }
    }
}

// MARK: - Hero banner

#if !os(tvOS)
// iPhone and iPad; the Apple TV's Home is SpotlightHome.

struct HeroBanner: View {
    /// Tall enough to be the centrepiece, short enough that the shelf below it shows.
    static let heroHeight: CGFloat = Theme.isPhone ? 360 : 550

    @Environment(\.appState) private var app
    let item: BaseItem
    let focusID: String
    var focus: FocusState<String?>.Binding
    /// Opens its page (its show's, for an episode) from the long-press menu.
    var showDetails: (() -> Void)? = nil
    let onPlay: () -> Void
    @State private var press = PressTimer()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The banner is far wider than a 16:9 backdrop, so filling it would crop
            // away nearly half the picture. Show the backdrop whole on the right at its
            // own shape, faded into the background on the left, where the title sits.
            // A banner narrower than the picture, a phone's or an iPad's held upright,
            // has the middle of it instead: kept to the right there, the left of the
            // picture was lost off the banner's edge, whoever stood in it cut in half.
            Color.clear
                .frame(height: Self.heroHeight)
                .frame(maxWidth: .infinity)
                .overlay {
                    GeometryReader { box in
                        let wide = Self.heroHeight * 16 / 9
                        let whole = box.size.width >= wide
                        RemoteImage(url: app?.client?.imageURL(for: item, type: "Backdrop",
                                                               maxWidth: Theme.pixels(wide, scale: displayScale)),
                                    symbol: "")
                            .frame(width: wide, height: Self.heroHeight)
                            .clipped()
                            .mask(LinearGradient(stops: [.init(color: whole ? .clear : .black, location: 0),
                                                         .init(color: .black, location: 0.4)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: box.size.width, height: box.size.height, alignment: whole ? .trailing : .center)
                    }
                }
                .overlay(
                    LinearGradient(
                        colors: [Theme.background, Theme.background.opacity(0.4), .clear],
                        startPoint: .bottom, endPoint: .top
                    )
                )
            VStack(alignment: .leading, spacing: 16) {
                // Only once it's started: a Next Up episode not yet begun
                // isn't something to continue.
                if let label = item.episodeLabel, item.resumeTicks > 0 {
                    Text("CONTINUE · \(label.uppercased())")
                        .font(.app(14, .bold))
                        .kerning(1.2)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(Theme.primary.0.opacity(0.3), in: Capsule())
                        .overlay(Capsule().stroke(Theme.primary.0.opacity(0.65), lineWidth: 1))
                }
                if let logoURL = app?.client?.imageURL(for: item, type: "Logo", maxWidth: 600) {
                    // The title in the movie's own graphic treatment
                    HeroLogo(url: logoURL, fallback: heroTitle, tallest: Theme.isPhone ? 130 : 190)
                } else {
                    Text(heroTitle)
                        .font(.app(40, .bold))
                        .lineLimit(2)
                }
                // A film's tagline, as on its page; the phone's banner hasn't room.
                if !Theme.isPhone, !item.isEpisode,
                   let tagline = item.taglines?.first?.trimmingCharacters(in: .whitespaces), !tagline.isEmpty {
                    Text(tagline)
                        .font(.custom("Figtree-Italic", fixedSize: 22 * Theme.uiScale))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                        .lineLimit(1)
                }
                if let label = item.episodeLabel {
                    Text("\(label) · \(item.displayTitle)")
                        .font(.app(20))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    MetadataRow(item: item)
                }
                Button { press.release(onPlay) } label: {
                    Label(item.resumeTicks > 0 ? String(localized: "Resume") : String(localized: "Play"), systemImage: "play.fill")
                }
                .buttonStyle(GradientButtonStyle(timer: press))
                .focused(focus, equals: focusID)
                // Every banner's button says Play, and the carousel lines them up
                // side by side; spoken, they need to say which film.
                .accessibilityLabel(item.resumeTicks > 0 ? String(localized: "Resume \(item.spokenDescription)")
                                                    : String(localized: "Play \(item.spokenDescription)"))
            }
            .padding(50)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        // Held anywhere on the banner, as a card is: its page, and the rest
        // of a card's menu.
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 24))
        .itemContextMenu(item, showDetails: showDetails)
    }

    private var heroTitle: String {
        item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
    }
}

/// Page dots + cycle countdown, isolated so the 10Hz tick only redraws this view,
/// never the carousel behind it (re-rendering the ScrollView each tick caused flicker).
struct HeroCycleDots: View {
    let count: Int
    let index: Int
    let interval: Double
    /// True while something should hold the countdown (paused, hero focused, playing).
    let held: Bool
    let advance: () -> Void

    @State private var progress: Double = 0
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                if i == index {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 30, height: 8)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.gradient(Theme.primary))
                                .frame(width: max(5, 30 * min(progress, 1)))
                        }
                } else {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .animation(.linear(duration: 0.1), value: progress)
        .onReceive(tick) { _ in
            guard !held else { return }
            progress += 0.1 / interval
            if progress >= 1 {
                progress = 0
                advance()
            }
        }
        .onChange(of: index) { _, _ in
            progress = 0
        }
    }
}
#endif

/// Title-treatment logo with a plain-text fallback while loading or on failure.
/// Sized by shape rather than height alone: a squarish logo (Jurassic Park's)
/// at the wide ones' height is a quarter of its column, so it gets taller, up
/// to about the same area.
struct HeroLogo: View {
    let url: URL
    let fallback: String
    /// The tallest a logo gets.
    var tallest: CGFloat = 220

    @State private var logo: UIImage?
    @State private var failed = false

    init(url: URL, fallback: String, tallest: CGFloat = 220) {
        self.url = url
        self.fallback = fallback
        self.tallest = tallest
        // A logo already fetched paints straight away, with no empty frame
        // first: Home's top fades a title in with its logo in place.
        _logo = State(initialValue: ImagePipeline.cached(url))
    }

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 560, maxHeight: min(Self.height(for: logo), tallest), alignment: .bottomLeading)
            } else if failed {
                fallbackText
            } else {
                Color.clear.frame(width: 1, height: 130)
            }
        }
        .task(id: url) {
            logo = ImagePipeline.cached(url)
            if logo == nil { logo = await ImagePipeline.load(url) }
            failed = logo == nil
        }
    }

    /// The height that gives a logo of this shape about the area of a wide
    /// one at 130: between 130 and 220.
    private static func height(for logo: UIImage) -> CGFloat {
        let ratio = logo.size.width / max(logo.size.height, 1)
        guard ratio > 0 else { return 130 }
        return min(max((440 * 130 / ratio).squareRoot() * 1.15, 130), 220)
    }

    private var fallbackText: some View {
        Text(fallback)
            .font(.app(40, .bold))
            .lineLimit(2)
    }
}

/// Home with nothing on it: every row switched off (Settings, Home Screen),
/// or the ones left on with nothing in them. It says where its rows are
/// chosen and is the way there: something for focus to stand on, too, on a
/// television, where a page with nothing to take focus left the menu
/// waiting for one that never came.
struct HomeEmpty: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.grid.1x2")
                .font(.system(size: CGFloat(44).scaled))
                .foregroundStyle(Theme.textSecondary)
            Text("Nothing on Home just now. Its rows are chosen in Settings.",
                 comment: "Home, when every row is switched off or empty; a button to Settings, Home Screen, follows")
                .font(.app(21))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Home Screen", comment: "Settings page: which rows Home shows, and their order"), action: open)
                .buttonStyle(.pill(selected: false))
        }
        .padding(40)
    }
}

/// Home's rows by name, and the order they stand in: Continue Watching, Next
/// Up, what's on the channels now, and a row of what's new for each library
/// Home has room for; or as the viewer has arranged them (Settings, Home
/// Screen).
enum HomeLayout {
    static let resume = "resume"
    static let nextUp = "nextUp"
    static let onNow = "onNow"
    /// Music: the albums played last, and the songs played most.
    static let musicRecent = "musicRecent"
    static let musicTop = "musicTop"
    /// Episodes of the library's shows still to air.
    static let upcoming = "upcoming"
    /// Audiobooks part-way through.
    static let listening = "listening"
    static var listeningTitle: String { String(localized: "Continue Listening", comment: "Audiobooks part-way through") }
    static var listeningEyebrow: String { String(localized: "Audiobooks", comment: "Eyebrow above a library of books, and Home's row of them") }
    static var upcomingTitle: String { String(localized: "Coming Soon", comment: "Home row and page: episodes of the library's shows still to air") }
    static func latest(_ library: BaseItem) -> String { "latest-" + library.id }
    /// A pinned view's own row (a library's filters, saved: see `PinnedFilter`).
    static func pinned(_ id: UUID) -> String { "pin-" + id.uuidString }
    static func pinId(_ row: String) -> UUID? { row.hasPrefix("pin-") ? UUID(uuidString: String(row.dropFirst(4))) : nil }

    static var musicRecentTitle: String { String(localized: "Recently Played", comment: "Home row: the albums of the songs played last") }
    static var musicTopTitle: String { String(localized: "Most Played", comment: "Music: sort songs by how often they've been played") }
    static var musicEyebrow: String { String(localized: "Music", comment: "Eyebrow above a music library's name") }

    /// Home's rows as they stand until the viewer moves them: what's under
    /// way, what's on, what's new in each library, the views pinned to Home,
    /// then listening, what's coming and music. Home and Settings → Home
    /// Screen both go by it, or the page's first move swapped two rows the
    /// viewer never touched.
    static func usualOrder(latest: [String], pinned: [String]) -> [String] {
        [resume, nextUp, onNow] + latest + pinned + [listening, upcoming, musicRecent, musicTop]
    }

    /// The rows there are, in the order they're to stand: the viewer's, and
    /// after them, in their usual order, any that order doesn't mention.
    static func arranged(_ rows: [String], by order: [String]) -> [String] {
        let chosen = order.filter { rows.contains($0) }
        return chosen + rows.filter { !chosen.contains($0) }
    }

    /// The libraries Home gives a row to. Five of the libraries of video:
    /// those of films and of shows before the other kinds, so that a library
    /// of home videos listed among them doesn't take the place of one that
    /// had a row here; and every library of music besides, whose albums are
    /// a row of square covers. Kept in the libraries' own order.
    static func shelfLibraries(_ libraries: [BaseItem]) -> [BaseItem] {
        let ordered = Array(libraries.enumerated())
        // Books aren't a row: Continue Listening is theirs.
        let video = ordered.filter { !$0.element.holdsMusic && !$0.element.holdsBooks }
        let first = video.filter { ["movies", "tvshows"].contains($0.element.collectionType ?? "") }
        let rest = video.filter { !["movies", "tvshows"].contains($0.element.collectionType ?? "") }
        let music = ordered.filter { $0.element.holdsMusic }
        return (Array((first + rest).prefix(5)) + music).sorted { $0.offset < $1.offset }.map(\.element)
    }
}

/// Home's shelves, kept outside the view so switching sections doesn't throw
/// them away. An object, so the view that keeps them needn't redraw with them.
@MainActor
final class HomeShelves: ObservableObject {
    @Published var resume: [BaseItem] = [] { didSet { shelvesChanged() } }
    @Published var nextUp: [BaseItem] = [] { didSet { shelvesChanged() } }
    /// What's on the server's television channels now: the channels, each
    /// with its programme. Empty where there's no Live TV, or the row has
    /// been switched off in Settings.
    @Published var onNow: [BaseItem] = [] { didSet { shelvesChanged() } }
    @Published var latest: [(library: BaseItem, items: [BaseItem])] = [] { didSet { shelvesChanged() } }
    /// The pinned views put on Home, each with its first titles.
    @Published var pinned: [(pin: PinnedFilter, library: BaseItem, items: [BaseItem])] = [] { didSet { shelvesChanged() } }
    /// Music: the albums played last, and the songs played most. Empty where
    /// the server has no music.
    @Published var recentMusic: [BaseItem] = [] { didSet { shelvesChanged() } }
    @Published var topSongs: [BaseItem] = [] { didSet { shelvesChanged() } }
    /// Episodes still to air, soonest first.
    @Published var upcoming: [BaseItem] = [] { didSet { shelvesChanged() } }
    /// Audiobooks part-way through, latest first.
    @Published var listening: [BaseItem] = [] { didSet { shelvesChanged() } }
    /// The library Continue Listening's See all opens: the first of books.
    var listeningLibrary: BaseItem?
    /// The viewer's arrangement of the rows (see `HomeLayout`), handed over
    /// by Home from the app's settings.
    @Published var order: [String] = [] { didSet { shelvesChanged() } }
    @Published var hidden: Set<String> = [] { didSet { shelvesChanged() } }
    /// Whether the shelves have been fetched once through: only then is a
    /// Home with no rows one with nothing to show (see `HomeEmpty`).
    @Published var fetched = false
    var loaded = false
    /// When "Recently added" was last fetched.
    var latestFetched: Date?
    /// The app's user-data revision the shelves were fetched at.
    var fetchedAtRevision = -1
    /// The latest load's number (see `HomeView.load`).
    var loadGeneration = 0
    /// Whether focus is on Home but below its top (the band's first row; on
    /// iPhone and iPad, the banner), so back should return there first. Read
    /// by back when it's pressed, and not published: kept as the menu's own
    /// state, moving between the top row and the next redrew the menu and
    /// the whole of Home.
    var scrolledDown = false
    #if os(tvOS)
    /// The Apple TV's band: the row it was on and the card last focused in
    /// each, so coming back to Home returns there. Not published: only the
    /// band reads them, as focus moves.
    var spotlightRow: String?
    var spotlightFocus: [String: String] = [:]
    /// What the top of the Apple TV's Home describes.
    let spotlight = SpotlightModel()

    /// The band's rows, made once for each change to the shelves rather than
    /// on every redraw of Home.
    var spotlightRows: [SpotlightRowData] {
        if let builtRows { return builtRows }
        let rows = makeSpotlightRows()
        builtRows = rows
        return rows
    }
    private var builtRows: [SpotlightRowData]?

    private func shelvesChanged() { builtRows = nil }

    private func makeSpotlightRows() -> [SpotlightRowData] {
        var rows: [SpotlightRowData] = []
        if !resume.isEmpty {
            rows.append(SpotlightRowData(id: "resume", title: String(localized: "Continue Watching"),
                                         eyebrow: String(localized: "In progress"), accentIndex: 0,
                                         kind: .landscape(removesFromNextUp: false), items: resume,
                                         seeAll: .resume))
        }
        if !nextUp.isEmpty {
            rows.append(SpotlightRowData(id: "nextUp", title: String(localized: "Next Up"),
                                         eyebrow: String(localized: "Your shows"), accentIndex: 2,
                                         kind: .landscape(removesFromNextUp: true), items: nextUp,
                                         seeAll: .nextUp))
        }
        if !onNow.isEmpty {
            rows.append(SpotlightRowData(id: "onNow", title: String(localized: "On Now", comment: "Home row: what's on the television channels at this moment"),
                                         eyebrow: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                                         accentIndex: 3, kind: .live, items: onNow, seeAll: .liveTV))
        }
        for (index, entry) in latest.enumerated() {
            let kind: SpotlightRowData.Kind = entry.library.holdsMusic ? .squares
                : entry.library.holdsVideos ? .landscape(removesFromNextUp: false) : .posters
            rows.append(SpotlightRowData(id: "latest-" + entry.library.id, title: entry.library.displayTitle,
                                         eyebrow: String(localized: "Recently added"), accentIndex: index + 1,
                                         kind: kind, items: entry.items, seeAll: .library(entry.library)))
        }
        for (index, entry) in pinned.enumerated() {
            // A show's episodes, or a library of home videos, as stills; the rest as posters.
            let kind: SpotlightRowData.Kind = entry.pin.filters.episodes || entry.library.holdsVideos
                ? .landscape(removesFromNextUp: false) : .posters
            rows.append(SpotlightRowData(id: HomeLayout.pinned(entry.pin.id), title: entry.pin.title,
                                         eyebrow: entry.library.displayTitle, accentIndex: index + 2,
                                         kind: kind, items: entry.items, seeAll: .pinned(entry.pin.id)))
        }
        if !listening.isEmpty {
            rows.append(SpotlightRowData(id: HomeLayout.listening, title: HomeLayout.listeningTitle,
                                         eyebrow: HomeLayout.listeningEyebrow, accentIndex: 3,
                                         kind: .squares, items: listening, seeAll: .library(listeningLibrary ?? listening[0])))
        }
        if !upcoming.isEmpty {
            rows.append(SpotlightRowData(id: HomeLayout.upcoming, title: HomeLayout.upcomingTitle,
                                         eyebrow: String(localized: "Your shows"), accentIndex: 2,
                                         kind: .landscape(removesFromNextUp: false), items: upcoming, seeAll: .upcoming))
        }
        if !recentMusic.isEmpty {
            rows.append(SpotlightRowData(id: HomeLayout.musicRecent, title: HomeLayout.musicRecentTitle,
                                         eyebrow: HomeLayout.musicEyebrow, accentIndex: 4,
                                         kind: .squares, items: recentMusic, seeAll: .recentMusic))
        }
        if !topSongs.isEmpty {
            rows.append(SpotlightRowData(id: HomeLayout.musicTop, title: HomeLayout.musicTopTitle,
                                         eyebrow: HomeLayout.musicEyebrow, accentIndex: 5,
                                         kind: .squares, items: topSongs, seeAll: .topSongs))
        }
        // As the viewer has them: in their order, less the ones switched off.
        return HomeLayout.arranged(rows.map(\.id), by: order).compactMap { id in
            hidden.contains(id) ? nil : rows.first { $0.id == id }
        }
    }
    #else
    /// The banner's rotation pool: everything in progress, up next, plus a
    /// taste of what's new. Worked out when a shelf changes, not each of the
    /// several times a body evaluation asks for it.
    private(set) var hero: [BaseItem] = []

    private func shelvesChanged() {
        var seen = Set<String>()
        var items: [BaseItem] = []
        // From the rows Home shows: one switched off (Settings, Home Screen)
        // went on putting its titles in the banner.
        let candidates = (hidden.contains(HomeLayout.resume) ? [] : resume)
            + (hidden.contains(HomeLayout.nextUp) ? [] : nextUp)
            // An album has no backdrop to make a banner of.
            + latest.filter { !hidden.contains(HomeLayout.latest($0.library)) && !$0.library.holdsMusic }.flatMap { $0.items.prefix(2) }
        for item in candidates where seen.insert(item.id).inserted {
            items.append(item)
            if items.count >= 6 { break }
        }
        hero = items
    }
    #endif
}

/// Destinations reached from a Home shelf's "See all" link.
enum HomeRoute: Hashable {
    case resume, nextUp, library(BaseItem), details(itemId: String)
    /// Music: the albums played last, the songs played most.
    case recentMusic, topSongs
    /// Episodes still to air.
    case upcoming
    /// A pinned view: its library with its filters.
    case pinned(UUID)
    /// Not a page pushed over Home: the Live TV section itself, which the
    /// row of what's on now leads to.
    case liveTV
}

/// Full grid for a Home shelf (Continue Watching, Next Up). Selecting an item plays it.
struct ItemListGridView: View {
    @EnvironmentObject var app: AppState
    let title: String
    let eyebrow: String
    let accent: (Color, Color)
    var showDetails: ((BaseItem) -> Void)? = nil
    /// A click opens the item's page (by `showDetails`) rather than playing it.
    var opensDetails = false
    var removesFromNextUp = false
    let loader: (any MediaServer) async throws -> [BaseItem]

    @State private var items: [BaseItem] = []
    @State private var loaded = false
    @State private var playingItem: BaseItem?

    private let columns = [GridItem(.adaptive(minimum: Theme.landscapeWidth), spacing: 32)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShelfHeader(title: title, eyebrow: eyebrow, accent: accent)
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .focusable()
                } else if items.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 40)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                    ForEach(items) { item in
                        let opens = opensDetails ? showDetails : nil
                        LandscapeCard(item: item, showDetails: showDetails.map { open in { open(item) } },
                                      removesFromNextUp: removesFromNextUp, opensPage: opens != nil) {
                            if let opens { opens(item) } else { playingItem = item }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
        }
        .pageSides()
        .task { await load() }
        .playerCover(item: $playingItem) { item in
            PlayerView(item: item)
        }
        .onChange(of: app.userDataRevision) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        let newItems = (try? await loader(client)) ?? []
        // The last thing listed has just gone (the last favourite unmarked,
        // the last film on the watchlist watched), and focus with it.
        let emptied = loaded && !items.isEmpty && newItems.isEmpty
        if loaded, !emptied { app.holdMenuFocus() }
        items = newItems
        loaded = true
        #if os(tvOS)
        // Nothing left here to hold focus, and nothing on the screen had it:
        // to the menu, on this section's row, to go somewhere else from.
        if emptied { app.askForMenu() }
        #endif
    }
}
