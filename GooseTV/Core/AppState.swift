import Foundation
import SwiftUI
#if os(tvOS)
import TVServices
#else
import WidgetKit
#endif

/// Persisted session + the phase the UI should show.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case serverSetup
        case login
        case main
    }

    /// Time to ask for a rating (see ReviewPrompt), once the player has closed.
    @Published var reviewDue = false

    @Published var phase: Phase = .serverSetup {
        didSet {
            #if os(iOS)
            // A film in its small window isn't part of the screens that go
            // when someone signs out or another viewer is chosen: it played
            // on over the sign-in screen, and under the next viewer.
            if phase != .main, oldValue == .main { PlayerStage.shared.askToClose() }
            #elseif os(macOS)
            // The same for the film's own window.
            if phase != .main, oldValue == .main { NotificationCenter.default.post(name: MacPlayerStage.closeAsked, object: nil) }
            #endif
        }
    }
    @Published private(set) var client: (any MediaServer)? {
        didSet {
            // A 401 still on its way for the account being replaced mustn't
            // sign out the one that replaced it.
            oldValue?.onUnauthorized = nil
            if let oldValue, oldValue !== client {
                MusicPlayer.shared.stop()
                MusicFavorites.shared.reset()
            }
            client?.onUnauthorized = { [weak self] in
                Task { @MainActor in self?.sessionExpired() }
            }
            // The Seerr connected for this server, if one was. The menu is
            // told when its Requests row comes or goes, and kept from taking
            // focus as the section's own page comes up in place of an offer.
            requests.changed = { [weak self] arriving in
                if arriving { self?.holdMenuFocus() }
                self?.objectWillChange.send()
            }
            requests.restore(for: client)
        }
    }
    /// Asking for titles through Seerr (see `Requests`).
    let requests = Requests()
    /// Shown on the sign-in screen when the server stopped accepting the saved sign-in.
    @Published private(set) var signInNotice: String?
    @Published var serverName: String?
    @Published var userName: String?
    /// Which server family this session is talking to, for the copy that names it.
    var serverFlavor: ServerFlavor { client?.flavor ?? .jellyfin }
    /// Filter shortcuts the user pinned to the menu.
    @Published private(set) var pins: [PinnedFilter] = []
    /// Next Up episodes the viewer took off the shelf, oldest first. Kept on
    /// this Apple TV, per viewer: neither server has a way to hide a show from
    /// Next Up. Hidden by episode, so a show comes back once more of it is
    /// watched and a different episode is next.
    private(set) var hiddenNextUp: [String] = []
    private var hiddenNextUpSet: Set<String> = []
    /// The menu's sections in the user's chosen order.
    @Published private(set) var menuSections = MenuSection.allCases
    /// The tabs along the foot of a phone's screen, in order, by `TabChoice`
    /// id: up to `mostTabs`, with Menu always after them. Each viewer's own,
    /// as the menu is.
    @Published private(set) var tabBar = AppState.defaultTabs
    static let defaultTabs = ["home", "libraries", "search", "downloads"]
    static let mostTabs = 4
    /// Whether the account has anything to list under Favourites and under
    /// Collections. The menu shows those sections only when it has; both are
    /// false until the first check.
    @Published private(set) var hasFavorites = false
    @Published private(set) var hasCollections = false
    /// Whether this account may make collections and change them: one that
    /// runs the server, or one it allows to (see `canManageCollections`).
    @Published private(set) var managesCollections = false
    /// Whether there's a film on the watchlist: its section is in the menu
    /// only then, as Favourites is.
    @Published private(set) var hasWatchlist = false
    /// Whether the server has television channels for this account: a tuner
    /// set up there (an HDHomeRun, an IPTV list), and the account let at it.
    @Published private(set) var hasLiveTV = false
    /// How many, for Settings to say.
    private(set) var liveChannelCount = 0
    /// The viewer's own say on it (Settings, Live TV): off, the menu has no
    /// Live TV row on this device, whatever the server has. Kept on the
    /// device, as the Home screen shelf's switch is.
    @Published var showsLiveTV: Bool = UserDefaults.standard
        .object(forKey: AppState.liveTVKey) as? Bool ?? true {
        didSet { defaults.set(showsLiveTV, forKey: Self.liveTVKey) }
    }
    /// And on Home's row of what's on the channels now (Settings, Live TV):
    /// off, Home has no such row. On the device too.
    @Published var showsOnNow: Bool = UserDefaults.standard
        .object(forKey: AppState.onNowKey) as? Bool ?? true {
        didSet { defaults.set(showsOnNow, forKey: Self.onNowKey) }
    }
    /// Whether a channel is kept on the device as it's watched, to be held
    /// and gone back through (Settings, Live TV): off, it's shown as it's
    /// broadcast and nothing of it is kept. Read where a channel starts
    /// (`LiveBuffer`), so it takes hold from the next one.
    @Published var keepsLiveTV: Bool = UserDefaults.standard
        .object(forKey: LiveBuffer.switchKey) as? Bool ?? true {
        didSet { defaults.set(keepsLiveTV, forKey: LiveBuffer.switchKey) }
    }
    /// Home's rows as the viewer has arranged them (Settings, Home Screen):
    /// the order they stand in, and the ones switched off, each by its
    /// row's name (see `HomeLayout`). Kept on the device. A row the order
    /// doesn't mention, a library added since, comes after those it does.
    @Published var homeOrder: [String] = UserDefaults.standard.stringArray(forKey: AppState.homeOrderKey) ?? [] {
        didSet { defaults.set(homeOrder, forKey: Self.homeOrderKey) }
    }
    @Published var homeHidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: AppState.homeHiddenKey) ?? []) {
        didSet { defaults.set(Array(homeHidden), forKey: Self.homeHiddenKey) }
    }

    /// Whether Home shows a row. What's on now has a switch of its own in
    /// Settings, Live TV, and this is the same one.
    func homeShows(_ row: String) -> Bool {
        if let pin = HomeLayout.pinId(row) { return pins.first { $0.id == pin }?.onHome ?? false }
        return row == HomeLayout.onNow ? showsOnNow : !homeHidden.contains(row)
    }

    func setHome(_ row: String, shown: Bool) {
        if let pin = HomeLayout.pinId(row) {
            // Kept, even in neither place: the page lists it switched off,
            // as it does every row, to be switched on again.
            setPin(pin, onHome: shown, keepsPin: true)
        } else if row == HomeLayout.onNow {
            if showsOnNow != shown { showsOnNow = shown }
        } else if shown {
            homeHidden.remove(row)
        } else {
            homeHidden.insert(row)
        }
    }

    /// Counted up to ask for the Live TV section from somewhere else: the
    /// See all at the end of Home's row.
    @Published private(set) var liveTVAsks = 0

    func askForLiveTV() { liveTVAsks += 1 }

    /// A section asked for by name from outside the menu (the Mac's Go menu and
    /// Settings… command): "home", "search", "libraries", "livetv", "favorites",
    /// "watchlist", "collections", "requests", "together", "downloads", "settings",
    /// the names GOOSETV_TAB takes. Each ask is new, the same name twice included.
    struct SectionAsk: Equatable {
        let name: String
        let serial: Int
    }
    @Published private(set) var sectionAsk = SectionAsk(name: "", serial: 0)

    func askForSection(_ name: String) { sectionAsk = SectionAsk(name: name, serial: sectionAsk.serial + 1) }

    /// Counted up to ask for Settings, Home Screen, from a Home with nothing
    /// on it.
    @Published private(set) var homeSettingsAsks = 0
    /// Whether Settings is still to open that page: taken by Settings as it
    /// comes on screen.
    var homeSettingsWanted = false

    func askForHomeSettings() {
        homeSettingsWanted = true
        homeSettingsAsks += 1
    }
    /// The user's movie/show libraries — fetched once per sign-in and shared
    /// by the sidebar, Home, and the Libraries screen.
    @Published private(set) var libraries: [BaseItem] = []
    /// Bumped whenever an item's watched / favorite / resume state changes from
    /// a long-press menu, so screens showing that state can reload.
    @Published private(set) var userDataRevision = 0
    /// Bumped when an audiobook is marked finished or not: the audiobook
    /// screens reload for that alone, not for every song starred or film
    /// watched (a library of them is thousands of files to ask for).
    @Published private(set) var audiobookRevision = 0
    /// True for a moment while content is swapped out from under focus (a screen
    /// popping, a shelf reloading). The sidebar is unfocusable meanwhile, so the
    /// focus engine's fallback lands in the content instead of opening the menu.
    /// Watched by the menu alone: published here, setting it and clearing it
    /// redrew every screen that watches the app, twice, each time it was used.
    let menuHold = MenuFocusHold()
    var menuFocusHeld: Bool { menuHold.held }
    /// The screens under the current sign-in screen, most recent last; back
    /// walks through them. Switching user or server from Settings leaves the
    /// saved session in place, so backing all the way out returns to it.
    @Published private(set) var authTrail: [Phase] = []
    /// Set when backing out of a switch that started in Settings, so the main
    /// screen reopens there rather than on Home.
    var reopenSettings = false
    /// Whether the switch under way started in Settings, rather than from the
    /// Apple TV menu's top row, which can be chosen from any screen.
    private var switchBeganInSettings = true
    /// Waiting to be opened, because someone chose it on the Apple TV home
    /// screen. Home clears it once it has acted; it survives a cold launch,
    /// where the URL arrives well before there is a screen to show it on.
    @Published var openedFromShelf: DeepLink.Opened?
    /// Whether the Apple TV home screen shows Continue Watching and Next Up
    /// above the app. Kept here rather than only in the shared session, so
    /// signing out doesn't forget the answer.
    @Published var showsOnHomeScreen: Bool = UserDefaults.standard
        .object(forKey: AppState.homeScreenKey) as? Bool ?? true {
        didSet {
            defaults.set(showsOnHomeScreen, forKey: Self.homeScreenKey)
            SharedSession.setShowsOnHomeScreen(showsOnHomeScreen)
            shelfChanged()
        }
    }
    /// The signed-in user's account preferences on the server; nil until first loaded.
    @Published private(set) var preferences: UserPreferences?
    /// Whether this account may change libraries and server settings.
    @Published private(set) var isAdmin = false
    /// Whether the server lets this account look for subtitles on the
    /// internet. Not published: only the player asks, as its controls open.
    private(set) var findsSubtitles = false
    /// The colour scheme. Setting it repaints the app and remembers the choice.
    @Published var theme: AppTheme = Theme.selected {
        didSet {
            defaults.set(theme.rawValue, forKey: AppTheme.storageKey)
            wear()
        }
    }
    /// Whether the Requests section is the one on show. It wears a scheme of
    /// its own, wallpaper, menu and all, so that asking for what the server
    /// hasn't got can't be taken for browsing what it has.
    @Published var inRequests = false {
        didSet { wear() }
    }
    /// Which scheme that is. Kept on this device, as the app's own is.
    @Published var requestsScheme = RequestsScheme(stored: UserDefaults.standard.string(forKey: RequestsScheme.storageKey)) {
        didSet {
            defaults.set(requestsScheme.stored, forKey: RequestsScheme.storageKey)
            wear()
        }
    }
    /// The scheme being worn now: the Requests section's while it's on show,
    /// and otherwise the one chosen in Appearance.
    var shownTheme: AppTheme { inRequests ? requestsScheme.theme(beside: theme) : theme }

    private func wear() {
        if Theme.selected != shownTheme { Theme.selected = shownTheme }
    }

    private var librariesFetch: Task<[BaseItem], Never>?
    private var menuHoldToken = 0
    private var menuLeaveToken = 0
    private let defaults = UserDefaults.standard
    private static let flavorKey = "goosetv.serverFlavor"
    private static let homeScreenKey = "goosetv.homeScreenShelf"
    private static let liveTVKey = "goosetv.liveTV.shown"
    private static let onNowKey = "goosetv.liveTV.onNow"
    static let homeOrderKey = "goosetv.home.order"
    static let homeHiddenKey = "goosetv.home.hidden"
    /// The most episodes kept off Next Up; the oldest go after.
    static let mostHiddenNextUp = 200

    /// The app's one, for what can't be handed it: Siri's requests.
    private(set) static weak var current: AppState?

    init() {
        restore()
        Self.current = self
        // Settings another device changed, as iCloud brings them.
        syncObserver = NotificationCenter.default.addObserver(forName: SettingsSync.changed, object: nil, queue: .main) { [weak self] note in
            let keys = note.userInfo?["keys"] as? [String] ?? []
            MainActor.assumeIsolated { self?.syncedSettingsChanged(keys) }
        }
        SettingsSync.shared.start()
    }

    private var syncObserver: NSObjectProtocol?

    /// Settings come from another device (`SettingsSync`): the ones held
    /// here read again. The rest are read as they're used, or watched by
    /// the pages that show them.
    private func syncedSettingsChanged(_ keys: [String]) {
        // Not the colour schemes: each device keeps its own.
        if keys.contains(Self.homeOrderKey) { homeOrder = defaults.stringArray(forKey: Self.homeOrderKey) ?? [] }
        if keys.contains(Self.homeHiddenKey) { homeHidden = Set(defaults.stringArray(forKey: Self.homeHiddenKey) ?? []) }
        // This account's pins, menu, libraries' order and Next Up.
        if let user = defaults.string(forKey: "goosetv.userId"), keys.contains(where: { $0.hasSuffix("." + user) }) {
            loadMenu(for: user)
            SharedSession.setHiddenNextUp(hiddenNextUp)
            libraries = inSavedOrder(libraries)
        }
    }

    /// Something's watched mark, resume point, favourite or place on the
    /// watchlist changed. A favourite can change what the menu lists, so
    /// that asks again whether Favourites has anything in it; and so can
    /// the watchlist, which a film also leaves by being watched, so while
    /// there's anything on it any change asks again.
    func userDataChanged(favorites: Bool = false, watchlist: Bool = false, audiobooks: Bool = false) {
        if audiobooks { audiobookRevision += 1 }
        userDataRevision += 1
        shelfChanged()
        if favorites { Task { await refreshFavorites() } }
        if watchlist || hasWatchlist { Task { await refreshWatchlist() } }
    }

    /// Whether Favourites, the watchlist and Collections have anything to
    /// list, and the server any television to watch.
    func refreshMenuContents() async {
        async let favorites: Void = refreshFavorites()
        async let watchlist: Void = refreshWatchlist()
        async let liveTV: Void = refreshLiveTV()
        async let together: Void = refreshWatchTogether()
        await refreshCollections()
        await favorites
        await watchlist
        await liveTV
        await together
    }

    /// Whether this account may watch together here, for the menu's row;
    /// and, on an Apple TV, the server told it can be played on from
    /// another device. Both over the one connection (`ServerLink`).
    func refreshWatchTogether() async {
        guard let client else { return }
        ServerLink.shared.use(client)
        async let remote: Void = RemoteControl.shared.use(client)
        await SyncPlay.shared.use(client)
        await remote
    }

    /// A server with no tuner answers with no channels, which is the same as
    /// having no Live TV; one that doesn't know the question (an old one, or
    /// one with Live TV locked away) fails, and changes nothing.
    func refreshLiveTV() async {
        guard let client, let count = try? await client.liveChannelCount(), client === self.client else { return }
        liveChannelCount = count
        if hasLiveTV != (count > 0) { hasLiveTV = count > 0 }
        // Where its recordings are kept, and whether this account may
        // delete them.
        let folders = count > 0 ? await client.liveRecordingFolders() : []
        if client === self.client, folders != recordingFolders { recordingFolders = folders }
        let deletable = count > 0 ? await client.liveDeletableLibraries() : []
        if client === self.client, deletable != recordingLibraries { recordingLibraries = deletable }
        let records = count > 0 ? await client.liveCanRecord() : false
        if client === self.client { liveCanRecord = records }
    }

    /// Whether this account may set the server to record, for a card away
    /// from the guide to offer it (Home's row of what's on). Nothing is
    /// drawn from it: it's read as a card's menu is asked for.
    private(set) var liveCanRecord = false
    /// Counts the recordings set or taken off from such a card, for the row
    /// to be read again: the server says which of what's on it is recording.
    @Published private(set) var liveRecordingChanges = 0

    func liveRecordingChanged() { liveRecordingChanges += 1 }

    /// The libraries the server records into, where this account may delete
    /// a recording: a long press on one of theirs offers to (see
    /// `ItemMenuHost`). Empty where it may not, or there's no television.
    @Published private(set) var recordingLibraries: Set<String> = []
    /// The libraries the server records into, whoever may delete from them:
    /// their grids say when each recording was made, and file them by day.
    @Published private(set) var recordingFolders: Set<String> = []
    /// The shows seen in those libraries: a show's page doesn't know where
    /// it was come to from, and its episodes are recordings to be deleted
    /// one at a time only where the show is one of these. Nothing is drawn
    /// from it.
    var recordedShows: Set<String> = []
    /// The guide's pictures of programmes, for the recordings of them.
    let guideArt = GuideArt()

    /// What heads a recording, which has no backdrop: the guide's picture of
    /// the programme, or failing that the frame the server took from the
    /// file. Nil for anything that isn't a recording or has a backdrop.
    /// Asked of the server the once for each item.
    func recordingCover(for item: BaseItem) async -> RecordingCover? {
        if let known = recordingCovers[item.id] { return known }
        // Found nothing a moment ago: not asked again straight away, but not
        // never either. The guide may list the programme again by then.
        if let missed = coverMisses[item.id], Date().timeIntervalSince(missed) < 600 { return nil }
        // No server with Live TV has been found to keep recordings: nothing is
        // asked. Nor for a title with artwork of its own; a backdrop alone may
        // be a frame the server took from a recording, which the programme's
        // own picture is better than.
        guard let client, !recordingFolders.isEmpty,
              client.imageURL(for: item, type: "Backdrop", maxWidth: 100) == nil || item.lacksPoster else { return nil }
        let place = await client.recordingPlace(item.id, among: recordingFolders)
        // Called off (its card scrolled away): the answer is the failed
        // request's, not the server's, and isn't kept.
        guard client === self.client, !Task.isCancelled else { return nil }
        // Something else with no backdrop: remembered too, so it's asked the once.
        guard place.isRecording else {
            recordingCovers[item.id] = .some(nil)
            return nil
        }
        var cover: RecordingCover?
        // The show or film itself, where the library has it: its backdrop
        // and logo, as its own page has them. A recording of a show is by
        // the show's name; one with no series may be a film.
        let name = item.showName ?? ""
        var title = await libraryTitle(named: name, film: false)
        if title == nil, item.seriesName == nil { title = await libraryTitle(named: name, film: true) }
        if let title, let backdrop = client.imageURL(for: title, type: "Backdrop", maxWidth: 2000) {
            cover = RecordingCover(url: backdrop, shape: 16.0 / 9, title: title)
        } else if let folder = place.pictured, let url = client.imageURL(for: folder, maxWidth: 1280) {
            // The programme's own picture, kept with the recording as it was
            // made: there however long ago it aired, as the guide's isn't.
            cover = RecordingCover(url: url, shape: folder.primaryImageAspectRatio ?? 4.0 / 3)
        } else if let listed = await guideArt.find(item.showName, with: client),
           let url = client.imageURL(for: listed, maxWidth: 1280) {
            cover = RecordingCover(url: url, shape: listed.primaryImageAspectRatio ?? 4.0 / 3)
        } else if let url = client.imageURL(for: item, maxWidth: 1280) {
            cover = RecordingCover(url: url, shape: item.primaryImageAspectRatio ?? 16.0 / 9)
        } else if let fresh = try? await client.item(id: item.id),
                  let url = client.imageURL(for: fresh, maxWidth: 1280) {
            // The copy in hand was listed before the server had given the
            // recording a picture (it does a while after adding it): asked
            // for again, it has one.
            cover = RecordingCover(url: url, shape: fresh.primaryImageAspectRatio ?? 16.0 / 9)
        }
        guard client === self.client, !Task.isCancelled else { return nil }
        if let cover { recordingCovers[item.id] = .some(cover) } else { coverMisses[item.id] = Date() }
        return cover
    }

    /// The library's own show or film for a programme on television, to show
    /// it at the top of Home as its page would: by the programme's name, the
    /// once. Nil where the library hasn't it.
    func libraryTitle(for program: LiveProgram) async -> BaseItem? {
        await libraryTitle(named: program.name, film: program.isMovie)
    }

    func libraryTitle(named name: String, film: Bool) async -> BaseItem? {
        let key = (film ? "film|" : "show|") + name.lowercased()
        if let known = libraryTitles[key] { return known }
        guard let client, !name.isEmpty else { return nil }
        let found = await client.libraryTitle(named: name, film: film)
        guard client === self.client, !Task.isCancelled else { return nil }
        libraryTitles[key] = .some(found)
        return found
    }

    /// The same, where it has been asked: `.some(nil)` where the library
    /// hasn't it, nil where nobody has asked yet.
    func knownLibraryTitle(for program: LiveProgram) -> BaseItem?? {
        libraryTitles[(program.isMovie ? "film|" : "show|") + program.name.lowercased()]
    }

    private var libraryTitles: [String: BaseItem?] = [:]

    /// The same, where it has been asked already: for a screen that can't wait.
    func knownRecordingCover(for item: BaseItem) -> RecordingCover? {
        recordingCovers[item.id] ?? nil
    }

    private var recordingCovers: [String: RecordingCover?] = [:]
    /// When each recording last turned up no picture at all.
    private var coverMisses: [String: Date] = [:]
    /// The items last deleted from here, for a screen showing them to drop
    /// them without waiting to hear from the server.
    @Published private(set) var lastDeleted: [String] = []

    func deleted(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lastDeleted = ids
        userDataChanged()
    }

    // Each asks for one item, which is all it takes to know whether a section
    // has anything in it. A failed check changes nothing, so a server hiccup
    // doesn't make a section vanish; and an unchanged answer isn't written,
    // since every write redraws the whole app.

    private func refreshFavorites() async {
        guard let client, let found = try? await client.favorites(limit: 1), client === self.client else { return }
        if hasFavorites == found.isEmpty { hasFavorites = !found.isEmpty }
    }

    /// Takes off the watchlist whichever of these films has now been watched,
    /// as marking one watched does. The list is kept as a mark on the film,
    /// which watching it doesn't lift: left on, it only hid the film, and
    /// one made unwatched again later was back on a list it had left.
    func leaveWatchlist(watched films: Set<String>) async {
        guard let client else { return }
        for id in films {
            guard let now = try? await client.item(id: id), now.userData?.played == true,
                  now.userData?.likes == true, client === self.client else { continue }
            try? await client.setWatchlisted(id, false)
        }
    }

    private func refreshWatchlist() async {
        guard let client, let found = try? await client.watchlist(limit: 1), client === self.client else { return }
        if hasWatchlist == found.isEmpty { hasWatchlist = !found.isEmpty }
    }

    private func refreshCollections() async {
        // Playlists of songs are music's, not a reason for the row.
        guard let client, let found = try? await client.videoCollections(), client === self.client else { return }
        if hasCollections == found.isEmpty { hasCollections = !found.isEmpty }
        let manages = await client.canManageCollections()
        if client === self.client, manages != managesCollections { managesCollections = manages }
    }

    /// A playlist or a collection was made or deleted here: the menu's
    /// Collections row comes or goes with the first and the last of them.
    func collectionsChanged() {
        Task { await refreshCollections() }
    }

    /// Whether a section has its row in the menu.
    func isShown(_ section: MenuSection) -> Bool {
        switch section {
        case .favorites: hasFavorites
        case .watchlist: hasWatchlist
        case .liveTV: hasLiveTV && showsLiveTV
        case .collections: hasCollections
        case .home, .libraries, .search: true
        }
    }

    /// Whether the menu has a Requests row: a Seerr is connected, or one was
    /// found and is on offer. It isn't one of the movable sections: it sits
    /// at the menu's foot, above Settings.
    var showsRequests: Bool { requests.client != nil || requests.offered != nil }

    /// A Seerr was connected or left: the menu gains or loses its row.
    func requestsChanged() { objectWillChange.send() }

    /// Bumped to have the menu take focus, on the row of the section on show:
    /// for a page left with nothing of its own to hold it.
    @Published private(set) var menuAsks = 0

    func askForMenu() { menuAsks += 1 }

    func holdMenuFocus() {
        menuHoldToken += 1
        let token = menuHoldToken
        if !menuHold.held { menuHold.held = true }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if token == menuHoldToken { menuHold.held = false }
        }
    }

    /// Out of the menu and into the page beside it: one of its rows was
    /// chosen. The menu can't hold focus while it's switched off, so focus
    /// goes to the page, and the menu closes behind it. It stays off until
    /// the page has something in focus: a page still loading has nothing to
    /// take it yet, and the menu switched back on would take focus back and
    /// open again. A page that never has anything is given up on after a few
    /// seconds.
    func leaveMenu() {
        #if os(tvOS)
        menuLeaveToken += 1
        let token = menuLeaveToken
        if !menuHold.leaving { menuHold.leaving = true }
        Task {
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard token == menuLeaveToken else { return }
                if !menuHold.menuFocused, Self.somethingHasFocus { break }
            }
            menuHold.leaving = false
        }
        #endif
    }

    #if os(tvOS)
    private static var somethingHasFocus: Bool {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        return window.flatMap { UIFocusSystem.focusSystem(for: $0) }?.focusedItem != nil
    }
    #endif

    private func restore() {
        #if DEBUG
        // GOOSETV_NEW_PROFILE=1: as someone opening the app for the first
        // time on an Apple TV whose household has used it (this person's own
        // session gone, what the TV's people share kept), to see a new
        // profile's welcome without a TV of profiles.
        if ProcessInfo.processInfo.environment["GOOSETV_NEW_PROFILE"] == "1" {
            for key in ["goosetv.serverURL", "goosetv.userId", "goosetv.userName", "goosetv.serverName"] {
                defaults.removeObject(forKey: key)
            }
            TokenStore.clear()
            SharedSession.clear()
        }
        #if os(macOS)
        // GOOSETV_STASH=1: a test run on a Mac that also has a real copy of the app, which
        // shares this one's saved data: the real copy's sign-in is put aside first, and
        // GOOSETV_STASH=back puts it back once the tests are done (and signed out).
        let stashed = ["goosetv.serverURL", "goosetv.userId", "goosetv.userName", "goosetv.serverName", Self.flavorKey]
        switch ProcessInfo.processInfo.environment["GOOSETV_STASH"] {
        case "1":
            if defaults.dictionary(forKey: "goosetv.debugStash") == nil {
                var stash: [String: Any] = [:]
                for key in stashed { if let value = defaults.object(forKey: key) { stash[key] = value } }
                if let token = TokenStore.token() { stash["token"] = token }
                defaults.set(stash, forKey: "goosetv.debugStash")
            }
            for key in stashed { defaults.removeObject(forKey: key) }
            TokenStore.clear()
        case "back":
            if let stash = defaults.dictionary(forKey: "goosetv.debugStash") {
                for key in stashed {
                    if let value = stash[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
                if let token = stash["token"] as? String { _ = TokenStore.save(token) }
                defaults.removeObject(forKey: "goosetv.debugStash")
            }
        default:
            break
        }
        #endif
        #endif
        guard let urlString = defaults.string(forKey: "goosetv.serverURL"),
              let url = URL(string: urlString) else { return welcome() }
        var token = TokenStore.token()
        // This person's settings kept and the token not: on an Apple TV, an
        // earlier version's token may be in the keychain the TV shares.
        if token == nil, let earlier = TokenStore.takeEarlier(), TokenStore.save(earlier) { token = earlier }
        let userId = defaults.string(forKey: "goosetv.userId")
        userName = defaults.string(forKey: "goosetv.userName")
        serverName = defaults.string(forKey: "goosetv.serverName")
        let flavor = ServerFlavor(rawValue: defaults.string(forKey: Self.flavorKey) ?? "") ?? .jellyfin
        client = MediaBrowserClient(baseURL: url, flavor: flavor, token: token, userId: userId)
        loadMenu(for: userId)
        phase = (token != nil && userId != nil) ? .main : .login
        // Fills in the shelf's copy for anyone who signed in before it existed.
        if let userId, let token {
            SharedSession.save(baseURL: url, flavor: flavor, userId: userId,
                               showsOnHomeScreen: showsOnHomeScreen, hiddenNextUp: hiddenNextUp)
            // And the list of accounts on this Apple TV, for anyone signed in
            // before there was one. Only when missing, so the order it keeps
            // (most recently used first) isn't disturbed by a launch.
            if !SavedAccounts.all().contains(where: { $0.serverURL == urlString && $0.userId == userId }) {
                SavedAccounts.remember(SavedAccount(serverURL: urlString, userId: userId,
                                                    name: userName ?? "", imageTag: nil, flavor: flavor),
                                       token: token)
            }
            // A session taken up without its name (see `welcome`), and not
            // named yet: the server asked again, at each launch until it has.
            if userName == nil { Task { await nameEarlierAccounts() } }
        }
    }

    /// Someone with no session of their own: on an Apple TV, a person opening
    /// the app for the first time, the app being run as each person using the
    /// TV. Signed in as before, where the session an earlier version kept is
    /// to be found (the one person who was signed in, on the first launch of
    /// this version); otherwise to the household's faces to pick from, on the
    /// server they last used. With neither, the server setup, as anywhere.
    private func welcome() {
        if let earlier = SharedSession.takeEarlier(), let token = TokenStore.takeEarlier() {
            defaults.set(earlier.url.absoluteString, forKey: "goosetv.serverURL")
            defaults.set(earlier.flavor.rawValue, forKey: Self.flavorKey)
            defaults.set(earlier.userId, forKey: "goosetv.userId")
            // What the session kept of this person's choices, which went
            // with their settings: the shelf left off, Next Up's hidden.
            if let shows = earlier.showsOnHomeScreen { showsOnHomeScreen = shows }
            if let hidden = earlier.hiddenNextUp { defaults.set(hidden, forKey: "goosetv.hiddenNextUp.\(earlier.userId)") }
            TokenStore.save(token)
            restore()
            return
        }
        guard let last = SavedAccounts.all().first, let url = URL(string: last.serverURL) else { return }
        serverName = SavedServers.all().first { $0.url == last.serverURL }?.name
        client = MediaBrowserClient(baseURL: url, flavor: last.flavor)
        phase = .login
    }

    /// After a session an earlier version kept is taken up: its name, which
    /// was kept with this person's settings and not with the session, and the
    /// household's other accounts that version left tokens for, by the name
    /// and picture the server gives each.
    private func nameEarlierAccounts() async {
        // The token is this session's, read before the asking: by the
        // answer, someone may have signed in as another account.
        guard let client = client as? MediaBrowserClient, let token = TokenStore.token(),
              let me = try? await client.signedInUser(), client === self.client else { return }
        if userName == nil {
            userName = me.name
            defaults.set(me.name, forKey: "goosetv.userName")
        }
        SavedAccounts.add(SavedAccount(serverURL: client.baseURL.absoluteString, userId: me.id, name: me.name,
                                       imageTag: me.primaryImageTag, flavor: client.flavor), token: token)
        // The server's name went with the settings too.
        if serverName == nil, let info = try? await client.publicInfo(), client === self.client {
            serverName = info.serverName
            defaults.set(info.serverName, forKey: "goosetv.serverName")
            SavedServers.remember(url: client.baseURL, name: info.serverName, flavor: client.flavor)
        }
        let known = Set(SavedAccounts.all().map(\.id))
        for (id, token) in SavedAccounts.householdTokens() where !known.contains(id) {
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = URL(string: parts[0]) else { continue }
            let other = MediaBrowserClient(baseURL: url, flavor: client.flavor, token: token, userId: parts[1])
            guard let user = try? await other.signedInUser() else { continue }
            SavedAccounts.add(SavedAccount(serverURL: parts[0], userId: user.id, name: user.name,
                                           imageTag: user.primaryImageTag, flavor: client.flavor), token: token)
        }
    }

    /// Opened from the Apple TV home screen. Held rather than acted on: a cold
    /// launch delivers this before Home exists, and Home is what can show it.
    func open(url: URL) {
        // jellygoose://section/<name>: a section by the name askForSection takes.
        if url.scheme == DeepLink.scheme, url.host == "section" {
            askForSection(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            return
        }
        #if os(macOS) && DEBUG
        // jellygoose://snap/<name>: a picture of the window, for a script (MacDebugSnapshots).
        if url.scheme == DeepLink.scheme, let host = url.host, ["snap", "click", "rightclick", "key", "signout", "closewindow", "windowsize", "dlalbum", "playgroup", "dlremove", "dlbook", "playbook", "dlquality", "dlitem", "dlitemremove", "nebaseline", "necheck", "neoff", "nowplaying", "livewatch", "seerrconnect", "appicon"].contains(host) {
            let arg = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch host {
            case "signout":
                // Before a real build goes onto the same Mac: it shares this one's saved
                // data, and would open signed in to the test server.
                signOut()
                for key in ["goosetv.serverURL", "goosetv.userId", "goosetv.userName", "goosetv.serverName"] {
                    defaults.removeObject(forKey: key)
                }
            case "dlalbum":
                // jellygoose://dlalbum/<album id>: downloaded as its page's button does.
                guard let client = client as? MediaBrowserClient else { return }
                Task {
                    let album = try? await client.item(id: arg)
                    let songs = (try? await client.tracks(of: arg, playlist: false)) ?? []
                    let problem = await Downloads.shared.download(group: arg, kind: .album, name: album?.displayTitle ?? arg,
                                                                  byLine: album?.byLine, pageId: arg, items: songs, art: album, client: client)
                    MacDebugSnapshots.log("dlalbum \(songs.count) songs: \(problem ?? "started")")
                }
            case "playgroup":
                // jellygoose://playgroup/<group id>: played from the device, as the Downloads page's row does.
                let items = Downloads.shared.groupItems(arg)
                if let client, !items.isEmpty { MusicPlayer.shared.play(items, source: arg, client: client) }
                MacDebugSnapshots.log("playgroup \(items.count) items")
            case "dlbook":
                // jellygoose://dlbook/<file or folder id>: a book downloaded as its page's button does.
                guard let client = client as? MediaBrowserClient else { return }
                Task {
                    let parts = (try? await Audiobooks.parts(of: BookRoute(id: arg), client: client)) ?? []
                    let name = parts.first?.album ?? parts.first?.displayTitle ?? arg
                    let problem = await Downloads.shared.download(group: arg, kind: .book, name: name, byLine: parts.first?.byLine,
                                                                  pageId: arg, items: parts, art: parts.first, client: client)
                    MacDebugSnapshots.log("dlbook \(parts.count) parts: \(problem ?? "started")")
                }
            case "playbook":
                // jellygoose://playbook/<group id>: carried on from the device, as the Downloads page's row does.
                let parts = Downloads.shared.groupItems(arg)
                if let client, !parts.isEmpty {
                    Audiobooks.play(parts, title: Downloads.shared.groups[arg]?.name ?? arg, client: client)
                    let point = Audiobooks.resumePoint(parts)
                    MacDebugSnapshots.log("playbook \(parts.count) parts from part \(point.index) at \(Int(point.seconds)) s")
                }
            case "nebaseline":
                // jellygoose://nebaseline/<days>: alerts on (without asking for
                // notifications), last looked so many days ago.
                guard let client = client as? MediaBrowserClient, let uid = client.userId else { return }
                UserDefaults.standard.set(true, forKey: NewEpisodes.enabledKey)
                let key = "goosetv.newEpisodes.\(client.baseURL.absoluteString)|\(uid)"
                UserDefaults.standard.set(Date().addingTimeInterval(-86_400 * (Double(arg) ?? 30)), forKey: key + ".since")
                UserDefaults.standard.removeObject(forKey: key + ".told")
                MacDebugSnapshots.log("new episodes: since \(arg) days ago")
            case "necheck":
                guard let client = client as? MediaBrowserClient else { return }
                Task { await NewEpisodes.shared.check(client: client); MacDebugSnapshots.log("new episodes: checked") }
            case "neoff":
                NewEpisodes.shared.turnOff()
                MacDebugSnapshots.log("new episodes: off")
            case "dlquality":
                // jellygoose://dlquality/<original|high|medium|low>: the Downloads page's choice.
                UserDefaults.standard.set(arg, forKey: PlaybackPreferences.downloadQualityKey)
                MacDebugSnapshots.log("download quality \(PlaybackPreferences.downloadQuality.rawValue)")
            case "dlitem":
                // jellygoose://dlitem/<id>: a film or episode downloaded as its page's button does.
                guard let client = client as? MediaBrowserClient else { return }
                Task {
                    guard let item = try? await client.item(id: arg) else { return MacDebugSnapshots.log("dlitem: no item") }
                    let problem = await Downloads.shared.download(item, client: client)
                    MacDebugSnapshots.log("dlitem \(item.displayTitle): \(problem ?? "started")")
                }
            case "dlitemremove":
                Downloads.shared.remove(arg)
            case "dlremove":
                Task { await Downloads.shared.remove(group: arg); MacDebugSnapshots.log("dlremove \(arg)") }
            case "windowsize":
                // jellygoose://windowsize/1280x800: the app's window at that size, for pictures of a set size.
                let size = arg.split(separator: "x").compactMap { Double($0) }
                if size.count == 2, let window = AppWindow.main {
                    var frame = window.frame
                    frame.origin.y += frame.height - size[1]
                    frame.size = NSSize(width: size[0], height: size[1])
                    window.setFrame(frame, display: true)
                }
            case "closewindow":
                // As its close button does: for checking the Dock brings a window back.
                AppWindow.main?.performClose(nil)
            case "nowplaying":
                // As a click on the mini player does.
                MusicPlayer.shared.showsNowPlaying = true
            case "livewatch":
                // As the Live TV corner's full-screen button does.
                NotificationCenter.default.post(name: MacDebugSnapshots.watchLive, object: nil)
            case "appicon":
                // jellygoose://appicon/<neon|playBeak|…|jellygoose>: chosen as Settings, Appearance does.
                guard let icon = AppIcon(rawValue: arg) else { return MacDebugSnapshots.log("appicon: no icon \(arg)") }
                Task {
                    let problem = await AppIcon.use(icon)
                    let dock = NSApplication.shared.applicationIconImage
                    MacDebugSnapshots.log("appicon \(arg): \(problem ?? "no problem"); now \(AppIcon.current.rawValue); dock image \(dock.map { "\(Int($0.size.width))pt" } ?? "-")")
                }
            case "seerrconnect":
                // As the Requests page's Connect button does, for the Seerr it offers.
                guard let offered = requests.offered else { return MacDebugSnapshots.log("seerrconnect: nothing offered") }
                Task {
                    do { try await requests.connect(to: offered.absoluteString); MacDebugSnapshots.log("seerrconnect: connected") }
                    catch { MacDebugSnapshots.log("seerrconnect: \(error)") }
                }
            case "snap": MacDebugSnapshots.snapNow(arg)
            case "key": MacDebugSnapshots.key(arg)
            default: MacDebugSnapshots.click(arg, right: host == "rightclick")
            }
            return
        }
        #endif
        guard let link = DeepLink.parse(url) else { return }
        openedFromShelf = link
    }

    /// Points at a new server and moves on to sign-in. Nothing is saved until a
    /// sign-in succeeds, so the current session survives backing out.
    func connect(to url: URL, flavor: ServerFlavor, serverName: String?) {
        client = MediaBrowserClient(baseURL: url, flavor: flavor)
        self.serverName = serverName
        open(.login)
    }

    func signedIn(_ auth: AuthenticationResult) {
        userName = auth.user.name
        defaults.set(client?.baseURL.absoluteString, forKey: "goosetv.serverURL")
        defaults.set(serverName, forKey: "goosetv.serverName")
        defaults.set(serverFlavor.rawValue, forKey: Self.flavorKey)
        TokenStore.save(auth.accessToken)
        defaults.set(auth.user.id, forKey: "goosetv.userId")
        defaults.set(auth.user.name, forKey: "goosetv.userName")
        // Before the shared session is written, which carries this viewer's
        // hidden Next Up episodes.
        loadMenu(for: auth.user.id)
        // Again now there's an account: a sign-in by password is made with a
        // client that had none when it was set.
        requests.restore(for: client)
        if let baseURL = client?.baseURL {
            SavedAccounts.remember(SavedAccount(serverURL: baseURL.absoluteString, userId: auth.user.id,
                                                name: auth.user.name, imageTag: auth.user.primaryImageTag,
                                                flavor: serverFlavor),
                                   token: auth.accessToken)
            SharedSession.save(baseURL: baseURL, flavor: serverFlavor, userId: auth.user.id,
                               showsOnHomeScreen: showsOnHomeScreen, hiddenNextUp: hiddenNextUp)
            // Remembered once it's known to work, not when it was typed.
            SavedServers.remember(url: baseURL, name: serverName, flavor: serverFlavor)
        }
        resetLibraries()   // possibly a different user or server
        hasFavorites = false
        hasWatchlist = false
        hasLiveTV = false
        liveChannelCount = 0
        recordingLibraries = []
        recordingFolders = []
        recordedShows = []
        guideArt.forget()
        LiveAirDates.shared.forget()
        SyncPlay.shared.forget()
        RemoteControl.shared.forget()
        ServerLink.shared.forget()
        recordingCovers = [:]
        coverMisses = [:]
        libraryTitles = [:]
        liveCanRecord = false
        hasCollections = false
        managesCollections = false
        preferences = nil
        isAdmin = false
        findsSubtitles = false
        signInNotice = nil
        authTrail = []
        phase = .main
        shelfChanged()   // someone else's shows, perhaps
    }

    /// From Settings: pick another server without signing out first.
    func beginServerChange() {
        switchBeganInSettings = true
        open(.serverSetup)
    }

    /// Signs in as an account already signed in on this Apple TV, with the
    /// token it kept. The token is tried first; one the server has since
    /// revoked forgets the account, and the caller asks for a password.
    func signIn(as account: SavedAccount) async -> Bool {
        guard let url = URL(string: account.serverURL), let token = SavedAccounts.token(for: account) else {
            SavedAccounts.forget(account)
            return false
        }
        let candidate = MediaBrowserClient(baseURL: url, flavor: account.flavor, token: token, userId: account.userId)
        do {
            _ = try await candidate.userDetails()
        } catch ServerError.badResponse(401) {
            SavedAccounts.forget(account)
            return false
        } catch {
            return false
        }
        client = candidate
        signedIn(AuthenticationResult(user: JFUser(id: account.userId, name: account.name,
                                                   primaryImageTag: account.imageTag),
                                      accessToken: token))
        return true
    }

    /// Sign in as someone else on this server without signing out first: from
    /// Settings, or from the Apple TV menu's top row.
    func beginSwitchUser(fromSettings: Bool = true) {
        guard let client else { return }
        self.client = MediaBrowserClient(baseURL: client.baseURL, flavor: client.flavor)
        switchBeganInSettings = fromSettings
        open(.login)
    }

    /// Sign-in "Change Server": back returns to this sign-in screen.
    func chooseAnotherServer() {
        open(.serverSetup)
    }

    /// Back on a sign-in screen. Returns false when there's nowhere to go
    /// (first launch, or after signing out), leaving back to the system.
    @discardableResult
    func backOutOfSignIn() -> Bool {
        guard let previous = authTrail.popLast() else { return false }
        if previous == .main {
            // Reload the saved session, untouched by the abandoned switch.
            authTrail = []
            reopenSettings = switchBeganInSettings
            switchBeganInSettings = true
            restore()
        } else {
            phase = previous
        }
        return true
    }

    private func open(_ next: Phase) {
        authTrail.append(phase)
        phase = next
    }

    func loadPreferences() async {
        guard let client, let details = try? await client.userDetails(),
              client === self.client else { return }   // not for an account since switched from
        // Written only when different: every Settings page asks on opening,
        // and each write redraws the whole app.
        let loaded = UserPreferences(configuration: details.configuration)
        if preferences != loaded { preferences = loaded }
        if isAdmin != details.isAdministrator { isAdmin = details.isAdministrator }
        findsSubtitles = details.findsSubtitles
    }

    /// Applies a change right away and saves it to the account. Rolls back and
    /// returns false if the server refuses (e.g. an account that can't edit itself).
    func updatePreferences(_ change: (inout UserPreferences) -> Void) async -> Bool {
        guard let client, var updated = preferences else { return false }
        let previous = updated
        change(&updated)
        preferences = updated
        do {
            // Read-modify-write so fields changed elsewhere aren't clobbered.
            let configuration = try await client.userConfiguration()
            try await client.saveUserConfiguration(updated.applied(to: configuration))
            return true
        } catch {
            preferences = previous
            return false
        }
    }

    private func resetLibraries() {
        if !libraries.isEmpty { libraries = [] }
        librariesFetch?.cancel()
        librariesFetch = nil
    }

    /// Loads the libraries once; concurrent callers await the same fetch.
    func loadLibraries() async {
        guard libraries.isEmpty else { return }
        let fetch: Task<[BaseItem], Never>
        if let running = librariesFetch {
            fetch = running
        } else {
            let client = client
            fetch = Task { (try? await client?.userViews()) ?? [] }
            librariesFetch = fetch
        }
        let fetched = await fetch.value
        // The first caller to hear back writes them, once. A fetch reset
        // meanwhile (another viewer signed in) is dropped rather than
        // bringing back the previous viewer's libraries.
        guard librariesFetch == fetch, libraries.isEmpty else { return }
        guard !fetched.isEmpty else {
            // A failed or empty fetch shouldn't stick: let the next caller retry.
            librariesFetch = nil
            return
        }
        libraries = inSavedOrder(fetched)
    }

    /// The server stopped accepting the saved sign-in. Without this, every request just
    /// failed and the app sat on empty screens; instead, go back to sign-in on the same
    /// server with the username filled in.
    private func sessionExpired() {
        guard phase == .main else { return }   // many requests fail at once; act on the first
        let name = userName
        signOut()
        userName = name
        signInNotice = String(localized: "Your session has expired. Sign in again.")
    }

    /// When the libraries were last asked after on coming back to the app.
    private var librariesCheckedAt = Date.distantPast

    /// The app back in front: libraries added, removed or renamed on the
    /// server while it was away (in Jellyfin's dashboard, say) come into the
    /// menu. The libraries were read once at sign-in, and an Apple TV keeps
    /// the app open for days, so a library added meanwhile never appeared.
    /// At most every two minutes, and the menu is left alone unless they
    /// changed.
    func refreshLibrariesIfChanged() async {
        guard phase == .main, !libraries.isEmpty, librariesFetch != nil,
              Date().timeIntervalSince(librariesCheckedAt) > 120 else { return }
        librariesCheckedAt = Date()
        guard let fetched = try? await client?.userViews(), !fetched.isEmpty else { return }
        func shape(_ items: [BaseItem]) -> Set<String> {
            Set(items.map { "\($0.id)|\($0.name ?? "")|\($0.collectionType ?? "")" })
        }
        // Signed out or switched meanwhile, or nothing changed.
        guard phase == .main, !libraries.isEmpty, shape(fetched) != shape(libraries) else { return }
        libraries = inSavedOrder(fetched)
        await refreshMenuContents()
    }

    /// Re-fetches the libraries after they've been changed on the server.
    func reloadLibraries() async {
        resetLibraries()
        async let contents: Void = refreshMenuContents()
        await loadLibraries()
        await contents
    }

    func signOut() {
        // Tell the server before forgetting the token, or it stays valid there
        // until the device is deleted from the dashboard by hand. The handler is
        // dropped first: an already-dead token answers 401, and that must not
        // read as "your session expired".
        if let current = client {
            current.onUnauthorized = nil
            // Signing out forgets the account on this Apple TV; switching user
            // doesn't come through here and keeps it.
            if let userId = current.userId {
                SavedAccounts.forget(serverURL: current.baseURL.absoluteString, userId: userId)
            }
            SyncPlay.shared.forget()
            RemoteControl.shared.forget()
            ServerLink.shared.forget()
            Task { await current.logout() }
        }
        signInNotice = nil
        pins = []
        hasFavorites = false
        hasWatchlist = false
        hasLiveTV = false
        liveChannelCount = 0
        hasCollections = false
        managesCollections = false
        setHiddenNextUp([])
        menuSections = MenuSection.allCases
        resetLibraries()
        preferences = nil
        isAdmin = false
        findsSubtitles = false
        authTrail = []   // nothing signed in to go back to
        TokenStore.clear()
        // Or the home screen would go on showing a signed-out viewer's shows.
        SharedSession.clear()
        #if os(iOS)
        // Nor the device's search their titles.
        SpotlightIndex.clear()
        #endif
        shelfChanged()
        defaults.removeObject(forKey: "goosetv.userId")
        defaults.removeObject(forKey: "goosetv.userName")
        if let current = client {
            client = MediaBrowserClient(baseURL: current.baseURL, flavor: current.flavor)
            phase = .login
        } else {
            client = nil
            phase = .serverSetup
        }
    }

    // MARK: Menu

    private func menuKey(_ name: String) -> String? {
        defaults.string(forKey: "goosetv.userId").map { "goosetv.\(name).\($0)" }
    }

    /// Pins and the menu's order belong to the person signed in, so each viewer
    /// on a shared TV keeps their own menu.
    private func loadMenu(for userId: String?) {
        if let userId, let data = defaults.data(forKey: "goosetv.pins.\(userId)"),
           let saved = try? JSONDecoder().decode([PinnedFilter].self, from: data) {
            pins = saved
        } else {
            pins = []
        }
        setHiddenNextUp(userId.flatMap { defaults.stringArray(forKey: "goosetv.hiddenNextUp.\($0)") } ?? [])
        let saved = (userId.flatMap { defaults.stringArray(forKey: "goosetv.menuOrder.\($0)") } ?? [])
            .compactMap(MenuSection.init(rawValue:))
        // Sections added in a later version join the end rather than going missing.
        menuSections = saved + MenuSection.allCases.filter { !saved.contains($0) }
        tabBar = userId.flatMap { defaults.stringArray(forKey: "goosetv.tabBar.\($0)") } ?? Self.defaultTabs
    }

    // MARK: The tab bar (a phone's)

    /// Something that can be a tab: a section, a library, or a view pinned
    /// to the menu, named and drawn as the menu has it.
    struct TabChoice: Identifiable, Equatable {
        let id: String
        let title: String
        /// A `MenuGlyph`'s name, or a system symbol's.
        let icon: String
    }

    /// Everything that can be a tab on this server for this viewer just now:
    /// sections the menu has a row for, every library and every pinned view.
    func tabChoices() -> [TabChoice] {
        var all = [
            TabChoice(id: "home", title: String(localized: "Home", comment: "Menu section: the home screen"), icon: MenuGlyph.home.rawValue),
            TabChoice(id: "libraries", title: String(localized: "Libraries"), icon: MenuGlyph.libraries.rawValue),
            TabChoice(id: "search", title: String(localized: "Search", comment: "Menu section: the search screen"), icon: MenuGlyph.search.rawValue),
            TabChoice(id: "downloads", title: String(localized: "Downloads"), icon: "arrow.down.circle"),
        ]
        if isShown(.liveTV) {
            all.append(TabChoice(id: "liveTV", title: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                                 icon: "antenna.radiowaves.left.and.right"))
        }
        if hasFavorites { all.append(TabChoice(id: "favorites", title: String(localized: "Favourites"), icon: MenuGlyph.favourites.rawValue)) }
        if hasWatchlist {
            all.append(TabChoice(id: "watchlist", title: String(localized: "Watchlist", comment: "Menu section: the films marked to be watched"), icon: "bookmark"))
        }
        if hasCollections { all.append(TabChoice(id: "collections", title: String(localized: "Collections"), icon: MenuGlyph.collections.rawValue)) }
        if showsRequests {
            all.append(TabChoice(id: "requests", title: String(localized: "Requests", comment: "Menu section and settings page: asking for titles through Seerr"),
                                 icon: "plus.rectangle.on.rectangle"))
        }
        all.append(TabChoice(id: "together", title: SyncPlay.title, icon: "person.2"))
        all.append(TabChoice(id: "settings", title: String(localized: "Settings"), icon: "gearshape"))
        all += libraries.map { TabChoice(id: "library:" + $0.id, title: $0.displayTitle, icon: $0.librarySymbol) }
        all += menuPins.map { TabChoice(id: "pinned:" + $0.id.uuidString, title: $0.title, icon: $0.icon) }
        return all
    }

    /// Puts something on the tab bar, at the end, or takes it off. No more
    /// than `mostTabs`: the phone's width holds four and Menu.
    func setTab(_ id: String, shown: Bool) {
        if shown {
            guard !tabBar.contains(id), tabBar.count < Self.mostTabs else { return }
            tabBar.append(id)
        } else {
            tabBar.removeAll { $0 == id }
        }
        saveTabs()
    }

    func moveTab(_ id: String, by offset: Int) {
        guard Self.shift(&tabBar, at: tabBar.firstIndex(of: id), by: offset) else { return }
        saveTabs()
    }

    private func saveTabs() {
        guard let key = menuKey("tabBar") else { return }
        defaults.set(tabBar, forKey: key)
    }

    private func savePins() {
        guard let key = menuKey("pins"), let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: key)
    }

    /// Libraries in the order the user arranged them; ones the server has added
    /// since keep the server's order, after the arranged ones.
    private func inSavedOrder(_ fetched: [BaseItem]) -> [BaseItem] {
        guard let key = menuKey("libraryOrder"),
              let order = defaults.stringArray(forKey: key), !order.isEmpty else { return fetched }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return fetched.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset)
                    < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// Shifts a menu section past its next shown neighbour; false when it's
    /// already at that end. Hidden sections are stepped over, or a move past
    /// one would look like a press that did nothing.
    @discardableResult
    func moveSection(_ section: MenuSection, by offset: Int) -> Bool {
        guard let from = menuSections.firstIndex(of: section), offset != 0,
              let to = stride(from: from + offset, to: offset < 0 ? -1 : menuSections.count, by: offset < 0 ? -1 : 1)
                .first(where: { isShown(menuSections[$0]) }),
              let key = menuKey("menuOrder") else { return false }
        menuSections.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        defaults.set(menuSections.map(\.rawValue), forKey: key)
        return true
    }

    @discardableResult
    func moveLibrary(_ id: String, by offset: Int) -> Bool {
        guard Self.shift(&libraries, at: libraries.firstIndex { $0.id == id }, by: offset),
              let key = menuKey("libraryOrder") else { return false }
        defaults.set(libraries.map(\.id), forKey: key)
        return true
    }

    @discardableResult
    func movePin(_ id: UUID, by offset: Int) -> Bool {
        guard Self.shift(&pins, at: pins.firstIndex { $0.id == id }, by: offset) else { return false }
        savePins()
        return true
    }

    private static func shift<T>(_ list: inout [T], at index: Int?, by offset: Int) -> Bool {
        guard let index, list.indices.contains(index + offset) else { return false }
        list.swapAt(index, index + offset)
        return true
    }

    /// A library's sort and filters as the viewer last left them.
    func savedFilters(for libraryId: String) -> LibraryFilters {
        savedFilters()[libraryId] ?? LibraryFilters()
    }

    func saveFilters(_ filters: LibraryFilters, for libraryId: String) {
        guard let key = menuKey("libraryFilters") else { return }
        var saved = savedFilters()
        // The usual ones kept too, not dropped, so another device's older
        // choice for the library can't come back (see `SettingsSync`).
        saved[libraryId] = filters
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }

    /// Kept for each viewer, as the menu is.
    private func savedFilters() -> [String: LibraryFilters] {
        guard let key = menuKey("libraryFilters"), let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: LibraryFilters].self, from: data) else { return [:] }
        return saved
    }

    func pin(for library: BaseItem, filters: LibraryFilters) -> PinnedFilter? {
        pins.first { $0.libraryId == library.id && $0.filters == filters }
    }

    /// The pins the menu lists, and those with a row on Home.
    var menuPins: [PinnedFilter] { pins.filter(\.inMenu) }
    var homePins: [PinnedFilter] { pins.filter(\.onHome) }

    func addPin(library: BaseItem, filters: LibraryFilters) {
        setPin(library: library, filters: filters, inMenu: true)
    }

    /// Puts a library's filters in the menu or on Home, or takes them off,
    /// made a pin if they weren't one. A pin in neither place is gone.
    func setPin(library: BaseItem, filters: LibraryFilters, inMenu: Bool? = nil, onHome: Bool? = nil) {
        if let existing = pin(for: library, filters: filters) {
            if let inMenu { setPin(existing.id, inMenu: inMenu) }
            if let onHome { setPin(existing.id, onHome: onHome) }
            return
        }
        guard inMenu == true || onHome == true else { return }
        pins.append(PinnedFilter(libraryId: library.id, libraryName: library.displayTitle,
                                 collectionType: library.collectionType, filters: filters,
                                 inMenu: inMenu ?? false, onHome: onHome ?? false))
        savePins()
    }

    func setPin(_ id: UUID, inMenu: Bool) {
        guard let index = pins.firstIndex(where: { $0.id == id }), pins[index].inMenu != inMenu else { return }
        pins[index].inMenu = inMenu
        settlePin(at: index)
    }

    /// From the filter bar, a pin in neither place is gone; from Settings,
    /// Home Screen (`keepsPin`), it stays listed there, switched off.
    func setPin(_ id: UUID, onHome: Bool, keepsPin: Bool = false) {
        guard let index = pins.firstIndex(where: { $0.id == id }), pins[index].onHome != onHome else { return }
        pins[index].onHome = onHome
        if keepsPin { savePins() } else { settlePin(at: index) }
    }

    /// Kept while it's somewhere; otherwise gone, and its place on Home with it.
    private func settlePin(at index: Int) {
        if !pins[index].inMenu && !pins[index].onHome {
            removePin(pins[index].id)
        } else {
            savePins()
        }
    }

    /// A name of the user's own, or back to the automatic one when cleared.
    func renamePin(_ id: UUID, to name: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pins[index].customName = trimmed.isEmpty ? nil : trimmed
        savePins()
    }

    func removePin(_ id: UUID) {
        pins.removeAll { $0.id == id }
        savePins()
        let row = HomeLayout.pinned(id)
        if homeOrder.contains(row) { homeOrder.removeAll { $0 == row } }
        if homeHidden.contains(row) { homeHidden.remove(row) }
    }

    // MARK: Next Up

    /// Takes an episode off Next Up, here and on the Apple TV home screen.
    func removeFromNextUp(_ episodeId: String) {
        guard !hiddenNextUpSet.contains(episodeId), let key = menuKey("hiddenNextUp") else { return }
        // The oldest go once there are plenty: by then their shows have long
        // moved on to other episodes, or been forgotten.
        setHiddenNextUp(Array((hiddenNextUp + [episodeId]).suffix(Self.mostHiddenNextUp)))
        defaults.set(hiddenNextUp, forKey: key)
        SharedSession.setHiddenNextUp(hiddenNextUp)
        userDataChanged()   // which tells the home screen too
    }

    /// Next Up as the viewer wants it, without what they removed.
    func visibleNextUp(_ items: [BaseItem]) -> [BaseItem] {
        hiddenNextUpSet.isEmpty ? items : items.filter { !hiddenNextUpSet.contains($0.id) }
    }

    private func setHiddenNextUp(_ ids: [String]) {
        hiddenNextUp = ids
        hiddenNextUpSet = Set(ids)
    }

    /// Asks tvOS to fetch the home screen's shelf again: what it shows, or
    /// whose it is, has changed. Without this it goes on showing its last
    /// copy, a signed-out viewer's shows included.
    private func shelfChanged() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #else
        // The home screen's widgets say what's in progress and next too.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// MARK: - Reaching AppState without observing it

/// Compared by identity, so an environment carrying it is unchanged for as
/// long as the same object is in it.
extension AppState: Equatable {
    nonisolated static func == (lhs: AppState, rhs: AppState) -> Bool { lhs === rhs }
}

private struct AppStateKey: EnvironmentKey {
    static let defaultValue: AppState? = nil
}

extension EnvironmentValues {
    /// AppState for views that only call it or read `client` from it: a card,
    /// a badge, a panel. `@EnvironmentObject` redraws its view on every
    /// published change, and a menu focus hold or a watched mark changing was
    /// redrawing every card on a hundred-poster grid. Screens that show
    /// something from AppState keep `@EnvironmentObject`.
    ///
    /// Optional because SwiftUI reads the value here before it writes it, so a
    /// getter that insisted on one crashed the app as it was being set.
    var appState: AppState? {
        get { self[AppStateKey.self] }
        set { self[AppStateKey.self] = newValue }
    }
}

/// See `AppState.menuHold`.
@MainActor
final class MenuFocusHold: ObservableObject {
    @Published fileprivate(set) var held = false
    /// Set while focus is being sent out of the menu (see `AppState.leaveMenu`).
    @Published fileprivate(set) var leaving = false
    /// Whether one of the menu's rows has focus, as the menu last said. Not
    /// published: nothing is drawn from it.
    var menuFocused = false
    /// The search keyboard has focus. To the focus engine the keyboard is one
    /// thing, its letters its own affair, so the menu is its neighbour on the
    /// left wherever among the letters the cursor is: on a television a swipe
    /// left along the letters went into the menu, and a press left from "a"
    /// went there too, past SPACE and 123. While the keyboard has focus the
    /// menu takes none. Back opens the menu from there, as it does everywhere.
    @Published fileprivate(set) var typing = false

    #if os(tvOS)
    private var watching: NSObjectProtocol?

    init() {
        watching = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                let onKeyboard = Self.isKeyboard(context?.nextFocusedItem)
                guard let self, self.typing != onKeyboard else { return }
                self.typing = onKeyboard
            }
        }
    }

    /// Whether what has focus is the system's keyboard: the thing itself or
    /// what it sits in is named for one. Its classes aren't public, so it's
    /// known by name.
    private static func isKeyboard(_ item: UIFocusItem?) -> Bool {
        var view = item as? UIView
        for _ in 0..<8 {
            guard let current = view else { return false }
            if String(describing: type(of: current)).contains("Keyboard") { return true }
            view = current.superview
        }
        return false
    }
    #endif

    /// Whether anything is keeping the menu from taking focus just now.
    var holding: Bool { typing || held }

    /// The menu was asked for outright (Back from the keyboard, or a page
    /// left with nothing to hold focus): whatever kept it off lets go.
    func letGo() {
        if typing { typing = false }
        if held { held = false }
    }
}
