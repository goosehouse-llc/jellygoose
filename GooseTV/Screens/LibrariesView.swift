import SwiftUI

struct LibrariesView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if app.libraries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LibraryPickerGrid(libraries: app.libraries)
                }
            }
            .sectionDestinations()
        }
        .sectionNavigation(path: $path, section: "libraries")
        .task { await app.loadLibraries() }
    }
}

struct LibraryPickerGrid: View {
    @Environment(\.appState) private var app
    var title: String = String(localized: "Libraries")
    let libraries: [BaseItem]

    @State private var counts: [String: Int] = [:]
    @State private var posters: [String: [BaseItem]] = [:]

    /// One tile to a row on a phone upright, two across an iPad or a phone
    /// on its side.
    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 640), spacing: 28)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(title)
                    .font(.app(26, .bold))
                    .padding(.leading, 4)
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                        NavigationLink(value: library) {
                            LibraryCard(library: library,
                                        count: counts[library.id],
                                        posterItems: posters[library.id] ?? [],
                                        accent: LibraryCard.accents[index % LibraryCard.accents.count])
                        }
                        .buttonStyle(.tvCard)
                        // A playlist's or a collection's: deleted from here, among the rest.
                        .containerMenu(library)
                        .accessibilityLabel(library.displayTitle)
                        .accessibilityValue(counts[library.id].map { String(localized: "\($0) items") } ?? "")
                        .accessibilityHint("Opens this library")
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
        }
        .pageSides()
        .task { await loadCounts() }
    }

    private func loadCounts() async {
        guard let client = app?.client, counts.isEmpty else { return }
        var recordingFolders = app?.recordingFolders ?? []
        // Not known yet so soon after launch (the Live TV check comes later):
        // asked here, or the recordings were counted as films and shows.
        if recordingFolders.isEmpty, libraries.contains(where: { $0.collectionType == nil && !$0.isContainer }) {
            recordingFolders = await client.liveRecordingFolders()
        }
        await withTaskGroup(of: (String, Int?, [BaseItem]).self) { group in
            for library in libraries {
                group.addTask {
                    async let latestResult = try? client.latest(in: library, limit: 3)
                    let total: Int?
                    if library.holdsBooks {
                        // Books as the library counts them: one in parts is
                        // one book, not its author's folder or each file.
                        total = (try? await client.audiobookFiles(in: library.id))
                            .map { Audiobooks.books(from: $0, folders: [:]).count }
                    } else if library.isContainer {
                        // A collection or a playlist says what it holds itself:
                        // counted as a library is, by its films and shows, a
                        // playlist of episodes came to none.
                        total = nil
                    } else {
                        // Recordings by what the server records into it, as
                        // the library itself lists them.
                        let types = recordingFolders.contains(library.id) ? BaseItem.recordingTypes : library.listedTypes
                        total = try? await client.libraryItems(parentId: library.id, limit: 1, itemTypes: types).totalRecordCount
                    }
                    return (library.id, total ?? library.childCount, await latestResult ?? [])
                }
            }
            for await (id, total, latest) in group {
                if let total { counts[id] = total }
                posters[id] = latest
            }
        }
    }
}

struct LibraryCard: View {
    @Environment(\.appState) private var app
    let library: BaseItem
    let count: Int?
    /// Its newest titles: the first with a picture gives the tile its own.
    let posterItems: [BaseItem]
    let accent: (Color, Color)

    // One palette everywhere — the library cards set the theme, the rest of the app follows.
    // Computed for the same reason as MenuRowStyle's tint: a stored static
    // freezes the scheme that happened to be in force at first use.
    static var accents: [(Color, Color)] { Theme.palette }

    /// A wide tile of artwork: a backdrop from one of the library's newest
    /// titles, dimmed under the library's name and how much is in it. The
    /// server's own picture for the library only when it has no titles with
    /// one: Jellyfin makes those itself, with the library's name written
    /// across them. Until a picture arrives, or for a library with none, the
    /// theme's gradient and an icon.
    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                LinearGradient(colors: [accent.0, accent.1],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: iconName)
                    .font(.app(110, .bold))
                    .foregroundStyle(.white.opacity(0.16))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 25, y: -18)
            }
            .overlay {
                if let picture {
                    RemoteImage(url: picture)
                        .overlay(Color.black.opacity(0.22))
                }
            }
            .overlay(
                // The words sit in the dark along the bottom, whatever the picture.
                LinearGradient(stops: [.init(color: .black.opacity(0.78), location: 0),
                                       .init(color: .black.opacity(0.25), location: 0.45),
                                       .init(color: .clear, location: 0.8)],
                               startPoint: .bottom, endPoint: .top)
            )
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.displayTitle)
                        .font(.app(24, .bold))
                        .lineLimit(1)
                    if let count {
                        Text(library.countText(count))
                            .font(.app(15, .medium))
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .padding(20)
            }
            .clipped()
    }

    private var picture: URL? {
        guard let client = app?.client else { return nil }
        if let backdrop = posterItems.lazy.compactMap({ client.imageURL(for: $0, type: "Backdrop", maxWidth: 1200) }).first {
            return backdrop
        }
        // A collection's own backdrop, when it has one.
        if let own = client.imageURL(for: library, type: "Backdrop", maxWidth: 1200) { return own }
        guard library.imageTags?["Primary"] != nil else { return nil }
        return client.imageURL(for: library, type: "Primary", maxWidth: 1200)
    }

    private var iconName: String { library.librarySymbol + ".fill" }
}

#if os(tvOS)
/// Out of focus's reach while the menu hands focus to the page (one of its
/// rows was chosen), so that focus goes to the titles and not to whatever
/// stands first on the page.
private struct AsideFromHandover<Content: View>: View {
    @ObservedObject var hold: MenuFocusHold
    @ViewBuilder var content: Content

    var body: some View {
        content.disabled(hold.leaving)
    }
}
#endif

/// What a library grid shows.
struct LibraryGridState {
    var items: [BaseItem] = []
    var total = 0
    var loaded = false
    var filters = LibraryFilters()
    var genres: [String] = []
    /// The decades the library's titles came out in, newest first, by their
    /// first year. Worked out once, when the years arrive.
    var decades: [Int] = []
    /// Whether the genres and decades have been fetched: a library with none
    /// isn't asked again on every visit.
    var choicesLoaded = false
    /// Shows being chosen for the filters, in the grid itself (see
    /// `ShowChoice`); nil the rest of the time. Kept here rather than by the
    /// page, so that leaving the section halfway through doesn't lose the
    /// filters it was started from.
    var showChoice: ShowChoice?
}

/// A TV library's shows being chosen, a press on each poster: every show is
/// listed A to Z meanwhile, and the filters it was started from come back
/// when it's done, with the shows ticked (or as they were, if cancelled).
struct ShowChoice {
    let returning: LibraryFilters
    /// The ticked shows' names, by id.
    var shows: [String: String]
}

/// A grid's data in an object of its own. The grid watches it; whatever keeps
/// it (MainTabView, for a section root) doesn't. Kept as MainTabView's own
/// state, every page of posters that loaded redrew the menu and everything
/// else on screen along with the grid.
@MainActor
final class LibraryGridModel: ObservableObject {
    @Published var state: LibraryGridState {
        didSet {
            if oldValue.items.count != state.items.count
                || !oldValue.items.elementsEqual(state.items, by: { $0.id == $1.id }) {
                positions = Dictionary(state.items.enumerated().map { ($1.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            }
        }
    }
    /// Where each title is in the list, for the alphabet's lookups on every
    /// focus move; a search through two thousand titles each time otherwise.
    private(set) var positions: [String: Int] = [:] {
        didSet { dayPlans = [:] }
    }
    /// Recordings in the order they were made, laid out by the day: worked
    /// out once for a list and a width, and asked for on every move.
    private var dayPlans: [Int: DayPlan] = [:]

    /// The list in rows of so many, each day's recordings beginning a row
    /// of their own under the day's name.
    func dayPlan(perRow: Int) -> DayPlan {
        let today = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 / 86_400)
        if let plan = dayPlans[perRow], plan.madeOn == today { return plan }
        let plan = DayPlan(state.items, perRow: max(perRow, 1), madeOn: today)
        dayPlans[perRow] = plan
        return plan
    }
    /// The app's user-data revision the titles were last fetched at, so
    /// coming back to the grid refreshes only when something has changed.
    var fetchedAtRevision = -1
    /// When they were: a library of recordings is asked again on coming
    /// back to it, but not straight after it last was.
    var fetchedAt = Date.distantPast
    /// The filters the titles on show were fetched with; nil before any were.
    /// A fetch cut short (the section left while it ran) or failed leaves the
    /// titles and the filters apart, and the next refresh starts afresh.
    var itemsFilters: LibraryFilters?
    #if os(tvOS)
    /// The Apple TV's grid: the row the band is on and the title last in
    /// focus, kept for coming back to the grid. Not published: only the grid
    /// reads them, as focus moves.
    var bandRow = 0
    var focusedTitle: String?
    /// Takes the grid on screen back to its first title, for Back; set by
    /// the grid while it's showing.
    var returnToTop: (() -> Void)?
    /// The page's width, as last measured: the same for every library, so a
    /// grid coming back, or a new one, lays out its rows right the first time
    /// rather than one title to a row until it's measured.
    static var bandWidth: CGFloat = 0
    #endif

    /// A library's own grid in the menu: its sort and filters are kept for
    /// next time. A pin's, or a shelf's See all, starts as it always does.
    let remembersFilters: Bool

    init(filters: LibraryFilters = LibraryFilters(), remembersFilters: Bool = false) {
        state = LibraryGridState(filters: filters)
        self.remembersFilters = remembersFilters
    }
}

/// A pinned view opened from its row on Home: its library, with its filters.
struct PinnedGridView: View {
    @EnvironmentObject var app: AppState
    let pinId: UUID

    var body: some View {
        if let pin = app.pins.first(where: { $0.id == pinId }),
           let library = app.libraries.first(where: { $0.id == pin.libraryId }) {
            PinnedGrid(library: library, filters: pin.filters)
        }
    }
}

private struct PinnedGrid: View {
    let library: BaseItem
    @StateObject private var model: LibraryGridModel

    init(library: BaseItem, filters: LibraryFilters) {
        self.library = library
        _model = StateObject(wrappedValue: LibraryGridModel(filters: filters))
    }

    var body: some View { LibraryGrid(library: library, model: model) }
}

/// A list of recordings, newest first, cut into rows by the day: a day's
/// begin a new row, which carries the day's name.
struct DayPlan {
    struct Day: Identifiable {
        let id: Int
        let title: String
        let items: [BaseItem]
    }

    /// The days, for a grid that lays itself out (by touch).
    let days: [Day]
    /// Where each row begins in the list, the heading over it where it's a
    /// day's first, and the row each title is in.
    private(set) var starts: [Int] = []
    private(set) var headings: [String?] = []
    private(set) var rowOf: [Int] = []
    let madeOn: Int

    init(_ items: [BaseItem], perRow: Int, madeOn: Int) {
        self.madeOn = madeOn
        let now = Date()
        var days: [Day] = []
        var last: Int?
        var gathered: [BaseItem] = []
        var title = ""
        var inRow = 0
        var starts: [Int] = []
        var headings: [String?] = []
        var rowOf: [Int] = []
        rowOf.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let day = Recorded.day(of: item.recordedAt, now: now)
            if day.key != last {
                if let last { days.append(Day(id: last, title: title, items: gathered)) }
                last = day.key
                title = day.title
                gathered = []
                starts.append(index)
                headings.append(day.title)
                inRow = 0
            } else if inRow == perRow {
                starts.append(index)
                headings.append(nil)
                inRow = 0
            }
            gathered.append(item)
            inRow += 1
            rowOf.append(starts.count - 1)
        }
        if let last { days.append(Day(id: last, title: title, items: gathered)) }
        self.days = days
        self.starts = starts
        self.headings = headings
        self.rowOf = rowOf
    }

    func range(ofRow row: Int, count: Int) -> Range<Int> {
        guard starts.indices.contains(row) else { return 0..<0 }
        return starts[row]..<(row + 1 < starts.count ? starts[row + 1] : count)
    }
}

/// The section roots' grids, by library or pin id, made on first visit and
/// kept so returning to a section repaints its grid at once.
@MainActor
final class LibraryGridModels {
    private var models: [String: LibraryGridModel] = [:]

    func model(_ key: String, filters: @autoclosure () -> LibraryFilters = LibraryFilters(),
               remembersFilters: Bool = false) -> LibraryGridModel {
        if let model = models[key] { return model }
        let model = LibraryGridModel(filters: filters(), remembersFilters: remembersFilters)
        models[key] = model
        return model
    }

    /// The grid already made for this key, if one has been. Asking mustn't
    /// make it: whoever makes it gives it its filters, and a grid made bare
    /// (by Back's handler, read before a library's page existed) stayed bare.
    func existing(_ key: String) -> LibraryGridModel? { models[key] }

    func forget(_ key: String) { models[key] = nil }
}

/// A grid with a model of its own, for grids pushed inside a section (a Home
/// shelf's "See all", a collection). Section roots use LibraryGrid directly.
struct LibraryGridView: View {
    @Environment(\.appState) private var app
    let opened: BaseItem
    @StateObject private var model = LibraryGridModel()
    /// A playlist whose server didn't say what it holds, once told by
    /// what's in it.
    @State private var told: BaseItem?

    init(library: BaseItem) { opened = library }

    private var library: BaseItem { told ?? opened }

    var body: some View {
        // Music opens as music: a library by its albums, artists and songs, an
        // album or a playlist of songs as a list of them, an artist as theirs.
        if opened.type == "Playlist", opened.knownMediaType == nil, told == nil {
            // Opened as films, a playlist of songs showed nothing.
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .task {
                    told = await app?.client?.withPlaylistTypes([opened]).first ?? opened
                }
        } else if library.holdsMusic {
            MusicLibraryView(library: library)
        } else if library.holdsBooks {
            AudiobookLibraryView(library: library)
        } else if library.isAlbum || library.isSongPlaylist {
            AlbumView(albumId: library.id, name: library.name, initial: library)
        } else if library.isArtist {
            ArtistView(artistId: library.id, name: library.name, initial: library)
        } else {
            LibraryGrid(library: library, model: model)
        }
    }
}

struct LibraryGrid: View {
    @EnvironmentObject var app: AppState
    @Environment(\.sectionNavigator) private var navigator
    let library: BaseItem
    @ObservedObject var model: LibraryGridModel

    private var state: LibraryGridState {
        get { model.state }
        nonmutating set { model.state = newValue }
    }

    @State private var loading = false
    @Environment(\.isNarrow) private var narrow
    @Environment(\.barEdge) private var barEdge
    /// The alphabet's lit letter and letter-at-a-time mode. Held, not
    /// watched: only the alphabet redraws when they change, not the grid.
    @State private var alphabet = AlphabetState()
    @State private var scroll = ScrollWatch()
    @FocusState private var focusedItem: String?
    @FocusState private var focusedLetter: String?
    @State private var playingItem: BaseItem?
    /// What plays after `playingItem`, for a collection's Play All and Shuffle.
    @State private var playingQueue: [BaseItem] = []
    /// Choosing among the server's recordings, to delete several at once:
    /// whether that's going on, the ones chosen, and the asking before
    /// they're deleted.
    @State private var selecting = false
    @State private var chosen: Set<String> = []
    @State private var confirmingDelete = false
    @State private var deleteFailed = false
    /// For a library of recordings: the series the server is set to record,
    /// so that a show here can be shown how its own is; the one whose
    /// options are open; and a show whose recordings are all to go.
    @StateObject private var recordings = LiveTVModel()
    @State private var seriesOpen: LiveSeriesTimer?
    @State private var deletingShow: BaseItem?

    /// Whether this is a library the server records into, from which this
    /// account may delete.
    private var deletable: Bool { app.recordingLibraries.contains(library.id) }

    /// Cards being chosen in the grid, a press on each: recordings to
    /// delete, or shows for the filters.
    private var picking: Bool { selecting || state.showChoice != nil }
    /// One that can be chosen: a show among shows, a recording among recordings.
    private func pickable(_ item: BaseItem) -> Bool {
        state.showChoice != nil ? item.isSeries : item.isOneVideo
    }
    /// The ones chosen so far.
    private var pickedIDs: Set<String> { state.showChoice.map { Set($0.shows.keys) } ?? chosen }
    /// A playlist or a collection this account may change (its own playlist,
    /// or collections it may manage): what's in it can be taken out.
    @State private var containerEditable = false
    @State private var containerChangeFailed = false

    /// Whether this is a library the server records into at all: each
    /// recording says when it was made.
    private var holdsRecordings: Bool { app.recordingFolders.contains(library.id) }
    /// What's listed: a recording at a time in a library of them.
    private var listedTypes: String { holdsRecordings ? BaseItem.recordingTypes : library.listedTypes }

    /// Recordings in the order they were made are filed by the day.
    var byDay: Bool { Self.byDay(state.filters, in: holdsRecordings) }

    static func byDay(_ filters: LibraryFilters, in recordings: Bool) -> Bool {
        recordings && filters.sort == .added && !filters.episodes
    }

    /// The line under a title, where there's one: when a recording was made.
    func note(for item: BaseItem) -> String? {
        holdsRecordings ? Recorded.note(for: item, headed: byDay) ?? " " : nil
    }

    private let pageSize = 100
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: narrow ? 12 : 24)] }
    private let episodeColumns = [GridItem(.adaptive(minimum: Theme.landscapeWidth), spacing: 32)]
    /// Wide stills that play when chosen, rather than posters that open a
    /// page: episodes, and a library of home videos or music videos.
    private var wide: Bool { state.filters.episodes || library.holdsVideos }

    #if os(tvOS)
    /// The Apple TV's grid moves the way Home's rows do (see SpotlightHome):
    /// the row in the band, the rows held out of focus (two or more from this
    /// one, caught up a moment after each move), a row focus is being sent to,
    /// the band's scroll, the glide, and whether focus is in the band.
    @State private var bandRow: Int
    @State private var lockRow: Int
    @State private var pendingRow: Int?
    @State private var glideOffset: CGFloat = 0
    /// The tallest row measured at the cards' present size, and that size
    /// (see rowPitch).
    @State private var measuredRowHeight: CGFloat = 0
    @State private var measuredAt = RowLayout(cardWidth: 0, episodes: false)
    /// The band's whole width, measured; the letters' room is taken off as
    /// it's used, since they come and go with the sort and filters.
    @State private var bandWidth: CGFloat
    @State private var bandFocused = false
    /// Whether the filters and the letters can take focus yet: not until the
    /// titles have had it. Focus that comes to the page with no direction to
    /// it (a row chosen in the menu, the first titles arriving) then has only
    /// the titles to go to, the one last in focus or the first, where
    /// otherwise it settled on the first of the filters.
    @State private var titlesHadFocus = false
    #endif

    init(library: BaseItem, model: LibraryGridModel) {
        self.library = library
        _model = ObservedObject(wrappedValue: model)
        #if os(tvOS)
        _bandRow = State(initialValue: model.bandRow)
        _lockRow = State(initialValue: model.bandRow)
        _bandWidth = State(initialValue: LibraryGridModel.bandWidth)
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            gridContent(proxy)
                #if os(tvOS)
                // Back, from below the top: to the first title (see MainTabView).
                .onAppear {
                    model.returnToTop = {
                        Task { await go(to: 0, proxy: proxy, focusing: true, keepIndex: true) }
                    }
                }
                #endif
                // Focus is heard by views of their own: read here, every step
                // along a row ran this whole body again, the filters' menus
                // and the letters included.
                .background {
                    FocusWatcher(focus: $focusedItem) { _, id in itemFocusMoved(to: id, proxy: proxy) }
                    FocusWatcher(focus: $focusedLetter) { old, letter in
                        letterFocusMoved(from: old, to: letter, proxy: proxy)
                    }
                }
        }
        .playerCover(item: $playingItem) { item in
            PlayerView(item: item, queue: playingQueue)
        }
        .onChange(of: playingItem) { _, newValue in
            if newValue == nil { playingQueue = [] }
        }
        // Watched marks and progress change while a player is up, or from a
        // long-press menu.
        .onChange(of: app.userDataRevision) { _, _ in
            Task { await reload() }
        }
        // The server's recordings, where this account may delete them: a
        // long press on one offers to. And one deleted goes from the grid
        // at once, not when the server has next been asked.
        .environment(\.recordingsDeletable, app.recordingLibraries.contains(library.id))
        .onChange(of: app.lastDeleted) { _, ids in
            let gone = Set(ids)
            let before = state.items.count
            guard state.items.contains(where: { gone.contains($0.id) }) else { return }
            state.items.removeAll { gone.contains($0.id) }
            state.total = max(state.total - (before - state.items.count), 0)
        }
        // Asked once for all of them: it's their files that go.
        .confirmationDialog(chosen.count == 1 ? String(localized: "Delete Recording", comment: "Deletes a recording from the server: its file is removed")
                                              : String(localized: "Delete \(chosen.count) Recordings", comment: "Deletes the chosen recordings from the server; the placeholder is how many"),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(chosen.count == 1 ? String(localized: "Delete Recording", comment: "Deletes a recording from the server: its file is removed")
                                     : String(localized: "Delete \(chosen.count) Recordings", comment: "Deletes the chosen recordings from the server; the placeholder is how many"),
                   role: .destructive) { deleteChosen() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if chosen.count == 1 {
                Text("The recording is deleted from your server and can't be brought back.", comment: "Asked before a recording is deleted")
            } else {
                Text("These recordings are deleted from your server and can't be brought back.", comment: "Asked before several recordings are deleted")
            }
        }
        .alert(String(localized: "Some of the recordings couldn't be deleted.", comment: "The server refused or didn't answer for one or more of the recordings being deleted"),
               isPresented: $deleteFailed) {}
        // A show among the recordings, from its long press: how its series
        // is recorded, or all of its recordings deleted.
        .seriesPanel($seriesOpen, model: recordings)
        .confirmationDialog(deletingShow?.displayTitle ?? "", isPresented: $deletingShow.isPresent(), titleVisibility: .visible,
                            presenting: deletingShow) { show in
            Button(String(localized: "Delete All Recordings", comment: "Deletes every recording of a show from the server"),
                   role: .destructive) { deleteShow(show) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Every recording of this show is deleted from your server and can't be brought back.",
                 comment: "Asked before all of a show's recordings are deleted")
        }
        .task(id: library.id) {
            guard library.isContainer, let client = app.client else { return }
            // A collection by what the app already knows of the account.
            containerEditable = library.type == "Playlist" ? await client.canEditPlaylist(library.id)
                                                           : app.managesCollections
        }
        .alert(library.type == "Playlist" ? String(localized: "Couldn't change the playlist.", comment: "The server refused a change to a playlist of songs, or didn't answer")
                                          : String(localized: "Couldn't change the collection.", comment: "The server refused a change to a collection, or didn't answer"),
               isPresented: $containerChangeFailed) {}
        .task(id: deletable) {
            // The series the server records, to match the shows here against.
            guard deletable, let client = app.client else { return }
            recordings.keepsGuide = false
            recordings.use(client)
            await recordings.loadTimers()
        }
        .onChange(of: state.items.count, initial: true) { _, _ in
            // Its shows' pages are then pages of recordings (see ItemDetailView).
            if deletable {
                app.recordedShows.formUnion(state.items.filter(\.isSeries).map(\.id))
                app.recordedShows.formUnion(state.items.compactMap(\.seriesId))
            }
        }
        .onChange(of: deletable) { _, may in
            if !may, selecting { stopSelecting() }
        }
        // A recording with no poster of its own wears the guide's picture.
        .environment(\.borrowsGuideArt, holdsRecordings)
        // Known only once Live TV has been asked about, which may be after
        // the first page was: listed again, a recording at a time.
        .onChange(of: holdsRecordings) { _, holds in
            if holds { Task { await reload(fresh: true) } }
        }
        .task(id: holdsRecordings) {
            // A library of recordings is in the order they were made, the
            // first time it's opened: by name, the news of seven nights is
            // the one name seven times. Whatever it's put in after that is
            // kept, as any library's is.
            let key = "goosetv.recordings.byDay." + library.id
            guard holdsRecordings, model.remembersFilters, !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            if state.filters.sort == .title, !state.filters.reversed { state.filters.sort = .added }
        }
        .task {
            // Alongside the first page rather than after it, so the filters
            // are all there when the grid is.
            async let choices: Void = loadFilterChoices()
            if state.loaded {
                // Back to the grid: it paints at once as it was. Watched marks
                // and progress are refreshed in place behind it, only if
                // something changed while it was away; refreshing every time
                // was a round trip for nothing on every back from a film.
                // Recordings arrive while it's away, as nothing else does: asked
                // again on coming back, but not back from one of them a moment later.
                let stale = holdsRecordings && Date().timeIntervalSince(model.fetchedAt) > 30
                if model.fetchedAtRevision != app.userDataRevision || model.itemsFilters != state.filters || stale {
                    await reload()
                }
            } else {
                await loadMore()
            }
            await choices
        }
        .onChange(of: state.filters) { _, filters in
            #if os(tvOS)
            resetBand()
            #endif
            // Not every show's, listed only while some are being chosen.
            if model.remembersFilters, state.showChoice == nil { app.saveFilters(filters, for: library.id) }
            Task { await reload(fresh: true) }
        }
    }

    private func itemFocusMoved(to new: String?, proxy: ScrollViewProxy) {
        #if os(tvOS)
        bandFocusMoved(to: new)
        #endif
        // Focus passes through nothing on its way from one title to the
        // next, so a move is measured from the last title that had it.
        guard let new else { return }
        let previous = scroll.arrive(at: new)
        if let at = model.positions[new] {
            let item = state.items[at]
            let letter = AlphabetIndex.letter(for: item.sortName ?? item.displayTitle)
            if alphabet.current != letter { alphabet.current = letter }
        }
        guard alphabet.skipping else { return }
        scheduleSkipEnd()
        skipIfClicked(from: previous, to: new, proxy: proxy)
    }

    /// Moving along the letters scrolls the grid there; the choice is made
    /// with select, which also puts focus on the first title.
    private func letterFocusMoved(from old: String?, to letter: String?, proxy: ScrollViewProxy) {
        scroll.pendingJump?.cancel()
        guard let letter else { return scheduleSkipEnd() }
        scroll.hide?.cancel()
        // Whatever title focus comes back to from here is where the viewer
        // chose to go, not a click from the title they left.
        scroll.enteredIndex()
        // Coming in from the grid lands on the letter it's at, rather than
        // whichever happened to be level with the poster, and doesn't move
        // the grid; only moving along the letters does.
        if old == nil, let current = alphabet.current, letter != current {
            focusedLetter = current
            return
        }
        guard letter != alphabet.current else { return }
        scroll.pendingJump = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await jump(to: letter, proxy: proxy, focusing: false)
        }
    }

    /// The grid as each platform shows it: on the Apple TV a row at a time
    /// (see the extension below), elsewhere a scrolling grid with the letters
    /// beside it.
    @ViewBuilder
    private func gridContent(_ proxy: ScrollViewProxy) -> some View {
        #if os(tvOS)
        bandGrid(proxy)
        #else
        HStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ShelfHeader(title: library.displayTitle, eyebrow: countLabel,
                            accent: Theme.primary)
                filterBar
                    .tvFocusSection()

                if !state.loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 400)
                        // Holds focus while loading so it can't escape to the menu;
                        // when the grid appears this vanishes and focus moves to it.
                        .focusable()
                } else if state.items.isEmpty {
                    VStack(spacing: 16) {
                        Text("No matches")
                            .font(.app(26, .bold))
                        Text("Nothing in \(library.displayTitle) fits these filters.")
                            .font(.app(18))
                            .foregroundStyle(Theme.textSecondary)
                        Button("Clear filters") { state.filters = LibraryFilters() }
                            .buttonStyle(.pill(selected: true))
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }

                // Ask for the next page a couple of rows before the end, so
                // scrolling never runs into a wall while it loads.
                let prefetchItem = state.items.dropLast(11).last
                LazyVGrid(columns: wide ? episodeColumns : columns, spacing: 32) {
                    if byDay {
                        // Recordings, newest first: each day's under its name.
                        ForEach(model.dayPlan(perRow: 1).days) { day in
                            Section {
                                ForEach(day.items) { gridCard($0, prefetch: prefetchItem) }
                            } header: {
                                Text(day.title)
                                    .font(.app(narrow ? 18 : 20, .bold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        ForEach(state.items) { gridCard($0, prefetch: prefetchItem) }
                    }
                }
            }
            .padding(.leading, narrow ? 16 : 40)
            .padding(.trailing, indexAvailable ? (narrow ? 4 : 16) : (narrow ? 16 : 40))
            .padding(.vertical, narrow ? 24 : 48)
        }
        // Holding the remote down scrolls rows by the second; after that,
        // clicks move a letter at a time for a while (see AlphabetState).
        // Read without redrawing (see ScrollWatch).
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            if indexAvailable, scroll.fast(at: y) { startSkipping() }
        }
        // Always there, in a column of its own beside the grid: right from the
        // last column goes into it. Laid over the grid, it sat on the last
        // column, and focus only moves right to something to the right.
        if indexAvailable {
            AlphabetIndex(alphabet: alphabet, focus: $focusedLetter) { letter in
                Task { await jump(to: letter, proxy: proxy, focusing: true) }
            }
            .frame(width: AlphabetIndex.cell + 16)
            .padding(.trailing, 24)
        }
        }
        .pageSides()
        #endif
    }

    /// A title in the grid that lays itself out.
    private func gridCard(_ item: BaseItem, prefetch: BaseItem?) -> some View {
        Group {
            if wide {
                LandscapeCard(item: item,
                              showDetails: { navigator.showItem(item.seriesId ?? item.id) }) {
                    playingItem = item
                }
            } else {
                PosterNavCard(item: item, focus: $focusedItem, pick: pick(item),
                              menuActions: { showActions(for: item) }, note: note(for: item))
            }
        }
        .onAppear {
            if item == prefetch || item == state.items.last {
                Task { await loadMore() }
            }
        }
    }

    // MARK: Filter bar

    /// Nothing happens for one with nothing to play, like a playlist of music.
    private func playAll(shuffled: Bool) async {
        guard let items = try? await app.client?.playQueue(for: library, shuffled: shuffled),
              let first = items.first else { return }
        playingQueue = Array(items.dropFirst())
        playingItem = first
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // Shows being chosen: done, none, or as they were.
                if let choice = state.showChoice {
                    Button {
                        finishChoosingShows(keep: true)
                    } label: {
                        FilterChipLabel(icon: "checkmark", text: String(localized: "Done"))
                    }
                    .buttonStyle(.chip(active: true))
                    if !choice.shows.isEmpty {
                        Button {
                            state.showChoice?.shows = [:]
                        } label: {
                            FilterChipLabel(icon: "circle", text: String(localized: "Choose None", comment: "Chip while shows are being chosen for a TV library's filters: unticks every show"))
                        }
                        .buttonStyle(.chip(active: false))
                    }
                    Button {
                        finishChoosingShows(keep: false)
                    } label: {
                        FilterChipLabel(icon: "xmark", text: String(localized: "Cancel"))
                    }
                    .buttonStyle(.chip(active: false))
                } else
                // The server's recordings, chosen several at a time to be
                // deleted: nothing else in the bar while that's going on.
                if deletable, selecting {
                    Button {
                        confirmingDelete = true
                    } label: {
                        FilterChipLabel(icon: "trash", text: chosen.count > 1
                            ? String(localized: "Delete \(chosen.count) Recordings", comment: "Deletes the chosen recordings from the server; the placeholder is how many")
                            : chosen.count == 1 ? String(localized: "Delete Recording", comment: "Deletes a recording from the server: its file is removed")
                            : String(localized: "Delete", comment: "Chip in a library of recordings: deletes the ones chosen; nothing is chosen yet"))
                    }
                    .buttonStyle(.chip(active: !chosen.isEmpty))
                    .disabled(chosen.isEmpty)
                    Button {
                        chosen = Set(state.items.filter(\.isOneVideo).map(\.id))
                    } label: {
                        FilterChipLabel(icon: "checkmark.circle", text: String(localized: "Select All"))
                    }
                    .buttonStyle(.chip(active: false))
                    Button {
                        stopSelecting()
                    } label: {
                        FilterChipLabel(icon: "xmark", text: String(localized: "Done"))
                    }
                    .buttonStyle(.chip(active: false))
                } else {
                if deletable, state.items.contains(where: \.isOneVideo) {
                    Button {
                        selecting = true
                    } label: {
                        FilterChipLabel(icon: "checkmark.circle", text: String(localized: "Select", comment: "Chip in a library of recordings: starts choosing several of them, to delete"))
                    }
                    .buttonStyle(.chip(active: false))
                }

                // A collection or playlist plays as a whole, in order or not.
                if library.isContainer {
                    Button {
                        Task { await playAll(shuffled: false) }
                    } label: {
                        FilterChipLabel(icon: "play.fill", text: String(localized: "Play All"))
                    }
                    .buttonStyle(.chip(active: true))
                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        FilterChipLabel(icon: "shuffle", text: String(localized: "Shuffle"))
                    }
                    .buttonStyle(.chip(active: false))
                }

                if state.filters != LibraryFilters() {
                    Button {
                        state.filters = LibraryFilters()
                    } label: {
                        FilterChipLabel(icon: "xmark", text: String(localized: "Clear", comment: "Removes all library filters"))
                    }
                    .buttonStyle(.chip(active: false))
                }

                Menu {
                    Picker("Sort by", selection: sortChoice) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    if state.filters.sort != .random {
                        Divider()
                        Picker(String(localized: "Order", comment: "Heading in the sort menu: which way round the sort goes"),
                               selection: $model.state.filters.reversed) {
                            Text(state.filters.sort.order(reversed: false)).tag(false)
                            Text(state.filters.sort.order(reversed: true)).tag(true)
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    FilterChipLabel(icon: "arrow.up.arrow.down", text: sortChipText, menu: true)
                }
                // A menu's own label went unread by VoiceOver.
                .accessibilityLabel(sortChipText)
                .buttonStyle(.chip(active: state.filters.sort != .title || state.filters.reversed))

                // Several at once, so each choice leaves the menu open.
                if !state.genres.isEmpty {
                    Menu {
                        Toggle("All genres", isOn: allChosen(\.genres))
                        Divider()
                        ForEach(state.genres, id: \.self) { genre in
                            Toggle(genre, isOn: chosen(genre, in: \.genres))
                        }
                    } label: {
                        FilterChipLabel(icon: "theatermasks.fill", text: genreChipText, menu: true)
                    }
                    .accessibilityLabel(genreChipText)
                    #if !os(macOS)
                    .menuActionDismissBehavior(.disabled)
                    #endif
                    .buttonStyle(.chip(active: !state.filters.genres.isEmpty))
                }

                if state.decades.count > 1 {
                    Menu {
                        Toggle("All years", isOn: allChosen(\.decades))
                        Divider()
                        ForEach(state.decades, id: \.self) { decade in
                            Toggle(LibraryFilters.decadeName(decade), isOn: chosen(decade, in: \.decades))
                        }
                    } label: {
                        FilterChipLabel(icon: "calendar", text: decadeChipText, menu: true)
                    }
                    .accessibilityLabel(decadeChipText)
                    #if !os(macOS)
                    .menuActionDismissBehavior(.disabled)
                    #endif
                    .buttonStyle(.chip(active: !state.filters.decades.isEmpty))
                }

                if library.collectionType == "tvshows" {
                    // Some shows and no others: chosen in the grid, a poster at a time.
                    Button {
                        chooseShows()
                    } label: {
                        FilterChipLabel(icon: state.filters.shows.isEmpty ? "tv" : "tv.fill", text: showsChipText)
                    }
                    .accessibilityLabel(showsChipText)
                    .buttonStyle(.chip(active: !state.filters.shows.isEmpty))

                    Button {
                        state.filters.episodes.toggle()
                    } label: {
                        FilterChipLabel(icon: state.filters.episodes ? "play.rectangle.fill" : "play.rectangle",
                                        text: String(localized: "Episodes"))
                    }
                    .buttonStyle(.chip(active: state.filters.episodes))
                }

                Button {
                    state.filters.unwatched.toggle()
                } label: {
                    FilterChipLabel(icon: state.filters.unwatched ? "eye.slash.fill" : "eye.slash", text: String(localized: "Unwatched"))
                }
                .buttonStyle(.chip(active: state.filters.unwatched))

                Button {
                    state.filters.favorites.toggle()
                } label: {
                    FilterChipLabel(icon: state.filters.favorites ? "star.fill" : "star", text: String(localized: "Favourites"))
                }
                .buttonStyle(.chip(active: state.filters.favorites))

                if state.filters != LibraryFilters() {
                    let existing = app.pin(for: library, filters: state.filters)
                    let inMenu = existing?.inMenu == true, onHome = existing?.onHome == true
                    Button {
                        app.setPin(library: library, filters: state.filters, inMenu: !inMenu)
                    } label: {
                        FilterChipLabel(icon: inMenu ? "pin.fill" : "pin",
                                        text: inMenu ? String(localized: "Pinned") : String(localized: "Pin to menu"))
                    }
                    .buttonStyle(.chip(active: inMenu))
                    // Or a row of its own on Home.
                    Button {
                        app.setPin(library: library, filters: state.filters, onHome: !onHome)
                    } label: {
                        FilterChipLabel(icon: onHome ? "house.fill" : "house",
                                        text: onHome ? String(localized: "On Home", comment: "Library filter bar: these filters are a row on Home")
                                                     : String(localized: "Add to Home", comment: "Library filter bar: makes these filters a row on Home"))
                    }
                    .buttonStyle(.chip(active: onHome))
                }
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
        }
        // Not under an iPhone Duo's camera strip (see Shelf).
        .scrollClipDisabled(barEdge == nil)
    }

    // MARK: Choosing recordings to delete

    /// What a card is while recordings are being chosen: one of the chosen
    /// or not, and chosen or let go by a press; a show or a folder, with
    /// more under it than a press should delete, can't be. Nil the rest of
    /// the time, when a card opens its page.
    private func pick(_ item: BaseItem) -> CardPick? {
        if let choice = state.showChoice {
            guard item.isSeries else { return CardPick(picked: false, toggle: nil) }
            return CardPick(picked: choice.shows[item.id] != nil) {
                if state.showChoice?.shows[item.id] != nil {
                    state.showChoice?.shows[item.id] = nil
                } else {
                    state.showChoice?.shows[item.id] = item.displayTitle
                }
            }
        }
        guard selecting else { return nil }
        guard item.isOneVideo else { return CardPick(picked: false, toggle: nil) }
        return CardPick(picked: chosen.contains(item.id)) {
            if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
        }
    }

    private func stopSelecting() {
        selecting = false
        chosen = []
    }

    /// Every show, A to Z, to tick the ones wanted; those already in the
    /// filters start ticked.
    private func chooseShows() {
        // The chip goes with the bar it's in, and focus stays on the page.
        app.holdMenuFocus()
        let returning = state.filters
        state.showChoice = ShowChoice(returning: returning, shows: returning.shows)
        state.filters = LibraryFilters()
    }

    /// Back to the filters choosing started from: with the shows ticked, or
    /// as they were.
    private func finishChoosingShows(keep: Bool) {
        guard let choice = state.showChoice else { return }
        app.holdMenuFocus()
        var filters = choice.returning
        if keep { filters.shows = choice.shows }
        state.showChoice = nil
        state.filters = filters
        #if os(tvOS)
        // On to the first title once they're here. Left in the bar, focus
        // went to Clear, where Done had been, and a second press cleared it all.
        Task {
            for _ in 0..<100 where model.itemsFilters != filters || loading {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard state.filters == filters, state.showChoice == nil, let first = state.items.first?.id else { return }
            focusedItem = first
        }
        #endif
    }

    private var showsChipText: String {
        let shows = state.filters.showList
        switch shows.count {
        case 0: return String(localized: "Shows", comment: "Filter chip in a TV library: starts choosing which shows to list")
        case 1: return shows[0]
        default: return String(localized: "\(shows.count) shows", comment: "Filter chip: how many shows are chosen")
        }
    }

    /// What a long press offers among the recordings, beyond what any
    /// card's does: on a show or one recording of it, how the server records
    /// it (how many it keeps, among the rest), where it's set to (matched by
    /// name: the server keeps a series' recordings under the name it records
    /// it by); on a show, the deleting of every recording it has of it.
    private func showActions(for item: BaseItem) -> [ItemMenuAction] {
        if library.isContainer { return containerActions(for: item) }
        guard deletable, item.isSeries || item.isOneVideo else { return [] }
        var actions: [ItemMenuAction] = []
        let show = item.isSeries ? item.displayTitle : (item.showName ?? item.displayTitle)
        if let series = recordings.seriesTimers.first(where: { $0.name.caseInsensitiveCompare(show) == .orderedSame }) {
            actions.append(ItemMenuAction(title: String(localized: "Recording Options", comment: "A recorded show's long-press menu: opens how its series is recorded"),
                                          icon: "record.circle") { seriesOpen = series })
        }
        if item.isSeries {
            actions.append(ItemMenuAction(title: String(localized: "Delete All Recordings", comment: "Deletes every recording of a show from the server"),
                                          icon: "trash", destructive: true) { deletingShow = item })
        }
        return actions
    }

    /// A playlist's or a collection's own row for what's in it: out of it,
    /// where this account may change it. The title itself stays.
    private func containerActions(for item: BaseItem) -> [ItemMenuAction] {
        guard containerEditable else { return [] }
        let playlist = library.type == "Playlist"
        return [ItemMenuAction(title: playlist ? String(localized: "Remove from Playlist", comment: "Takes a song out of a playlist; the song stays in the library")
                                               : String(localized: "Remove from Collection", comment: "Takes a film or a show out of a collection; it stays in the library"),
                               icon: "minus.circle", destructive: true) { removeFromContainer(item) }]
    }

    private func removeFromContainer(_ item: BaseItem) {
        guard let client = app.client else { return }
        let container = library
        let before = state.items
        let totalBefore = state.total
        // Focus was on the card going: kept on the grid.
        app.holdMenuFocus()
        state.items.removeAll { $0.id == item.id }
        state.total = max(0, state.total - 1)
        Task {
            do {
                if container.type == "Playlist" {
                    try await client.removeFromPlaylist(container.id, itemIds: [item.id])
                } else {
                    try await client.removeFromCollection(container.id, items: [item.id])
                }
                NotificationCenter.default.post(name: .songPlaylistsChanged, object: container.id)
            } catch {
                state.items = before
                state.total = totalBefore
                containerChangeFailed = true
            }
        }
    }

    /// Every recording of a show: the show itself is what the server is
    /// asked to delete, and its episodes go with it.
    private func deleteShow(_ show: BaseItem) {
        guard let client = app.client else { return }
        app.holdMenuFocus()
        Task {
            if (try? await client.deleteItem(show.id)) != nil {
                app.holdMenuFocus()
                app.deleted([show.id])
            } else {
                deleteFailed = true
            }
        }
    }

    /// Deletes the chosen recordings one after another, and says so if any
    /// wouldn't go. The ones that went leave the grid as they do.
    private func deleteChosen() {
        guard let client = app.client else { return }
        let ids = state.items.map(\.id).filter { chosen.contains($0) }
        // The chip that asked goes with the choosing, and focus with it:
        // to the page's own, not the menu.
        app.holdMenuFocus()
        stopSelecting()
        Task {
            var gone: [String] = []
            for id in ids {
                if (try? await client.deleteItem(id)) != nil { gone.append(id) }
            }
            app.holdMenuFocus()
            app.deleted(gone)
            if gone.count < ids.count { deleteFailed = true }
        }
    }

    /// A new sort starts its usual way round.
    private var sortChoice: Binding<LibrarySort> {
        Binding {
            state.filters.sort
        } set: { sort in
            var filters = state.filters
            filters.sort = sort
            filters.reversed = false
            state.filters = filters
        }
    }

    private var sortChipText: String {
        let filters = state.filters
        if filters.sort == .title && !filters.reversed {
            return String(localized: "Sort", comment: "Filter chip that opens the sort order menu")
        }
        guard filters.reversed else { return filters.sort.label }
        // "Title, Z to A"
        return String(localized: "\(filters.sort.label), \(filters.sort.order(reversed: true))",
                      comment: "Filter chip: the sort, then which way round it goes")
    }

    private var genreChipText: String {
        let genres = state.filters.genreList
        switch genres.count {
        case 0: return String(localized: "Genre")
        case 1: return genres[0]
        default: return String(localized: "\(genres.count) genres", comment: "Filter chip: how many genres are chosen")
        }
    }

    /// The genres and decades the filters offer. Tried again next visit if
    /// the server didn't answer.
    private func loadFilterChoices() async {
        guard !state.choicesLoaded, let client = app.client else { return }
        async let genres = try? client.genres(in: library.id)
        async let years = try? client.years(in: library.id)
        let (foundGenres, foundYears) = await (genres, years)
        state.genres = foundGenres ?? []
        state.decades = Array(Set((foundYears ?? []).map { $0 / 10 * 10 })).sorted(by: >)
        state.choicesLoaded = foundGenres != nil && foundYears != nil
    }

    private var decadeChipText: String {
        let decades = state.filters.decades.sorted()
        switch decades.count {
        case 0: return String(localized: "Year", comment: "Filter chip that opens the decades menu")
        case 1: return LibraryFilters.decadeName(decades[0])
        default: return String(localized: "\(decades.count) decades", comment: "Filter chip: how many decades are chosen")
        }
    }

    /// On when nothing narrows the list; choosing it clears the choices.
    private func allChosen<T>(_ set: WritableKeyPath<LibraryFilters, Set<T>>) -> Binding<Bool> {
        Binding {
            state.filters[keyPath: set].isEmpty
        } set: { on in
            if on { state.filters[keyPath: set] = [] }
        }
    }

    private func chosen<T: Hashable>(_ value: T, in set: WritableKeyPath<LibraryFilters, Set<T>>) -> Binding<Bool> {
        Binding {
            state.filters[keyPath: set].contains(value)
        } set: { on in
            if on { state.filters[keyPath: set].insert(value) } else { state.filters[keyPath: set].remove(value) }
        }
    }

    private var countLabel: String {
        if let choice = state.showChoice {
            switch choice.shows.count {
            case 0: return String(localized: "Choose the shows to list", comment: "Over a TV library while shows are being chosen for its filters; none is ticked yet")
            case 1: return String(localized: "1 show chosen", comment: "Over a TV library while shows are being chosen for its filters; one is ticked")
            default: return String(localized: "\(choice.shows.count) shows chosen", comment: "Over a TV library while shows are being chosen for its filters")
            }
        }
        guard state.loaded else { return String(localized: "Library") }
        let total = state.total
        if state.filters.sort == .random {
            return String(localized: "\(total) at random", comment: "Number of titles picked at random from the library")
        }
        // A sort alone leaves every title there.
        let unfiltered = !state.filters.narrows
        if library.collectionType == "movies" {
            return unfiltered ? String(localized: "\(total) movies")
                              : String(localized: "\(total) movies match", comment: "Number of movies that fit the chosen filters")
        }
        if library.holdsVideos, unfiltered { return String(localized: "\(total) videos") }
        return unfiltered ? String(localized: "\(total) titles")
                          : String(localized: "\(total) titles match", comment: "Number of titles that fit the chosen filters")
    }

    // MARK: Loading

    /// Refreshes what's loaded; `fresh` starts again from one page, for new filters.
    private func reload(fresh: Bool = false) async {
        guard let client = app.client, !loading else { return }
        loading = true
        defer { loading = false }
        var fresh = fresh
        while true {
            let requested = state.filters
            await reload(client, filters: requested, fresh: fresh)
            // Changed again while that was on its way (a second genre ticked
            // in the open menu): the reload asked for then went unheard, so
            // this one goes again for them.
            guard state.filters != requested else { break }
            fresh = true
        }
    }

    private func reload(_ client: any MediaServer, filters requested: LibraryFilters, fresh: Bool) async {
        let revision = app.userDataRevision
        // Afresh, too, when the titles on show aren't these filters'.
        let fresh = fresh || model.itemsFilters != requested
        // A random choice stays as it was: only its titles are brought up to date.
        if requested.sort == .random, !fresh, state.loaded {
            if await refreshInPlace(client, filters: requested) { model.fetchedAtRevision = revision }
            return
        }
        // In a long list, only the titles around where the viewer is: what a
        // film's page or a player changed is there, and refetching two
        // thousand titles each time a film closed was 2 MB for nothing.
        // (Not the favourite or chosen shows' episodes, which only come whole.)
        if !fresh, state.items.count > Self.refreshWindow, !requested.episodesByShow,
           !Self.byDay(requested, in: holdsRecordings),
           await refreshAround(client, filters: requested) {
            model.fetchedAtRevision = revision
            model.fetchedAt = Date()
            return
        }
        // Otherwise everything already loaded, not just the first page:
        // replacing a list scrolled to its 500th title with the first 100 took
        // away the title focus was on, and back from its page landed elsewhere.
        let count = fresh ? pageSize : max(state.items.count, pageSize)
        if let result = try? await fetchPage(client, startIndex: 0, limit: count, filters: requested),
           requested == state.filters {
            // Swapped in place rather than cleared first: blanking the grid
            // dropped focus and the scroll position every time it refreshed.
            if state.loaded { app.holdMenuFocus() }
            state.items = result.items
            // The server shuffles again for every page, so a random choice is
            // the one page: further pages would repeat some titles and miss others.
            state.total = requested.sort == .random
                ? result.items.count : result.totalRecordCount ?? result.items.count
            model.fetchedAtRevision = revision
            model.fetchedAt = Date()
            model.itemsFilters = requested
        }
        state.loaded = true
    }

    /// The titles already there, fetched again by id and kept in their order,
    /// less any the filters now leave out.
    private func refreshInPlace(_ client: any MediaServer, filters requested: LibraryFilters) async -> Bool {
        guard let fetched = try? await client.items(ids: state.items.map(\.id)),
              requested == state.filters else { return false }
        let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = state.items.compactMap { byID[$0.id] }.filter { item in
            (!requested.unwatched || item.userData?.played != true)
                // An episode there for its show is no favourite itself.
                && (!requested.favorites || requested.episodesByShow || item.userData?.isFavorite == true)
        }
        if state.loaded { app.holdMenuFocus() }
        state.items = items
        state.total = items.count
        return true
    }

    private static let refreshWindow = 300

    /// Refetches the titles either side of the last one in focus and swaps
    /// them in place. False when the list has shifted underneath (a title
    /// added or removed), which needs the whole of it again.
    private func refreshAround(_ client: any MediaServer, filters requested: LibraryFilters) async -> Bool {
        let focus = scroll.lastTitleID.flatMap { model.positions[$0] } ?? 0
        let start = max(0, min(focus - Self.refreshWindow / 2, state.items.count - Self.refreshWindow))
        guard let result = try? await fetchPage(client, startIndex: start, limit: Self.refreshWindow,
                                                filters: requested),
              requested == state.filters else { return false }
        let fresh = result.items
        let end = start + fresh.count
        guard end <= state.items.count,
              state.items[start..<end].elementsEqual(fresh, by: { $0.id == $1.id }) else { return false }
        state.items.replaceSubrange(start..<end, with: fresh)
        return true
    }

    private func loadMore() async {
        guard let client = app.client, !loading else { return }
        guard !state.loaded || state.items.count < state.total else { return }
        loading = true
        defer { loading = false }
        let requested = state.filters
        let revision = app.userDataRevision
        let result = try? await fetchPage(client, startIndex: state.items.count, filters: requested)
        if let result, requested == state.filters {   // drop results for filters the user has since changed
            if state.items.isEmpty { model.fetchedAtRevision = revision; model.fetchedAt = Date() }
            state.items.append(contentsOf: result.items)
            // A random choice is its first page, and that's all (see reload).
            state.total = requested.sort == .random
                ? state.items.count : result.totalRecordCount ?? state.items.count
            model.itemsFilters = requested
        }
        // The section was left while its first titles were on their way: not
        // loaded, so coming back asks again rather than finding nothing.
        if result == nil, state.items.isEmpty, Task.isCancelled { return }
        state.loaded = true
        // The filters changed while this page was on its way, and the reload
        // they asked for found a page loading and went unheard.
        if requested != state.filters { Task { await reload(fresh: true) } }
    }

    private func fetchPage(_ client: any MediaServer, startIndex: Int, limit: Int? = nil,
                           filters requested: LibraryFilters, before letter: String? = nil) async throws -> ItemsResult {
        try await client.listing(of: library, filters: requested, recordings: holdsRecordings,
                                 startIndex: startIndex, limit: limit ?? pageSize, before: letter)
    }

    // MARK: Alphabet index

    /// Only where it means something: titles in alphabetical order, and more
    /// of them than a few presses get through.
    private var indexAvailable: Bool {
        state.filters.sort == .title && !state.filters.reversed && !state.filters.episodes && state.total > 150
    }

    private func startSkipping() {
        if !alphabet.skipping { withAnimation(.easeOut(duration: 0.2)) { alphabet.skipping = true } }
        scheduleSkipEnd()
    }

    /// Back to a row at a time a few seconds after the last move.
    private func scheduleSkipEnd() {
        scroll.hide?.cancel()
        scroll.hide = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, focusedLetter == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { alphabet.skipping = false }
        }
    }

    /// Scrolls to the first title at or after the letter; with `focusing`,
    /// lands there and ends letter-at-a-time mode.
    private func jump(to letter: String, proxy: ScrollViewProxy, focusing: Bool) async {
        guard let target = await start(of: letter), !Task.isCancelled else { return }
        await go(to: target, proxy: proxy, focusing: focusing, keepIndex: !focusing)
    }

    /// Where a letter's titles begin: one count from the server of those that
    /// sort before it. Past the end for a letter nothing is filed under.
    private func start(of letter: String) async -> Int? {
        guard letter != AlphabetIndex.symbols else { return 0 }
        guard let client = app.client,
              let before = try? await fetchPage(client, startIndex: 0, limit: 0, filters: state.filters,
                                                before: letter.lowercased()) else { return nil }
        return before.totalRecordCount ?? 0
    }

    /// Scrolls to the title at this place in the list, loading the pages up
    /// to it in one request if they aren't here yet.
    private func go(to index: Int, proxy: ScrollViewProxy, focusing: Bool, keepIndex: Bool) async {
        guard let client = app.client, index < state.total else { return }
        let requested = state.filters
        // Only to fetch: a title already here is gone to at once, whatever is
        // loading (back to the top during a long refresh did nothing).
        if index >= state.items.count {
            // A page may be on its way from the scrolling that brought the index up.
            for _ in 0..<40 where loading { try? await Task.sleep(for: .milliseconds(50)) }
            guard !loading, !Task.isCancelled else { return }
        }
        if index >= state.items.count {
            loading = true
            defer { loading = false }
            guard let more = try? await fetchPage(client, startIndex: state.items.count,
                                                  limit: index - state.items.count + pageSize,
                                                  filters: requested),
                  requested == state.filters else { return }
            state.items.append(contentsOf: more.items)
            // A beat for the grid to lay out what just arrived: scrolled to at
            // once, the title isn't there yet and the grid stays put.
            try? await Task.sleep(for: .milliseconds(120))
        }
        // Left the letters for the grid while this was on its way: the viewer
        // is already where they want to be.
        guard requested == state.filters, state.items.indices.contains(index),
              !Task.isCancelled else { return }
        let id = state.items[index].id
        scroll.quiet(for: 1.5)   // the jump itself isn't fast scrolling
        #if os(tvOS)
        bring(toIndex: index)
        #else
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
        #endif
        guard focusing else { return }
        try? await Task.sleep(for: .milliseconds(80))
        scroll.landing = id
        focusedItem = id
        if !keepIndex { withAnimation(.easeOut(duration: 0.25)) { alphabet.skipping = false } }
    }

    /// A single click up or down in the grid while the index is up, not a hold:
    /// down goes to the next letter's first title, up to the start of this
    /// letter, or of the one before when already there. The click has moved
    /// focus a row by then; the jump carries on from where it started.
    private func skipIfClicked(from previous: (id: String, after: TimeInterval)?, to new: String,
                               proxy: ScrollViewProxy) {
        guard let previous, previous.after > 0.35, focusedLetter == nil, new != scroll.landing,
              let from = model.positions[previous.id],
              let to = model.positions[new],
              abs(to - from) > 1   // a row up or down, not a step along it
        else { return }
        let item = state.items[from]
        let letter = AlphabetIndex.letter(for: item.sortName ?? item.displayTitle)
        let letters = AlphabetIndex.letters
        guard let at = letters.firstIndex(of: letter) else { return }
        let down = to > from
        Task {
            if down {
                for next in letters[(at + 1)...] {
                    if let target = await start(of: next), target > from, target < state.total {
                        return await go(to: target, proxy: proxy, focusing: true, keepIndex: true)
                    }
                }
            } else {
                // Back to where this letter starts, or the one before it.
                let candidates = [letter] + letters[..<at].reversed()
                for previous in candidates {
                    if let target = await start(of: previous), target < from {
                        return await go(to: target, proxy: proxy, focusing: true, keepIndex: true)
                    }
                }
            }
        }
    }
}

#if os(tvOS)
/// The Apple TV's library grid: the library's name and filters across the
/// top and the grid beneath them, moving a row at a time, each row gliding up
/// to the same place under the filters. It moves the way Home's rows do, for
/// the same reasons (see SpotlightHome): the focus engine moves between rows,
/// only the rows either side of the band's can take focus, the rows above it
/// are drawn under a cover, and a move never rebuilds a row.
extension LibraryGrid {
    /// Where the band starts: just under the filters.
    private static let bandTop: CGFloat = 150
    private static let rowGap: CGFloat = 8
    private static let glide = Animation.easeOut(duration: 0.35)
    /// How far the band reaches below the screen, for the glide up a row.
    private static let glideReach: CGFloat = 520
    private static let margin: CGFloat = 40

    /// A card's usual width, and the gap between cards.
    private var baseCardWidth: CGFloat { wide ? Theme.landscapeWidth : SpotlightHome.posterWidth }
    private var cardGap: CGFloat { wide ? 32 : 24 }

    /// What the cards share: the band, less its margin and the letters' room.
    private var usableWidth: CGFloat { bandWidth - Self.margin - bandTrailing }

    /// Cards to a row: as many of their usual width as fit.
    private var perRow: Int {
        max(1, Int((usableWidth + cardGap) / (baseCardWidth + cardGap)))
    }

    /// Each card a little wider than usual, so the row reaches the letters
    /// rather than stopping short of them.
    private var cardWidth: CGFloat {
        guard usableWidth > 0 else { return baseCardWidth }
        return ((usableWidth - cardGap * CGFloat(perRow - 1)) / CGFloat(perRow)).rounded(.down)
    }

    /// The letters' room, when they're there.
    private var bandTrailing: CGFloat { indexAvailable ? AlphabetIndex.cell + 56 : Self.margin }

    /// Recordings by the day: the rows as that cuts them (see `DayPlan`).
    private var dayPlan: DayPlan? { byDay ? model.dayPlan(perRow: perRow) : nil }

    private var rowCount: Int { dayPlan?.starts.count ?? (state.items.count + perRow - 1) / perRow }

    private func items(inRow row: Int) -> [BaseItem] {
        if let dayPlan {
            let range = dayPlan.range(ofRow: row, count: state.items.count)
            guard range.upperBound <= state.items.count else { return [] }
            return Array(state.items[range])
        }
        let start = row * perRow
        guard start < state.items.count else { return [] }
        return Array(state.items[start..<min(start + perRow, state.items.count)])
    }

    /// The row the title at a place in the list is in.
    private func row(at position: Int) -> Int {
        if let dayPlan { return dayPlan.rowOf.indices.contains(position) ? dayPlan.rowOf[position] : max(dayPlan.starts.count - 1, 0) }
        return position / perRow
    }

    private func row(of id: String) -> Int? {
        model.positions[id].map(row(at:))
    }

    func bandGrid(_ proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .topLeading) {
            if state.loaded, !state.items.isEmpty {
                // As wide as the page and no wider, whatever the rows: the
                // scroll view, reaching past the screen's edges, sits a little
                // wider than the page, and the page grew with it.
                GeometryReader { _ in band }
            } else {
                placeholder
                    .padding(.top, Self.bandTop)
                    .padding(.horizontal, Self.margin)
                    // The page's full height, as the grid is: shorter, the
                    // whole stack was centred, and the title and filters
                    // dropped a third of the way down the screen.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            SpotlightCover(bandTop: Self.bandTop)
            VStack(alignment: .leading, spacing: 4) {
                ShelfHeader(title: library.displayTitle, eyebrow: countLabel, accent: Theme.primary)
                    .padding(.horizontal, 4)
                AsideFromHandover(hold: app.menuHold) {
                    filterBar
                        .tvFocusSection()
                }
                .disabled(!besideTitlesReachable)
            }
            .padding(.leading, Self.margin)
            .padding(.trailing, bandTrailing)
        }
        // The page's width, which the cards are shared out from. Measured
        // while the first page loads too, so the rows come out right at once.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard abs(bandWidth - width) > 0.5 else { return }
            bandWidth = width
            LibraryGridModel.bandWidth = width
        }
        // Over the page rather than in it: the letters stand a little taller
        // than the screen, and as part of the page they made it taller too,
        // which then sat higher than a short library's without them.
        .overlay(alignment: .trailing) {
            if indexAvailable {
                AsideFromHandover(hold: app.menuHold) {
                    AlphabetIndex(alphabet: alphabet, focus: $focusedLetter) { letter in
                        Task { await jump(to: letter, proxy: proxy, focusing: true) }
                    }
                }
                .disabled(!besideTitlesReachable)
                .frame(width: AlphabetIndex.cell + 16)
                .padding(.trailing, 24)
            }
        }
        .pageSides()
    }

    /// The filters and the letters, once the titles have had focus, or when
    /// there are no titles for it to go to (nothing matched).
    private var besideTitlesReachable: Bool {
        titlesHadFocus || (state.loaded && state.items.isEmpty)
    }

    /// While loading, holds focus so it can't escape to the menu; when the grid
    /// appears this goes and focus moves to it. Or nothing matched.
    @ViewBuilder
    private var placeholder: some View {
        if !state.loaded {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
                .focusable()
        } else {
            VStack(spacing: 16) {
                Text("No matches")
                    .font(.app(26, .bold))
                Text("Nothing in \(library.displayTitle) fits these filters.")
                    .font(.app(18))
                    .foregroundStyle(Theme.textSecondary)
                Button("Clear filters") { state.filters = LibraryFilters() }
                    .buttonStyle(.pill(selected: true))
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    /// From the top of one row to the next: a row's height as its cards make
    /// it, or taller if a row measured taller (a language whose titles stand
    /// higher). Never only what was measured last: on a real Apple TV a row measured
    /// mid-change left the rows a few points short of their cards, and every
    /// row overlapped the one before it until the library was left.
    private var rowPitch: CGFloat {
        let measured = measuredAt == rowLayout ? measuredRowHeight : 0
        return max(expectedRowHeight, measured) + Self.rowGap
    }

    /// A row as its cards lay it out: the picture, the title lines under it
    /// and the room above and below for the focus lift (measured on 1.2).
    private var expectedRowHeight: CGFloat {
        (wide ? cardWidth * 9 / 16 + 96 : cardWidth * 3 / 2 + 73)
            + (byDay ? LibraryBandRow.headRoom : 0) + (holdsRecordings && !wide ? 20 : 0)
    }

    private var rowLayout: RowLayout {
        RowLayout(cardWidth: cardWidth, episodes: wide, headed: byDay, noted: holdsRecordings)
    }

    /// A row's height that a cards' size and kind make.
    private func measured(_ height: CGFloat) {
        if measuredAt != rowLayout {
            measuredAt = rowLayout
            measuredRowHeight = height
        } else if height > measuredRowHeight + 0.5 {
            measuredRowHeight = height
        }
    }

    /// The rows there are: from three above the band's (under the cover,
    /// where the one just above can take focus) to four below it. Around the
    /// row the locks follow, which catches up a moment after a move, so a
    /// row's worth of cards is made and let go after the press is answered,
    /// not before it.
    private var windowRows: [Int] {
        guard rowCount > 0 else { return [] }
        return Array(windowStart...min(rowCount - 1, min(lockRow, rowCount - 1) + 4))
    }

    /// The first row there is. Rows are placed from it, and the whole band
    /// moves by the band's row: a move shifts one block, rather than every
    /// row (and every card's place for the focus engine) one by one.
    private var windowStart: Int { max(0, min(lockRow, max(rowCount - 1, 0)) - 3) }

    /// Only the rows around the band's exist, each placed by how far it is
    /// from the band's row, and a move shifts them a row. Scrolling had ideas
    /// of its own (a lazy scroll view eased itself back towards the top after
    /// each jump, and its insets left the band a row out), so nothing scrolls.
    /// The rows are in a scroll view all the same, for the glide: it moves the
    /// scroll view itself, as on Home, and the cards, which the system draws
    /// in layers of its own, go with it. Moving the rows instead left cards
    /// ahead of their titles or behind them for the length of the glide.
    private var band: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                ForEach(windowRows, id: \.self) { row in
                    EquatableView(content: LibraryBandRow(
                        items: items(inRow: row), episodes: wide, cardWidth: cardWidth, gap: cardGap,
                        heading: dayPlan.flatMap { $0.headings.indices.contains(row) ? $0.headings[row] : nil },
                        headed: byDay, note: holdsRecordings ? note : nil,
                        onlyFocusable: onlyFocusable(inRow: row), focus: $focusedItem,
                        picked: picking ? pickedIDs.intersection(items(inRow: row).map(\.id)) : nil, pick: pick,
                        menu: showActions,
                        showDetails: { navigator.showItem($0.seriesId ?? $0.id) },
                        play: { playingItem = $0 }))
                        // Two or more rows from the band's can't take focus.
                        .disabled(row != pendingRow && abs(row - lockRow) >= 2)
                        // The whole row's width is a target for up and down, so a
                        // short last row is reached from under the far end.
                        .focusSection()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
                        .offset(y: CGFloat(row - windowStart) * rowPitch)
                        // The next page a few rows before the end.
                        .onAppear { if row >= rowCount - 4 { Task { await loadMore() } } }
                }
            }
            .padding(.leading, Self.margin)
            .padding(.trailing, bandTrailing)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, Self.glideReach + Self.bandTop)
            // The jump to the band's row, at once.
            .offset(y: -CGFloat(bandRow - windowStart) * rowPitch)
        }
        .scrollDisabled(true)
        // A glide's reach past the page at either end, so a row gliding in or
        // out isn't cut off by the scroll view's edge; the row above the
        // band's, under the cover, is inside it too, where focus can reach.
        .ignoresSafeArea()
        .padding(.vertical, -Self.glideReach)
        .offset(y: glideOffset)
        // The band's focus section ends where the cards do, short of the
        // letters (the padding changes the section, not the layout). Reaching
        // under them, it held the letters, so it wasn't to a letter's left:
        // left from a letter with no card level with it (W to Z, or below the
        // last row) passed every title and went to the menu.
        .padding(.trailing, -bandTrailing)
        .focusSection()
        .padding(.trailing, bandTrailing)
    }

    // MARK: Focus

    /// While focus is outside the band (the filters, the letters, the menu, a
    /// film's page), the band's row lets only its landing card take focus.
    private func onlyFocusable(inRow row: Int) -> String? {
        guard !bandFocused, pendingRow == nil, row == bandRow else { return nil }
        return landingID
    }

    /// The title last in focus, if it's in the band's row, or the row's first.
    /// While recordings are being chosen, one that can be: a show can't, and
    /// landing on it left the row with nothing to take focus at all.
    private var landingID: String? {
        let row = items(inRow: bandRow)
        if picking {
            if let id = model.focusedTitle, row.contains(where: { $0.id == id && pickable($0) }) { return id }
            return row.first(where: pickable)?.id
        }
        if let id = model.focusedTitle, self.row(of: id) == bandRow { return id }
        return row.first?.id
    }

    func bandFocusMoved(to id: String?) {
        guard let id else {
            // Gone from the band, unless it's only passing between two cards.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if focusedItem == nil, bandFocused { bandFocused = false }
            }
            return
        }
        let entering = !bandFocused
        if entering { bandFocused = true }
        if !titlesHadFocus { titlesHadFocus = true }
        guard let position = model.positions[id] else { return }
        let row = row(at: position)
        if let pendingRow, row != pendingRow { return }
        if pendingRow == row { pendingRow = nil }
        // Back into the grid, the focus engine can reach the rows either side
        // of the band's too: from there, on to the landing card.
        if entering, row != bandRow, let landingID {
            focusedItem = landingID
            return
        }
        model.focusedTitle = id
        if row != bandRow { arrive(at: row) }
    }

    /// The band moves to `row`: the scroll jumps there and the rows, drawn
    /// back where they were, ease into place. A jump of more than a couple of
    /// rows (a letter) goes straight there.
    private func arrive(at row: Int) {
        let rows = row - bandRow
        let near = abs(rows) <= 2
        pendingRow = nil
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            bandRow = row
            glideOffset = near ? CGFloat(rows) * rowPitch : 0
        }
        model.bandRow = row
        // Held down, the remote moves rows by the second; after that, clicks
        // move a letter at a time for a while (see AlphabetState).
        if indexAvailable, near, scroll.fast(at: CGFloat(row) * rowPitch) { startSkipping() }
        if near {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1))
                withAnimation(Self.glide) { glideOffset = 0 }
                try? await Task.sleep(for: .milliseconds(30))
                if bandRow == row { lockRow = row }
            }
        } else {
            lockRow = row
        }
    }

    /// A letter: the band goes to the row with the title at `index`, and
    /// focus coming back to the grid lands on it, whether the letter was
    /// chosen or only passed over.
    func bring(toIndex index: Int) {
        let row = row(at: index)
        if row != bandRow { arrive(at: row) }
        lockRow = row
        guard state.items.indices.contains(index) else { return }
        model.focusedTitle = state.items[index].id
    }

    /// New filters: a new list, from its top.
    func resetBand() {
        bandRow = 0
        lockRow = 0
        pendingRow = nil
        glideOffset = 0
        model.bandRow = 0
        model.focusedTitle = nil
    }
}

/// What a library row's height depends on.
struct RowLayout: Equatable {
    let cardWidth: CGFloat
    let episodes: Bool
    /// Rows with room over them for a day's name, and titles with a line
    /// under them: a library of recordings.
    var headed = false
    var noted = false
}

/// One row of the Apple TV's library grid. Equatable, so a move never rebuilds
/// it: only its own titles changing do.
private struct LibraryBandRow: View, Equatable {
    let items: [BaseItem]
    let episodes: Bool
    let cardWidth: CGFloat
    let gap: CGFloat
    /// The day this row's recordings were made, where it's the day's first
    /// row; and whether the grid's rows leave room for one at all (every
    /// row does or none, so that the rows stay a row apart).
    var heading: String? = nil
    var headed = false
    /// A line under each title's name, where the grid has one.
    var note: ((BaseItem) -> String?)? = nil
    static let headRoom: CGFloat = 34
    /// Set while focus is outside the band: the one card that may take it.
    let onlyFocusable: String?
    var focus: FocusState<String?>.Binding
    /// While recordings are being chosen: which of this row's are, and what
    /// each card is then (see `LibraryGrid.pick`). Nil otherwise.
    var picked: Set<String>? = nil
    var pick: (BaseItem) -> CardPick? = { _ in nil }
    /// Rows of the grid's own for a card's long-press menu, asked for as
    /// the menu opens.
    var menu: (BaseItem) -> [ItemMenuAction] = { _ in [] }
    let showDetails: (BaseItem) -> Void
    let play: (BaseItem) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.onlyFocusable == rhs.onlyFocusable && lhs.episodes == rhs.episodes && lhs.cardWidth == rhs.cardWidth
            && lhs.picked == rhs.picked && lhs.heading == rhs.heading && lhs.headed == rhs.headed
            && (lhs.note == nil) == (rhs.note == nil)
            && lhs.items.elementsEqual(rhs.items) {
                $0.id == $1.id && $0.progressFraction == $1.progressFraction
                    && $0.userData?.played == $1.userData?.played
                    && $0.userData?.unplayedItemCount == $1.userData?.unplayedItemCount
            }
    }

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(items) { item in
                Group {
                    if episodes {
                        LandscapeCard(item: item, showDetails: { showDetails(item) }, focus: focus, width: cardWidth) { play(item) }
                    } else {
                        PosterNavCard(item: item, width: cardWidth, focus: focus, pick: picked == nil ? nil : pick(item),
                                      menuActions: { menu(item) }, note: note?(item))
                    }
                }
                .disabled(onlyFocusable.map { $0 != item.id } ?? false)
            }
        }
        // Room for the focus lift, and over it for the day's name.
        .padding(.bottom, 20)
        .padding(.top, 20 + (headed ? Self.headRoom : 0))
        .overlay(alignment: .topLeading) {
            if let heading {
                Text(heading)
                    .font(.app(20, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
        }
    }
}
#endif

/// How fast the grid is moving, and the index's timers. A reference, so noting
/// every scroll position doesn't redraw the grid the way state would.
@MainActor
private final class ScrollWatch {
    private var since: Date?
    private var from: CGFloat = 0
    private var quietUntil = Date.distantPast
    var hide: Task<Void, Never>?
    var pendingJump: Task<Void, Never>?
    /// The title a jump just put focus on, whose focus change isn't a click.
    var landing: String?
    private var lastTitle: (id: String, at: Date)?
    var lastTitleID: String? { lastTitle?.id }
    private var fromIndex = false

    /// Focus went into the letters; the next title it reaches isn't a click.
    func enteredIndex() { fromIndex = true }

    /// Notes focus arriving on a title, and returns the one before and how
    /// long it had focus: a click comes after a pause, while a held button's
    /// moves are a fraction of a second apart.
    func arrive(at id: String) -> (id: String, after: TimeInterval)? {
        let now = Date()
        defer { lastTitle = (id, now); fromIndex = false }
        if fromIndex { return nil }
        return lastTitle.map { ($0.id, now.timeIntervalSince($0.at)) }
    }

    /// Whether the grid has covered three rows' worth or more within a
    /// second: held down, it does; pressed row by row, it doesn't.
    func fast(at y: CGFloat) -> Bool {
        let now = Date()
        guard now > quietUntil else {
            since = nil
            return false
        }
        guard let since, now.timeIntervalSince(since) < 1 else {
            self.since = now
            from = y
            return false
        }
        guard abs(y - from) > 1100 else { return false }
        self.since = now
        from = y
        return true
    }
}

extension ScrollWatch {
    /// Ignores the scrolling for a moment, while the grid is moved for the viewer.
    func quiet(for seconds: TimeInterval) { quietUntil = Date().addingTimeInterval(seconds) }
}

/// What the alphabet shows. An object of its own so the grid, which keeps it,
/// isn't redrawn with it.
@MainActor
private final class AlphabetState: ObservableObject {
    /// The letter of the title in focus.
    @Published var current: String?
    /// For a few seconds after fast scrolling: the big letter shows beside the
    /// column, and a click up or down moves a whole letter rather than a row.
    @Published var skipping = false
}

/// The letters down the right of a long grid. Each one scrolls there when
/// highlighted, and select lands on its first title.
private struct AlphabetIndex: View {
    /// Titles starting with a digit or a symbol.
    static let symbols = "#"
    static let letters = [symbols] + (65...90).compactMap { UnicodeScalar($0).map(String.init) }

    @ObservedObject var alphabet: AlphabetState
    var focus: FocusState<String?>.Binding
    let choose: (String) -> Void

    private var current: String? { alphabet.current }
    /// The big letter beside the column: the highlighted one while moving
    /// along the letters, where a white disc alone was too small to read
    /// across a room; and the grid's while clicks skip letters.
    private var tileLetter: String? {
        focus.wrappedValue ?? (alphabet.skipping ? current : nil)
    }

    /// A round cell per letter. 27 of them and the panel's inset come to
    /// about 980 points, inside the screen's 1080.
    static let cell = CGFloat(30).scaled
    private static let rowHeight = cell
    private static let rowGap: CGFloat = 1
    private static let inset: CGFloat = 12

    static func letter(for sortName: String) -> String {
        guard let first = sortName.first?.uppercased(), letters.contains(first) else { return symbols }
        return first
    }

    var body: some View {
        VStack(spacing: Self.rowGap) {
            ForEach(Self.letters, id: \.self) { letter in
                Button { choose(letter) } label: {
                    Text(verbatim: letter)
                        .font(.app(letter == current ? 19 : 17, letter == current ? .heavy : .semibold))
                        .frame(width: Self.cell, height: Self.rowHeight)
                }
                .buttonStyle(IndexLetterStyle(current: letter == current))
                .focused(focus, equals: letter)
                .accessibilityLabel(String(localized: "Jump to \(letter)"))
            }
        }
        .padding(.vertical, Self.inset)
        .padding(.horizontal, 6)
        .background {
            let panel = RoundedRectangle(cornerRadius: 24, style: .continuous)
            panel.fill(.black.opacity(0.4))
                .background(.ultraThinMaterial, in: panel)
                .overlay { panel.strokeBorder(.white.opacity(0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
        .overlay(alignment: .topTrailing) {
            if let letter = tileLetter, let row = Self.letters.firstIndex(of: letter) {
                LetterTile(letter: letter)
                    // Level with its row in the column, just to the left of it.
                    // Offsets rather than alignment guides, which were lost
                    // through the tile's transition and left it on the column.
                    .offset(x: -(Self.cell + 12 + 14),
                            y: Self.inset + CGFloat(row) * (Self.rowHeight + Self.rowGap)
                                + Self.rowHeight / 2 - LetterTile.height / 2)
                    .animation(.easeOut(duration: 0.15), value: row)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .tvFocusSection()
    }
}

/// The letter the grid is on, big enough to read across a room, with the
/// clicks that move a letter at a time either side of it.
private struct LetterTile: View {
    static let height = CGFloat(116).scaled
    let letter: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "chevron.up").font(.app(14, .bold)).opacity(0.7)
            Text(verbatim: letter).font(.app(46, .heavy))
            Image(systemName: "chevron.down").font(.app(14, .bold)).opacity(0.7)
        }
        .foregroundStyle(.white)
        .frame(width: CGFloat(78).scaled, height: Self.height)
        .background(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}

/// A white disc when highlighted, like every control; the letter the grid is
/// on filled with the theme's colour and glowing; the rest quiet.
private struct IndexLetterStyle: ButtonStyle {
    let current: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : (current ? Color.white : Color.white.opacity(0.55)))
            .background {
                Circle()
                    .fill(focused ? AnyShapeStyle(Color.white)
                          : current ? AnyShapeStyle(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing))
                          : AnyShapeStyle(Color.clear))
                    .shadow(color: focused ? .black.opacity(0.4) : current ? Theme.primary.0.opacity(0.6) : .clear,
                            radius: focused ? 10 : 8, y: focused ? 4 : 0)
            }
            .scaleEffect(focused ? 1.3 : (configuration.isPressed ? 0.9 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
            .animation(.easeOut(duration: 0.15), value: current)
    }
}

// MARK: - Library filters

enum LibrarySort: String, CaseIterable, Identifiable, Codable {
    case title = "Title"
    case added = "Recently Added"
    case released = "Release Date"
    case played = "Date Played"
    case rating = "Rating"
    case critics = "Critics"
    case runtime = "Runtime"
    case random = "Random"

    var id: String { rawValue }

    /// The name shown in the sort menu. The raw value is saved in pins, so it stays English.
    var label: String {
        switch self {
        case .title: return String(localized: "Title", comment: "Sort order: by title")
        case .added: return String(localized: "Recently Added", comment: "Sort order")
        case .released: return String(localized: "Release Date", comment: "Sort order")
        case .played: return String(localized: "Date Played", comment: "Sort order: by when the viewer last watched it")
        case .rating: return String(localized: "Rating", comment: "Sort order: by rating")
        case .critics: return String(localized: "Critics' Score", comment: "Sort order: by the critics' score")
        case .runtime: return String(localized: "Runtime", comment: "Sort order: by length")
        case .random: return String(localized: "Random", comment: "Sort order: a random selection")
        }
    }

    /// Which way round, in the sort's own terms: A to Z, newest first.
    func order(reversed: Bool) -> String {
        switch self {
        case .title:
            return reversed ? String(localized: "Z to A", comment: "Sort direction for titles")
                            : String(localized: "A to Z", comment: "Sort direction for titles")
        case .added, .released:
            return reversed ? String(localized: "Oldest First", comment: "Sort direction for dates")
                            : String(localized: "Newest First", comment: "Sort direction for dates")
        case .played:
            return reversed ? String(localized: "Least Recent First", comment: "Sort direction for when something was last watched")
                            : String(localized: "Most Recent First", comment: "Sort direction for when something was last watched")
        case .rating, .critics:
            return reversed ? String(localized: "Lowest First", comment: "Sort direction for ratings")
                            : String(localized: "Highest First", comment: "Sort direction for ratings")
        case .runtime:
            return reversed ? String(localized: "Longest First", comment: "Sort direction for running time")
                            : String(localized: "Shortest First", comment: "Sort direction for running time")
        case .random:
            return ""
        }
    }

    /// The server's SortBy / SortOrder values, the usual way round.
    var api: (String, String) {
        switch self {
        case .title: return ("SortName", "Ascending")
        case .added: return ("DateCreated,SortName", "Descending")
        case .released: return ("PremiereDate,ProductionYear,SortName", "Descending")
        case .played: return ("DatePlayed,SortName", "Descending")
        case .rating: return ("CommunityRating,SortName", "Descending")
        case .critics: return ("CriticRating,SortName", "Descending")
        case .runtime: return ("Runtime,SortName", "Ascending")
        case .random: return ("Random", "Ascending")
        }
    }
}

struct LibraryFilters: Codable, Hashable {
    var sort: LibrarySort = .title
    /// The sort the other way round from its usual: Z to A, oldest first.
    var reversed = false
    /// Titles in any of these.
    var genres: Set<String> = []
    /// Decades, by their first year (1990 for the 1990s).
    var decades: Set<Int> = []
    var unwatched = false
    var favorites = false
    /// TV libraries only: list episodes themselves rather than shows.
    var episodes = false
    /// TV libraries only: these shows and no others (or their episodes), by
    /// id, with their names for the chip and a pinned view's name.
    var shows: [String: String] = [:]

    init() {}

    /// Written by hand so pins saved before a filter existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = try c.decodeIfPresent(LibrarySort.self, forKey: .sort) ?? .title
        reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        genres = try c.decodeIfPresent(Set<String>.self, forKey: .genres) ?? []
        decades = try c.decodeIfPresent(Set<Int>.self, forKey: .decades) ?? []
        unwatched = try c.decodeIfPresent(Bool.self, forKey: .unwatched) ?? false
        favorites = try c.decodeIfPresent(Bool.self, forKey: .favorites) ?? false
        episodes = try c.decodeIfPresent(Bool.self, forKey: .episodes) ?? false
        shows = try c.decodeIfPresent([String: String].self, forKey: .shows) ?? [:]
        // Pins from when a library took one genre.
        if genres.isEmpty, let genre = try decoder.container(keyedBy: OneGenre.self)
            .decodeIfPresent(String.self, forKey: .genre) {
            genres = [genre]
        }
    }

    private enum OneGenre: String, CodingKey { case genre }

    /// Episodes of a set of shows, asked for a show at a time: Episodes and
    /// Favourites together (the favourite shows' episodes, not only the
    /// episodes that are favourites themselves), or Episodes with shows chosen.
    var episodesByShow: Bool { episodes && (favorites || !shows.isEmpty) }

    /// Whether anything leaves titles out (or lists episodes instead).
    var narrows: Bool {
        !genres.isEmpty || !decades.isEmpty || unwatched || favorites || episodes || !shows.isEmpty
    }

    /// The chosen shows' names, A to Z.
    var showList: [String] {
        shows.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The server's SortBy / SortOrder values, this way round.
    var sortAPI: (String, String) {
        let (sortBy, order) = sort.api
        guard reversed, sort != .random else { return (sortBy, order) }
        return (sortBy, order == "Ascending" ? "Descending" : "Ascending")
    }

    /// Every year in the chosen decades.
    var years: [Int] {
        decades.sorted().flatMap { $0..<($0 + 10) }
    }

    /// The genres in alphabetical order, for names and labels.
    var genreList: [String] { genres.sorted() }

    /// "1990s", in the viewer's language.
    static func decadeName(_ decade: Int) -> String {
        String(localized: "\(String(decade))s", comment: "A decade, from its first year: 1990s")
    }
}

extension MediaServer {
    /// A library listed with filters, as its grid lists it: a page of the grid,
    /// or the first titles of a pinned view's row on Home.
    func listing(of library: BaseItem, filters requested: LibraryFilters, recordings: Bool,
                 startIndex: Int, limit: Int, before letter: String? = nil) async throws -> ItemsResult {
        // Episodes of the favourite shows, or the chosen ones, take more than
        // one question to the server, and come all at once: everything from
        // `startIndex` on.
        if requested.episodesByShow {
            let all = try await showEpisodes(in: library.id, filters: requested)
            return ItemsResult(items: Array(all.dropFirst(startIndex)), totalRecordCount: all.count)
        }
        let listedTypes = recordings ? BaseItem.recordingTypes : library.listedTypes
        let (sortBy, order) = requested.sortAPI
        var flags: [String] = []
        if requested.unwatched { flags.append("IsUnplayed") }
        if requested.favorites { flags.append("IsFavorite") }
        // Recordings by when they were made come whole too, and are put in
        // that order here: the server knows when each was added, which is
        // when it ended, and for a show when its first was.
        if await LibraryGrid.byDay(requested, in: recordings), letter == nil {
            let all = try await self.recordings(in: library.id, itemTypes: listedTypes, genres: requested.genreList,
                                                years: requested.years, filters: flags)
            let newestFirst = all.sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
            let ordered = requested.reversed ? Array(newestFirst.reversed()) : newestFirst
            return ItemsResult(items: Array(ordered.dropFirst(startIndex)), totalRecordCount: ordered.count)
        }
        let itemTypes = requested.episodes ? "Episode" : listedTypes
        // Too many shows chosen for one address (the server takes about
        // 8 KB of one, each id 33 characters of it): the whole library, in
        // order, and only the chosen shows kept from it.
        if requested.shows.count > Self.idsAtOnce {
            let all = try await libraryItems(parentId: library.id, startIndex: 0, limit: 10_000,
                                             sortBy: sortBy, sortOrder: order,
                                             genres: requested.genreList, years: requested.years, filters: flags,
                                             itemTypes: itemTypes, nameLessThan: letter, ids: [])
            let kept = all.items.filter { requested.shows[$0.id] != nil }
            return ItemsResult(items: Array(kept.dropFirst(startIndex).prefix(limit)), totalRecordCount: kept.count)
        }
        return try await libraryItems(parentId: library.id, startIndex: startIndex,
                                      limit: limit, sortBy: sortBy, sortOrder: order,
                                      genres: requested.genreList, years: requested.years, filters: flags,
                                      itemTypes: itemTypes, nameLessThan: letter, ids: Array(requested.shows.keys))
    }

    /// The most titles asked for by id in one question to the server.
    static var idsAtOnce: Int { 150 }

    /// A TV library's episodes from the shows chosen in the filters, or the
    /// shows marked as favourites (with any episode marked as one itself), or
    /// both: what Episodes asks for with either. The server can only be asked
    /// for episodes that are favourites themselves, and marking a show marks
    /// none of its episodes, so asked that way a favourite show's episodes
    /// never came; and it has no asking for the episodes of several shows.
    ///
    /// They are asked for a show at a time instead and put in order here, all
    /// of them at once: there is no asking the server for the second hundred
    /// of a list it never made. By title that is a show at a time, A to Z,
    /// each in the order it aired; by anything else, every show's together.
    func showEpisodes(in libraryId: String, filters: LibraryFilters) async throws -> [BaseItem] {
        let (sortBy, order) = filters.sortAPI
        let flags = filters.unwatched ? ["IsUnplayed"] : []
        let chosen = Array(filters.shows.keys)
        var shows = try await libraryItems(parentId: libraryId, startIndex: 0, limit: 5000,
                                           sortBy: "SortName",
                                           sortOrder: filters.sort == .title ? order : "Ascending",
                                           genres: [], years: [], filters: filters.favorites ? ["IsFavorite"] : [],
                                           itemTypes: "Series", nameLessThan: nil,
                                           ids: chosen.count > Self.idsAtOnce ? [] : chosen).items
        if !chosen.isEmpty { shows = shows.filter { filters.shows[$0.id] != nil } }
        var byShow = Array(repeating: [BaseItem](), count: shows.count)
        // Six shows at a time: asked for forty at once, a server is slow with all of them.
        for first in stride(from: 0, to: shows.count, by: 6) {
            try await withThrowingTaskGroup(of: (Int, [BaseItem]).self) { group in
                for index in first..<Swift.min(first + 6, shows.count) {
                    let show = shows[index].id
                    group.addTask {
                        let episodes = try await self.libraryItems(
                            parentId: show, startIndex: 0, limit: 5000, sortBy: sortBy, sortOrder: order,
                            genres: filters.genreList, years: filters.years, filters: flags,
                            itemTypes: "Episode", nameLessThan: nil)
                        return (index, episodes.items)
                    }
                }
                for try await (index, episodes) in group { byShow[index] = episodes }
            }
        }
        var all = Array(byShow.joined())
        // Episodes marked themselves, from shows that aren't: after the shows
        // (and only the chosen shows', where there are some).
        if filters.favorites {
            let marked = try await libraryItems(parentId: libraryId, startIndex: 0, limit: 1000,
                                                sortBy: sortBy, sortOrder: order,
                                                genres: filters.genreList, years: filters.years,
                                                filters: flags + ["IsFavorite"],
                                                itemTypes: "Episode", nameLessThan: nil).items
            var seen = Set(all.map(\.id))
            all += marked.filter { episode in
                (chosen.isEmpty || filters.shows[episode.seriesId ?? ""] != nil) && seen.insert(episode.id).inserted
            }
        }

        let descending = order == "Descending"
        switch filters.sort {
        case .title: return all
        case .random: return all.shuffled()
        case .added: return all.inOrder(descending: descending) { $0.dateCreated }
        case .released:
            return all.inOrder(descending: descending) { $0.premiereDate ?? $0.productionYear.map(String.init) }
        case .played: return all.inOrder(descending: descending) { $0.userData?.lastPlayedDate }
        case .rating: return all.inOrder(descending: descending) { $0.communityRating }
        case .critics: return all.inOrder(descending: descending) { $0.criticRating }
        case .runtime: return all.inOrder(descending: descending) { $0.runTimeTicks }
        }
    }
}

private extension Array where Element == BaseItem {
    /// Sorted as the server sorts a list, by one of its values (its dates are
    /// ISO 8601, which sort as text). Titles without the value go last, and
    /// those that tie keep the order they came in.
    func inOrder<Key: Comparable>(descending: Bool, by key: (BaseItem) -> Key?) -> [BaseItem] {
        enumerated().sorted { one, other in
            switch (key(one.element), key(other.element)) {
            case let (a?, b?) where a != b: return descending ? a > b : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return one.offset < other.offset
            }
        }.map(\.element)
    }
}

struct FilterChipLabel: View {
    let icon: String
    let text: String
    var menu = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.app(15, .semibold))
            Text(text)
            if menu {
                Image(systemName: "chevron.down")
                    .font(.app(12, .bold))
                    .opacity(0.6)
            }
        }
    }
}


/// Collections and playlists: the groupings made on the server rather than
/// found in the folders. They hold items and open like a library does, so they
/// are listed the same way.
struct CollectionsView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath

    @State private var collections: [BaseItem] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Somewhere for focus to wait when the menu hands it
                        // over, as the libraries' own placeholder is.
                        .focusable()
                } else if collections.isEmpty {
                    VStack(spacing: 10) {
                        Text("No collections yet")
                            .font(.app(26, .bold))
                        Text("Collections and playlists made on your \(app.serverFlavor.label) server show up here.")
                            .font(.app(18))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                } else {
                    LibraryPickerGrid(title: String(localized: "Collections"), libraries: collections)
                }
            }
            .sectionDestinations()
        }
        .sectionNavigation(path: $path, section: "collections")
        .task {
            guard !loaded, let client = app.client else { return }
            collections = (try? await client.videoCollections()) ?? []
            loaded = true
        }
        // Made or deleted from a long press, anywhere.
        .onReceive(NotificationCenter.default.publisher(for: .songPlaylistsChanged)) { _ in
            Task {
                guard let client = app.client, let found = try? await client.videoCollections() else { return }
                app.holdMenuFocus()
                collections = found
            }
        }
        .onChange(of: app.lastDeleted) { _, ids in
            let gone = Set(ids)
            if collections.contains(where: { gone.contains($0.id) }) { collections.removeAll { gone.contains($0.id) } }
        }
    }
}
