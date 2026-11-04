import SwiftUI
#if os(iOS)
import CoreSpotlight
import UserNotifications
#elseif os(macOS)
import UserNotifications
#endif

@main
struct GooseTVApp: App {
    @StateObject private var app = AppState()

    init() {
        // What a television channel had kept, if the app was killed with
        // one on: gigabytes, and nothing else would ever clear it.
        DispatchQueue.global(qos: .utility).async { LiveBuffer.sweep() }
        #if os(macOS)
        // A finished download's notice, and where choosing it goes (the iPhone's
        // AppDelegate sets this).
        UNUserNotificationCenter.current().delegate = DownloadNotices.shared
        // New-episode alerts, every hour while the app runs.
        DispatchQueue.main.async { NewEpisodes.shared.schedule() }
        // The icon chosen in Settings, Appearance, in the Dock.
        DispatchQueue.main.async { UIApplication.showDockIcon() }
        #endif
        #if os(macOS) && DEBUG
        DispatchQueue.main.async { MacDebugSnapshots.startIfAsked() }
        #endif
    }
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // One window, as a media app has: the dark page runs to the top edge, under the
        // window's buttons; a film opens in a window of its own (MacPlayerStage).
        WindowGroup {
            root
                // A button with no style of its own is drawn as on iPad, with no
                // bezel: the Mac's default is a grey push button.
                .buttonStyle(.borderless)
                .background(MacWindowSetup())
                // A link (a widget, Spotlight) goes to the window that's open, not a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { MacCommands(app: app) }
        #elseif os(iOS)
        WindowGroup { root }
            // New-episode alerts, as iOS wakes the app for them.
            .backgroundTask(.appRefresh(NewEpisodes.taskID)) {
                await NewEpisodes.shared.backgroundCheck()
            }
        #else
        WindowGroup { root }
        #endif
    }

    private var root: some View {
        // The first window is the app; another only says so (OneWindowGate).
        OneWindowGate {
            RootView()
                .environmentObject(app)
                .environment(\.appState, app)
        }
        .themed(app.shownTheme)
        .preferredColorScheme(.dark)
        // Chosen on the Apple TV home screen, in the row above the app.
        .onOpenURL { app.open(url: $0) }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    /// The version's highlights, once, to someone who updated (see WhatsNew).
    @State private var showingWhatsNew = false
    /// Read once, before anything can sign in: signed in already means an update.
    @State private var returning: Bool?

    var body: some View {
        Group {
            switch app.phase {
            case .serverSetup:
                ServerSetupView()
            case .login:
                LoginView()
            case .main:
                MainTabView(startInSettings: app.reopenSettings)
            }
        }
        // Fill the screen before painting the wallpaper: setup and sign-in are only
        // as big as their content, and the wallpaper would stop at their edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The app's own wallpaper, whatever the section on show is wearing:
        // the Requests section lays its own over the page alone.
        .background(AppWallpaper(theme: app.theme).ignoresSafeArea())
        .font(.app(29))   // default for any text without its own font
        // Sign-in screens: back returns to the one before, or to the session a
        // user/server switch started from. MainTabView handles back in the app.
        .tvExitCommand(perform: app.phase == .main || app.authTrail.isEmpty
                       ? nil : { app.backOutOfSignIn() })
#if DEBUG
        .task { await debugAutoLogin() }
        // GOOSETV_REVIEW=1 shows the rating request once Home is up, to see it.
        .task {
            guard ProcessInfo.processInfo.environment["GOOSETV_REVIEW"] == "1" else { return }
            try? await Task.sleep(for: .seconds(12))
            app.reviewDue = true
        }
#endif
        .onChange(of: scenePhase) { _, phase in
            // Give the TV its own mode back on the way out of the app, not on the
            // way out of a film.
            if phase == .background {
                DisplayCriteria.reset()
                // Settings changed in the last moment sent before the app's put away.
                SettingsSync.shared.flush()
                #if os(iOS)
                // The next look for new episodes, while the app's away.
                NewEpisodes.shared.schedule()
                #endif
            }
            if phase == .active {
                #if DEBUG && os(iOS)
                // GOOSETV_NE_CHECK_AFTER=<seconds>: the background look for new
                // episodes, made with the app open, for tests (simulators run no
                // background refresh).
                if let wait = ProcessInfo.processInfo.environment["GOOSETV_NE_CHECK_AFTER"].flatMap(Double.init) {
                    Task {
                        try? await Task.sleep(for: .seconds(wait))
                        if let client = app.client as? MediaBrowserClient { await NewEpisodes.shared.check(client: client) }
                    }
                }
                #endif
                SettingsSync.shared.refresh()
                app.requests.lookAgain()
                // A library added on the server while the app was away.
                Task { await app.refreshLibrariesIfChanged() }
                // A trial runs out while the app's away; a purchase arrives
                // from another device.
                Task { await Unlock.shared.refresh() }
            }
        }
        .task { await AppIcon.resetIfUnknown() }
        .task { ReviewPrompt.noteLaunch() }
        .task {
            await Unlock.shared.refresh()
            #if DEBUG
            // GOOSETV_UNLOCK_SHOW=1 puts the unlock screen up, to see it.
            if ProcessInfo.processInfo.environment["GOOSETV_UNLOCK_SHOW"] == "1" {
                try? await Task.sleep(for: .seconds(4))
                UnlockStage.shared.show()
            }
            #endif
        }
        .task {
            if returning == nil { returning = app.phase == .main }
            guard WhatsNew.isDue(returning: returning ?? false) else { return }
            // Once Home has drawn, rather than over the launch.
            try? await Task.sleep(for: .seconds(1.5))
            if app.phase == .main { showingWhatsNew = true }
        }
        .fullScreenCover(isPresented: $showingWhatsNew) {
            WhatsNewCard { showingWhatsNew = false }
                .presentationBackground(.clear)
        }
        #if os(iOS)
        // What was watched on the device while the server was out of reach,
        // and any download that broke off and has to start over.
        .task(id: app.client == nil) {
            guard let client = app.client as? MediaBrowserClient else { return }
            // Downloads beside the rest, not before it: one starting again can
            // wait on the question of notices for as long as it's unanswered.
            Task {
                await Downloads.shared.sendPositions(client: client)
                await Downloads.shared.carryOn(client: client)
                // The shows kept downloaded, brought up to date.
                await SmartDownloads.shared.refresh(client: client)
            }
            // What Siri's phrases with a title in them are learnt for.
            JellyGooseShortcuts.updateAppShortcutParameters()
            // The library in the device's search, once a day, beside the rest.
            Task { await SpotlightIndex.refresh(client: client) }
            #if DEBUG
            await debugIntent()
            #endif
        }
        // Chosen in the device's search: its page.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            app.open(url: DeepLink.display(id))
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let client = app.client as? MediaBrowserClient else { return }
            Task {
                await Downloads.shared.sendPositions(client: client)
                await Downloads.shared.carryOn(client: client)
                await SmartDownloads.shared.refresh(client: client)
            }
        }
        // An episode watched: the next one down, and the one watched gone.
        .onChange(of: app.userDataRevision) { _, _ in
            guard let client = app.client as? MediaBrowserClient else { return }
            Task { await SmartDownloads.shared.refresh(client: client) }
        }
        #elseif os(macOS)
        // The downloads' part of the above: what was watched offline told to the
        // server, broken-off downloads carried on, kept shows brought up to date.
        .task(id: app.client == nil) {
            guard let client = app.client as? MediaBrowserClient else { return }
            await Downloads.shared.sendPositions(client: client)
            await Downloads.shared.carryOn(client: client)
            await SmartDownloads.shared.refresh(client: client)
        }
        .onChange(of: app.userDataRevision) { _, _ in
            guard let client = app.client as? MediaBrowserClient else { return }
            Task { await SmartDownloads.shared.refresh(client: client) }
        }
        #endif
        .reviewPrompt(isDue: $app.reviewDue)
    }

#if DEBUG && os(iOS)
    /// GOOSETV_INTENT runs one of Siri's requests as Siri would, a moment
    /// after Home is up (a simulator can't be spoken to): "continue",
    /// "shuffle", "video:<id>", "music:<id>", or "spotlight" to index now.
    private func debugIntent() async {
        guard let asked = ProcessInfo.processInfo.environment["GOOSETV_INTENT"] else { return }
        try? await Task.sleep(for: .seconds(4))
        let parts = asked.split(separator: ":", maxSplits: 1).map(String.init)
        let client = app.client as? MediaBrowserClient
        switch parts[0] {
        case "continue": _ = try? await ContinueWatchingIntent().perform()
        case "shuffle": _ = try? await ShuffleMusicIntent().perform()
        case "video" where parts.count == 2:
            guard let item = try? await client?.item(id: parts[1]) else { return }
            var intent = PlayVideoIntent()
            intent.item = VideoEntity(item)
            _ = try? await intent.perform()
        case "music" where parts.count == 2:
            guard let item = try? await client?.item(id: parts[1]) else { return }
            var intent = PlayMusicIntent()
            intent.music = MusicEntity(item)
            _ = try? await intent.perform()
        case "spotlight":
            if let client { await SpotlightIndex.refresh(client: client, force: true) }
        default: break
        }
    }
#endif

#if DEBUG
    /// Dev convenience: launch with GOOSETV_SERVER / GOOSETV_USER / GOOSETV_PASS
    /// env vars (e.g. via simctl) to skip setup and land on Home.
    private func debugAutoLogin() async {
        let env = ProcessInfo.processInfo.environment
        guard app.phase != .main,
              let server = env["GOOSETV_SERVER"], let url = URL(string: server),
              let user = env["GOOSETV_USER"] else { return }
        let probe = MediaBrowserClient(baseURL: url)
        guard let info = try? await probe.publicInfo() else { return }
        // Emby 4 doesn't name itself, so an address ending in /emby says it.
        let flavor = ServerFlavor.named(info.productName) ?? (url.lastPathComponent == "emby" ? .emby : .jellyfin)
        app.connect(to: url, flavor: flavor, serverName: info.serverName)
        if let auth = try? await app.client?.authenticate(username: user, password: env["GOOSETV_PASS"] ?? "") {
            app.signedIn(auth)
        }
    }
#endif
}

private extension View {
    /// Asks for a rating when one is due: Apple's prompt on iPad, the app's own
    /// card on the Apple TV, which has no prompt of Apple's.
    @ViewBuilder
    func reviewPrompt(isDue: Binding<Bool>) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isDue) {
            ReviewCard { isDue.wrappedValue = false }
                .presentationBackground(.clear)
        }
        #else
        modifier(SystemReviewPrompt(isDue: isDue))
        #endif
    }
}

#if !os(tvOS)
import StoreKit

private struct SystemReviewPrompt: ViewModifier {
    @Binding var isDue: Bool
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content.onChange(of: isDue) { _, due in
            guard due else { return }
            ReviewPrompt.asked()
            requestReview()
            isDue = false
        }
    }
}
#endif

struct MainTabView: View {
    enum Selection: Hashable {
        case home, librariesOverview, library(String), pinned(UUID), favorites, watchlist, collections, search, settings
        /// The server's television channels.
        case liveTV
        /// iPhone and iPad: what's on the device.
        case downloads
        /// Asking for titles through Seerr.
        case requests
        /// Watching in step with others (Jellyfin's SyncPlay).
        case together
    }

    /// Sidebar rows, used both as focus identity and to aggregate "is any row focused".
    enum SidebarItem: Hashable {
        case home, libraries, library(String), pinned(UUID), favorites, watchlist, collections, search, settings, downloads, requests
        case liveTV, together
        /// Apple TV: who's watching, at the top of the menu.
        case profile
        /// Apple TV: the music playing, above the sections while there is some.
        case nowPlaying
    }

    @EnvironmentObject var app: AppState

    @State private var selection: Selection

    init(startInSettings: Bool = false) {
        _selection = State(initialValue: startInSettings ? .settings : Self.launchSelection)
    }

    // GOOSETV_TAB=libraries etc. jumps straight to a section (dev/screenshot convenience).
    // Worked out once: it's asked for each time this view is made, on every
    // redraw of the app around it.
    private static let launchSelection: Selection = selection(named: ProcessInfo.processInfo.environment["GOOSETV_TAB"] ?? "")

    /// A section by the name GOOSETV_TAB and `AppState.askForSection` use; Home for
    /// any other.
    private static func selection(named tab: String) -> Selection {
        if tab.hasPrefix("library:") { return .library(String(tab.dropFirst("library:".count))) }
        if tab.hasPrefix("pinned:"), let id = UUID(uuidString: String(tab.dropFirst("pinned:".count))) { return .pinned(id) }
        switch tab {
        case "libraries": return .librariesOverview
        case "favorites": return .favorites
        case "watchlist": return .watchlist
        case "livetv": return .liveTV
        case "collections": return .collections
        case "search": return .search
        case "requests": return .requests
        case "together": return .together
        case "settings": return .settings
        case "downloads": return .downloads
        default: return .home
        }
    }
    @State private var renamingPin: PinnedFilter?
    /// The menu row being moved, from its long-press menu until Select or back.
    @State private var movingRow: SidebarItem?
    @State private var librariesExpanded = true
    @State private var homePath = NavigationPath()
    @State private var librariesPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var favoritesPath = NavigationPath()
    @State private var watchlistPath = NavigationPath()
    @State private var collectionsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var requestsPath = NavigationPath()
    @State private var homeShelves = HomeShelves()
    /// Home's shelves and the section roots' grids. Held, not watched: each
    /// screen watches its own, so their loading redraws only that screen.
    @State private var grids = LibraryGridModels()
    @State private var homeScrollRequest = 0
    /// Where the Live TV guide is, for Back (see `backAction`).
    @State private var liveGuide = LiveGuidePlace()
    /// Whether focus is on one of the menu's rows. Which row is the menu's own
    /// business (`SidebarFocusHost`): kept here, every press up or down the
    /// menu redrew this whole view, the page behind the menu included.
    @State private var menuFocused = false
    /// A row to move focus to, handed to the menu, which clears it.
    @State private var menuFocusRequest: SidebarItem?

    /// The sidebar pops out whenever focus is on any of its rows, or on iPad
    /// while it's been tapped open.
    private var sidebarExpanded: Bool { menuFocused || menuTappedOpen }
    /// iPad: the menu opened with a tap on the brand, until a row is chosen or
    /// the page beside it is tapped.
    @State private var menuTappedOpen = false
    /// Whether the account may watch together on this server, for its row.
    /// Followed alone rather than watching the group, whose every word
    /// would redraw the whole app.
    @State private var watchesTogether = false
    /// A film the group started, with no player open here to take it.
    /// A film opened from elsewhere: by the group watching together, or
    /// asked for from another device (`RemoteControl`).
    @State private var launchedFilm: BaseItem?
    @State private var launchedSource: String?
    @State private var launchedQueue: [BaseItem] = []
    private var libraries: [BaseItem] { app.libraries }
    /// The rail of icons down the left; none on a narrow screen, where the
    /// tab bar along the bottom does its job.
    private var railWidth: CGFloat { narrow ? 0 : CGFloat(84).scaled }
    /// The menu's colours: the scheme chosen in Appearance, whatever the
    /// section on show is wearing. The Requests section changes the page's
    /// colours, not the menu's.
    private var menuColors: ThemeColors { app.theme.colors }
    /// The open menu's width.
    private static let menuWidth = CGFloat(280).scaled
    /// How much of the page the open menu covers on the Apple TV.
    private static func menuOverlap(rail: CGFloat) -> CGFloat {
        #if os(tvOS)
        menuWidth - rail
        #else
        0
        #endif
    }
    /// How far the open menu slides the page. Not at all on the Apple TV, where
    /// the menu opens over the page and the page stays where it is.
    private var menuShift: CGFloat {
        #if os(tvOS)
        0
        #else
        sidebarExpanded ? Self.menuWidth - railWidth : 0
        #endif
    }

    /// An iPhone, or an iPad app sharing the screen at a phone's width.
    @Environment(\.isNarrow) private var narrow
    /// The side bars stand along (an iPhone Duo folded), or nil.
    @Environment(\.barEdge) private var barEdge
    /// The window's safe area, for the width of the strip bars stand in.
    @State private var screenInsets = EdgeInsets()

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: railWidth)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The Requests section's own wallpaper, under its page and
                // out beneath the rail, where it fades into the app's own:
                // the menu keeps the app's colours, and the page leaves no
                // doubt which section it is.
                .background {
                    ZStack {
                        // Not when the section is set to look as the rest
                        // of the app does.
                        if selection == .requests, app.requestsScheme != .same {
                            RequestsWallpaper(theme: app.shownTheme)
                                .padding(.leading, -railWidth)
                                .mask {
                                    HStack(spacing: 0) {
                                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                            .frame(width: railWidth > 0 ? railWidth + 70 : 0)
                                        Color.black
                                    }
                                    .padding(.leading, -railWidth)
                                }
                                .ignoresSafeArea(edges: narrow ? [.top, .horizontal] : .all)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: selection == .requests)
                }
                // For what should stay put on screen as the page slides, like
                // the picture across the top of the Apple TV's Home.
                .environment(\.menuShift, menuShift)
                // Every card's long-press menu, and what it plays, from here.
                .itemMenuHost()
                // Focus section so a rightward press from any sidebar row lands in
                // the content even when its nearest control is diagonal to the beam.
                // On the Apple TV the section starts where the open menu ends,
                // though the page itself starts at the rail: the menu opens over
                // the page, and a section lying under the menu's rows isn't to
                // their right, so a press right from the menu went nowhere.
                .modifier(PageRegion(hold: app.menuHold, overlap: Self.menuOverlap(rail: railWidth), rail: railWidth))
                // Nowhere for focus to go while a row moves, so presses reach the row.
                .disabled(movingRow != nil)
                // The open menu slides the content aside rather than resizing it:
                // a slide moves the page as one piece, while re-laying out every
                // shelf and grid made the screen judder, and shrinking it (1.1)
                // redrew every picture, word and shadow on each frame, which
                // stuttered on a first-generation Apple TV 4K.
                .offset(x: menuShift)
                .animation(Self.menuAnimation, value: sidebarExpanded)
        }
        #if os(iOS)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { screenInsets = $0 }
        // Folded, an iPhone Duo's tabs stand in the strip beside its camera.
        .overlay(alignment: barEdge == .leading ? .bottomLeading : .bottomTrailing) {
            if narrow, let barEdge { sideTabBar(edge: barEdge).themed(app.theme) }
        }
        #endif
        #if !os(tvOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // The music playing, over the tabs; beside the rail on an iPad
                // or a Mac, where it lay over the rail's Settings icon.
                MiniPlayer()
                    .padding(.leading, railWidth)
                #if os(iOS)
                if narrow, barEdge == nil { tabBar.themed(app.theme) }
                #endif
            }
        }
        #else
        // Play/Pause on the remote works the music from anywhere a page
        // doesn't take it for itself.
        .onPlayPauseCommand { if MusicPlayer.shared.isActive { MusicPlayer.shared.togglePause() } }
        #endif
        .background { NowPlayingPresenter() }
        #if os(tvOS)
        // The open menu lies over the page, which dims towards the menu's side
        // so the menu reads against whatever is under it.
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0),
                                   .init(color: .black.opacity(0.7), location: 0.2),
                                   .init(color: .black.opacity(0.35), location: 0.55),
                                   .init(color: .black.opacity(0.2), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
                .opacity(sidebarExpanded ? 1 : 0)
                .animation(Self.menuAnimation, value: sidebarExpanded)
                .allowsHitTesting(false)
        }
        #endif
        .overlay(alignment: .leading) {
            if !narrow || sidebarExpanded {
            SidebarFocusHost(focused: $menuFocused, request: $menuFocusRequest, moving: $movingRow,
                             target: sidebarTarget, hold: app.menuHold) { focus in
            sidebar(focus)
                .frame(width: sidebarExpanded ? Self.menuWidth : railWidth)
                .frame(maxHeight: .infinity)
                .background(alignment: .leading) { sidebarPanel }
                #if !os(tvOS)
                // Collapsed, a tap anywhere on the strip that isn't one of its
                // icons opens the menu; the icons still go straight to their pages.
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !sidebarExpanded else { return }
                    withAnimation(Self.menuAnimation) { menuTappedOpen = true }
                }
                #endif
            }
                // The app's own scheme for the menu and everything in it.
                .themed(app.theme)
                .animation(Self.menuAnimation, value: sidebarExpanded)
                .transition(.move(edge: .leading))
                #if os(macOS)
                // Measured from the window's top, under its buttons: a page with a
                // back button has a toolbar, and the rail moved down by its height.
                .padding(.top, 28)
                .ignoresSafeArea(.container, edges: .top)
                #endif
            }
        }
        #if os(tvOS)
        // The tvOS safe area adds ~90pt per side; we manage our own margins instead.
        // Not on an iPhone on its side, where the side's safe area is the
        // Dynamic Island's: ignored, it put the rail under the island and
        // let every page that ignores its own sides slide under the rail.
        .ignoresSafeArea(.container, edges: .horizontal)
        #endif
        // Back steps outward, the same in every section: a pushed screen pops,
        // then the page goes to its top, then the menu opens, and from the open
        // menu back goes to Home. From the menu on Home it reaches the system
        // (suspends the app). It doesn't retrace the sections visited.
        .tvExitCommand(perform: backAction)
        .task {
            async let contents: Void = app.refreshMenuContents()
            await app.loadLibraries()
            await contents
        }
        .onAppear { app.reopenSettings = false }
        // Something was chosen on the home screen's shelf. Home is what opens it,
        // so be on Home — including when the app was already running elsewhere.
        .onChange(of: app.openedFromShelf) { _, opened in
            if opened != nil, selection != .home { show(.home) }
        }
        // A page with nothing left to hold focus has asked for the menu.
        .onChange(of: app.menuAsks) { _, _ in menuFocusRequest = sidebarTarget }
        // Home's row of what's on leads to the guide: the section opens as
        // if its row in the menu had been chosen.
        .onChange(of: app.liveTVAsks) { _, _ in open(.liveTV) }
        // A section asked for by name: the Mac's Go menu and its Settings… command.
        .onChange(of: app.sectionAsk) { _, ask in open(Self.selection(named: ask.name)) }
        // Settings opens the page itself, once it's there (see `SettingsView`).
        .onChange(of: app.homeSettingsAsks) { _, _ in open(.settings) }
        // The Requests section in its own colours from the start, when the
        // app opens on it; every later change of section sees to them
        // itself (see `show`).
        .onChange(of: selection, initial: true) { _, now in
            let requests = now == .requests
            if app.inRequests != requests { app.inRequests = requests }
        }
        .onDisappear { if app.inRequests { app.inRequests = false } }
        // The Requests section was turned down, or its Seerr left, while it
        // was open: Home, with the menu up, as Back from the menu goes.
        .onChange(of: app.showsRequests) { _, shown in
            if !shown, selection == .requests {
                show(.home)
                menuFocusRequest = .home
            }
        }
        .onChange(of: selection) { _, _ in
            librariesPath = NavigationPath()
            settingsPath = NavigationPath()
            menuTappedOpen = false
        }
        .onReceive(SyncPlay.shared.$access.combineLatest(SyncPlay.shared.$group).map { $0 != .none || $1 != nil }.removeDuplicates()) { may in
            let did = watchesTogether
            if did != may { watchesTogether = may }
            // Taken away while it was open (not before the server has said).
            if did, !may, selection == .together { show(.home) }
        }
        // Someone in the group chose a film: it opens here too.
        .onReceive(SyncPlay.shared.$launch) { id in
            guard let id else { return }
            Task {
                // Cleared once it's been set: cleared from inside its own
                // announcement, the id was stored after, and opened again by
                // the next view to listen (this one, built again).
                if SyncPlay.shared.launch == id { SyncPlay.shared.launch = nil }
                guard let film = try? await app.client?.item(id: id), SyncPlay.shared.playersOpen == 0 else { return }
                launchedSource = nil
                launchedQueue = []
                launchedFilm = film
            }
        }
        // Asked for from another device: whatever's playing closes for it.
        .onReceive(RemoteControl.shared.$launch) { asked in
            guard let asked else { return }
            Task {
                if RemoteControl.shared.launch == asked { RemoteControl.shared.launch = nil }
                var waited = false
                if SyncPlay.shared.playersOpen > 0 {
                    RemoteControl.shared.stopPlayer()
                    for _ in 0..<40 where SyncPlay.shared.playersOpen > 0 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    waited = true
                }
                guard let sent = try? await app.client?.item(id: asked.itemId),
                      let (film, queue) = await RemoteControl.shared.playable(sent, shuffled: asked.shuffled),
                      SyncPlay.shared.playersOpen == 0 else { return }
                // Time for a cover going away (a film's, Live TV's) to be gone.
                try? await Task.sleep(for: .milliseconds(waited ? 700 : 400))
                launchedSource = film.id == sent.id ? asked.mediaSourceId : nil
                launchedQueue = queue
                launchedFilm = film
            }
        }
        .playerCover(item: $launchedFilm) { PlayerView(item: $0, mediaSourceId: launchedSource, queue: launchedQueue) }
        #if !os(tvOS)
        // A tap on the page beside the open menu closes it.
        .overlay {
            if menuTappedOpen {
                Color.black.opacity(0.001)
                    .padding(.leading, Self.menuWidth)
                    .onTapGesture { withAnimation(Self.menuAnimation) { menuTappedOpen = false } }
            }
        }
        #endif
        .fullScreenCover(item: $renamingPin) { pin in
            TextEntryPanel(title: String(localized: "Rename Pin"),
                           message: String(localized: "Leave it empty to go back to \u{201C}\(pin.automaticTitle)\u{201D}."),
                           placeholder: pin.automaticTitle,
                           initial: pin.customName ?? "") { name in
                app.renamePin(pin.id, to: name)
            }
            .presentationBackground(.clear)
        }
    }

    /// Opening and closing the menu, and on iPad the page moving aside for it.
    static let menuAnimation = Animation.easeOut(duration: 0.15)

    // MARK: Sidebar

    /// The menu row that matches what's on screen.
    private var sidebarTarget: SidebarItem {
        switch selection {
        case .home: return .home
        #if os(tvOS)
        // The Apple TV's menu has a row for each library and none for all of them.
        case .librariesOverview: return libraries.first.map { .library($0.id) } ?? .home
        case .library(let id): return .library(id)
        #else
        case .librariesOverview: return .libraries
        case .library(let id): return librariesExpanded ? .library(id) : .libraries
        #endif
        case .pinned(let id): return .pinned(id)
        case .favorites: return .favorites
        case .watchlist: return .watchlist
        case .liveTV: return .liveTV
        case .collections: return .collections
        case .search: return .search
        case .settings: return .settings
        case .downloads: return .downloads
        case .requests: return .requests
        case .together: return .together
        }
    }

    /// Floating glass panel when open. Collapsed to icons, a quiet strip on
    /// iPad and nothing at all on the Apple TV, where the icons sit straight
    /// on the page. The panel is always there, see-through when not in use:
    /// its blur used to be made anew each time the menu opened, in the frame
    /// it began to move. Now it only slides in and fades up.
    private var sidebarPanel: some View {
        ZStack(alignment: .leading) {
            #if !os(tvOS)
            LinearGradient(colors: [.white.opacity(0.035), .white.opacity(0.01)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .trailing) {
                    LinearGradient(colors: [.clear, .white.opacity(0.08), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: 1)
                }
                .frame(width: railWidth)
                .opacity(sidebarExpanded ? 0 : 1)
            #endif
            GlassPanel()
                .shadow(color: .black.opacity(0.5), radius: 40, x: 16)
                .padding(.vertical, 18)
                .padding(.leading, 12)
                .frame(width: Self.menuWidth)
                .offset(x: sidebarExpanded ? 0 : -CGFloat(60).scaled)
                .opacity(sidebarExpanded ? 1 : 0)
        }
        .frame(maxHeight: .infinity)
    }

    /// Room above and below the menu's scrolling list for a focused row's lift.
    private static let menuLiftRoom: CGFloat = 16

    private func sidebar(_ focus: FocusState<SidebarItem?>.Binding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            #if os(tvOS)
            // Who's watching, as the menu's first row: their initial in a ring
            // where the others have an icon, and their name, all in the theme's
            // colours. Choosing it switches user, as
            // Switch User in Settings does. It stays put above the list, which
            // scrolls.
            if let user = app.userName {
                SidebarRow(title: user, icon: "person.crop.circle", monogram: String(user.prefix(1)).uppercased(),
                           selected: false, chevron: false,
                           expanded: sidebarExpanded, id: .profile, focus: focus,
                           moving: $movingRow) { app.beginSwitchUser(fromSettings: false) }
            }
            #else
            // Brand
            HStack(spacing: 14) {
                Image(systemName: "play.fill")
                    .font(.app(17, .bold))
                    .foregroundStyle(.white)
                    .frame(width: CGFloat(44).scaled, height: CGFloat(44).scaled)
                    .background(Theme.gradient(menuColors.palette[0], start: .topLeading, end: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: menuColors.palette[0].0.opacity(0.5), radius: 12, y: 4)
                if sidebarExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        GooseWordmark(size: 26)
                        if let server = app.serverName {
                            Text(server)
                                .font(.app(15))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            // On the icons' centre line: a row centres its 26-point icon in 12
            // points of padding (25 from the edge), and the 44-point tile's
            // centre is 22 in, so 3 more, at the same scale as both.
            .padding(.leading, CGFloat(3).scaled)
            .padding(.bottom, 26 - Self.menuLiftRoom)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Self.menuAnimation) { menuTappedOpen.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(menuTappedOpen ? String(localized: "Close menu") : String(localized: "Open menu"))
            #endif

            // The sections, libraries and pins scroll between the top row and
            // Settings, so any number of pins fits: focus moving down the list
            // scrolls it.
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    #if os(tvOS)
                    NowPlayingMenuRow(expanded: sidebarExpanded, focus: focus)
                    #endif
                    // Favourites and Collections only when there's something in
                    // them, and the one on screen until it's left.
                    ForEach(app.menuSections.filter { app.isShown($0) || isOpen($0) }, id: \.self) { section in
                        sectionRows(section, focus: focus)
                    }

                    if !app.menuPins.isEmpty {
                        if sidebarExpanded {
                            Text("PINNED")
                                .font(.app(14, .heavy))
                                .kerning(1.6)
                                .foregroundStyle(menuColors.palette[0].1)
                                .padding(.leading, 16)
                                .padding(.top, 18)
                                .padding(.bottom, 2)
                        } else {
                            Capsule().fill(.white.opacity(0.12)).frame(width: 28, height: 2)
                                .padding(.leading, 10).padding(.vertical, 12)
                        }
                        ForEach(app.menuPins) { pin in
                            SidebarRow(title: pin.title, icon: pin.icon,
                                       selected: selection == .pinned(pin.id),
                                       expanded: sidebarExpanded, id: .pinned(pin.id), focus: focus,
                                       onRename: { renamingPin = pin }, onRemove: { unpin(pin) },
                                       moving: $movingRow, move: { app.movePin(pin.id, by: $0) }) {
                                open(.pinned(pin.id))
                            }
                        }
                    }
                }
                // Room for a focused row's lift before the clip.
                .padding(.vertical, Self.menuLiftRoom)
            }
            // Clipped top and bottom only: the rows' lift and shadow reach past
            // the sides. A plain clip, not a fading mask, which drew the whole
            // list again off screen on every frame that anything in it moved.
            .scrollClipDisabled()
            .padding(.horizontal, 60)
            .clipped()
            .padding(.horizontal, -60)
            #if !os(tvOS)
            // Where it runs under the profile row: a soft edge, not a cut
            // through the middle of a row that read as two lines of text
            // over each other.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                }
            }
            #endif
            // A row being moved keeps focus while it slides, which the focus
            // engine doesn't scroll for, so the list follows it here.
            .onChange(of: app.pins) { _, _ in follow(movingRow, in: proxy) }
            .onChange(of: app.menuSections) { _, _ in follow(movingRow, in: proxy) }
            .onChange(of: app.libraries.map(\.id)) { _, _ in follow(movingRow, in: proxy) }
            }

            if sidebarExpanded, movingRow != nil {
                Label("Up and down to move it, then press Select", systemImage: "arrow.up.arrow.down")
                    .font(.app(15, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            #if !os(tvOS)
            if sidebarExpanded, movingRow == nil, let user = app.userName {
                // Who's watching
                HStack(spacing: 12) {
                    Text(String(user.prefix(1)).uppercased())
                        .font(.app(17, .heavy))
                        .frame(width: CGFloat(40).scaled, height: CGFloat(40).scaled)
                        .background(Theme.gradient(menuColors.palette[3], start: .topLeading, end: .bottomTrailing),
                                    in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user).font(.app(19, .semibold)).lineLimit(1)
                        Text("Watching now").font(.app(15)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            #endif

            #if !os(tvOS)
            SidebarRow(title: String(localized: "Downloads"), icon: "arrow.down.circle",
                       selected: selection == .downloads,
                       expanded: sidebarExpanded, id: .downloads, focus: focus,
                       moving: $movingRow) { open(.downloads) }
            #endif
            // Asking for what the server hasn't got sits apart from what it
            // has: at the foot, above Settings. There while a Seerr is
            // connected or on offer, and for as long as it's on show.
            if watchesTogether || selection == .together {
                SidebarRow(title: SyncPlay.title, icon: "person.2",
                           selected: selection == .together,
                           expanded: sidebarExpanded, id: .together, focus: focus,
                           moving: $movingRow) { open(.together) }
            }
            if app.showsRequests || selection == .requests {
                SidebarRow(title: String(localized: "Requests", comment: "Menu section and settings page: asking for titles through Seerr"),
                           icon: "plus.rectangle.on.rectangle",
                           selected: selection == .requests,
                           expanded: sidebarExpanded, id: .requests, focus: focus,
                           moving: $movingRow) { open(.requests) }
            }
            SidebarRow(title: String(localized: "Settings"), icon: "gearshape",
                       selected: selection == .settings,
                       expanded: sidebarExpanded, id: .settings, focus: focus,
                       moving: $movingRow) { open(.settings) }
        }
        .padding(.leading, sidebarExpanded ? 28 : 18)
        .padding(.trailing, 18)
        .padding(.vertical, 48)
    }

    /// Whether a section is the one on screen.
    private func isOpen(_ section: MenuSection) -> Bool {
        switch section {
        case .home: selection == .home
        case .libraries: selection == .librariesOverview
        case .favorites: selection == .favorites
        case .watchlist: selection == .watchlist
        case .liveTV: selection == .liveTV
        case .collections: selection == .collections
        case .search: selection == .search
        }
    }

    private func follow(_ row: SidebarItem?, in proxy: ScrollViewProxy) {
        guard let row else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(row) }
    }

    /// One section's row, and for Libraries the libraries under it.
    @ViewBuilder
    private func sectionRows(_ section: MenuSection, focus: FocusState<SidebarItem?>.Binding) -> some View {
        let move = { (offset: Int) in app.moveSection(section, by: offset) }
        switch section {
        case .home:
            SidebarRow(title: String(localized: "Home", comment: "Menu section: the home screen"), icon: MenuGlyph.home.rawValue,
                       selected: selection == .home,
                       expanded: sidebarExpanded, id: .home, focus: focus,
                       moving: $movingRow, move: move) { open(.home) }
        case .libraries:
            #if os(tvOS)
            // Each library is a row of its own, with no Libraries row to open
            // them from. Moved past the first or the last of them, a library
            // takes them all with it, up or down among the sections.
            ForEach(libraries) { library in
                SidebarRow(title: library.displayTitle,
                           icon: library.librarySymbol,
                           selected: selection == .library(library.id),
                           expanded: sidebarExpanded, id: .library(library.id), focus: focus,
                           moving: $movingRow,
                           move: { app.moveLibrary(library.id, by: $0) || move($0) }) {
                    open(.library(library.id))
                }
            }
            #else
            SidebarRow(title: String(localized: "Libraries"), icon: MenuGlyph.libraries.rawValue,
                       selected: selection == .librariesOverview,
                       chevron: libraries.isEmpty ? nil : librariesExpanded,
                       expanded: sidebarExpanded, id: .libraries, focus: focus,
                       moving: $movingRow, move: move) {
                if selection == .librariesOverview {
                    withAnimation(.easeOut(duration: 0.2)) { librariesExpanded.toggle() }
                } else {
                    open(.librariesOverview)
                    withAnimation(.easeOut(duration: 0.2)) { librariesExpanded = true }
                }
            }
            if librariesExpanded && sidebarExpanded && !libraries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(libraries) { library in
                        SidebarRow(title: library.displayTitle,
                                   icon: library.librarySymbol,
                                   selected: selection == .library(library.id),
                                   indented: true,
                                   expanded: sidebarExpanded, id: .library(library.id), focus: focus,
                                   moving: $movingRow, move: { app.moveLibrary(library.id, by: $0) }) {
                            open(.library(library.id))
                        }
                    }
                }
                // Guide line tying the libraries to their parent row
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [menuColors.palette[0].0.opacity(0.6), menuColors.palette[0].1.opacity(0.15)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 2)
                        .padding(.vertical, 6)
                        .padding(.leading, 25)
                }
            }
            #endif
        case .favorites:
            SidebarRow(title: String(localized: "Favourites"), icon: MenuGlyph.favourites.rawValue,
                       selected: selection == .favorites,
                       expanded: sidebarExpanded, id: .favorites, focus: focus,
                       moving: $movingRow, move: move) { open(.favorites) }
        case .watchlist:
            SidebarRow(title: String(localized: "Watchlist", comment: "Menu section: the films marked to be watched"), icon: "bookmark",
                       selected: selection == .watchlist,
                       expanded: sidebarExpanded, id: .watchlist, focus: focus,
                       moving: $movingRow, move: move) { open(.watchlist) }
        case .liveTV:
            SidebarRow(title: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                       icon: "antenna.radiowaves.left.and.right",
                       selected: selection == .liveTV,
                       expanded: sidebarExpanded, id: .liveTV, focus: focus,
                       moving: $movingRow, move: move) { open(.liveTV) }
        case .collections:
            SidebarRow(title: String(localized: "Collections"), icon: MenuGlyph.collections.rawValue,
                       selected: selection == .collections,
                       expanded: sidebarExpanded, id: .collections, focus: focus,
                       moving: $movingRow, move: move) { open(.collections) }
        case .search:
            SidebarRow(title: String(localized: "Search", comment: "Menu section: the search screen"), icon: MenuGlyph.search.rawValue,
                       selected: selection == .search,
                       expanded: sidebarExpanded, id: .search, focus: focus,
                       moving: $movingRow, move: move) { open(.search) }
        }
    }

    #if os(iOS)
    /// iPhone: the sections along the bottom, and the whole menu (libraries,
    /// pins, favourites, collections, profile) a tap away.
    /// The tabs along the foot of a phone's screen: the viewer's choice of up
    /// to four (Settings, Tab Bar), then Menu, which has everything. Held
    /// down, the bar opens that page.
    private var tabBar: some View {
        HStack(spacing: 0) { tabButtons(iconsOnly: false) }
            .padding(.top, 8)
            .background {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                    .ignoresSafeArea(edges: .bottom)
            }
            .simultaneousGesture(tabBarHold)
    }

    /// An iPhone Duo folded: the same tabs as icons in a column at the foot
    /// of the strip beside the camera, where the system stands its own bars.
    private func sideTabBar(edge: HorizontalEdge) -> some View {
        let strip = edge == .trailing ? screenInsets.trailing : screenInsets.leading
        return VStack(spacing: 4) { tabButtons(iconsOnly: true) }
            .padding(.vertical, 8)
            .frame(width: max(min(strip - 20, 60), 44))
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.1)) }
            }
            .simultaneousGesture(tabBarHold)
            .frame(width: strip)
            .padding(.bottom, max(screenInsets.bottom - 12, 12))
            .ignoresSafeArea(.container, edges: [.bottom, edge == .trailing ? .trailing : .leading])
    }

    /// The tabs the viewer chose (Settings, Tab Bar), then Menu, which has
    /// everything.
    @ViewBuilder
    private func tabButtons(iconsOnly: Bool) -> some View {
        let choices = app.tabChoices()
        let shown = app.tabBar.compactMap { id in choices.first { $0.id == id } }
            .filter { $0.id != "together" || watchesTogether }
        ForEach(shown) { choice in
            if let destination = Self.destination(of: choice.id) {
                tab(choice.title, glyph: MenuGlyph(rawValue: choice.icon),
                    symbol: MenuGlyph(rawValue: choice.icon) == nil ? choice.icon : nil,
                    selected: tabSelected(choice.id, destination, among: shown), iconsOnly: iconsOnly) { open(destination) }
            }
        }
        tab(String(localized: "Menu", comment: "Opens the full menu"), symbol: "line.3.horizontal", selected: false, iconsOnly: iconsOnly) {
            withAnimation(Self.menuAnimation) { menuTappedOpen = true }
        }
    }

    /// Held down, the tab bar opens its page in Settings.
    private var tabBarHold: some Gesture {
        LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            show(.settings)
            settingsPath = NavigationPath()
            settingsPath.append(SettingsRoute.tabBar)
        }
    }

    /// Where a tab goes, by its `AppState.TabChoice` id.
    private static func destination(of id: String) -> Selection? {
        if id.hasPrefix("library:") { return .library(String(id.dropFirst("library:".count))) }
        if id.hasPrefix("pinned:") { return UUID(uuidString: String(id.dropFirst("pinned:".count))).map { .pinned($0) } }
        switch id {
        case "home": return .home
        case "libraries": return .librariesOverview
        case "search": return .search
        case "downloads": return .downloads
        case "liveTV": return .liveTV
        case "favorites": return .favorites
        case "watchlist": return .watchlist
        case "collections": return .collections
        case "requests": return .requests
        case "together": return .together
        case "settings": return .settings
        default: return nil
        }
    }

    /// The tab of the section on show. A library or a pinned view with no tab
    /// of its own lights Libraries, which is where it's reached from.
    private func tabSelected(_ id: String, _ destination: Selection, among shown: [AppState.TabChoice]) -> Bool {
        if selection == destination { return true }
        guard id == "libraries" else { return false }
        switch selection {
        case .library(let library): return !shown.contains { $0.id == "library:" + library }
        case .pinned(let pin): return !shown.contains { $0.id == "pinned:" + pin.uuidString }
        default: return false
        }
    }

    private func tab(_ title: String, glyph: MenuGlyph? = nil, symbol: String? = nil, selected: Bool,
                     iconsOnly: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            // The tab already open goes back to its first screen.
            if selected { popToRoot() } else { action() }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let glyph { MenuGlyphView(glyph: glyph, size: 24) }
                    else if let symbol { Image(systemName: symbol).font(.system(size: 19, weight: .semibold)) }
                }
                .frame(height: 26)
                if !iconsOnly { Text(title).font(.app(11, .semibold)).lineLimit(1) }
            }
            .foregroundStyle(selected ? menuColors.accent : Color.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            // In a column, each icon a finger's height, the one on show lit.
            .frame(height: iconsOnly ? 48 : nil)
            .background {
                if iconsOnly, selected { Capsule().fill(.white.opacity(0.12)).padding(.horizontal, 4) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func popToRoot() {
        switch selection {
        case .home: homePath = NavigationPath()
        case .librariesOverview, .library, .pinned: librariesPath = NavigationPath()
        case .favorites: favoritesPath = NavigationPath()
        case .watchlist: watchlistPath = NavigationPath()
        case .collections: collectionsPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .settings: settingsPath = NavigationPath()
        case .requests: requestsPath = NavigationPath()
        case .downloads, .liveTV, .together: break
        }
    }
    #endif

    /// A row was chosen in the menu: its section opens, focus goes into the
    /// page and the menu closes behind it. The same for the row of the
    /// section already on show, which is how to get back into its page.
    private func open(_ destination: Selection) {
        menuTappedOpen = false
        show(destination)
        app.leaveMenu()
    }

    /// Every change of section goes by here, so that the colours change
    /// before the page does. The Requests section wears a scheme of its own,
    /// and a page first drawn under the wrong one keeps what it took from
    /// it: back on Home, the picture's fade stayed the other scheme's.
    private func show(_ destination: Selection) {
        let requests = destination == .requests
        if app.inRequests != requests { app.inRequests = requests }
        if destination != selection { selection = destination }
    }

    /// Takes a pin out of the menu (gone, unless it's a row on Home); if it's
    /// open, falls back to its library unfiltered.
    private func unpin(_ pin: PinnedFilter) {
        if selection == .pinned(pin.id) { show(.library(pin.libraryId)) }
        grids.forget(pin.id.uuidString)
        app.setPin(pin.id, inMenu: false)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            HomeView(path: $homePath, scrollToTopRequest: homeScrollRequest, shelves: homeShelves)
        case .librariesOverview:
            LibrariesView(path: $librariesPath)
        case .library(let id):
            if let library = libraries.first(where: { $0.id == id }) {
                NavigationStack(path: $librariesPath) {
                    Group {
                        if library.holdsMusic {
                            MusicLibraryView(library: library)
                        } else if library.holdsBooks {
                            AudiobookLibraryView(library: library)
                        } else {
                            LibraryGrid(library: library,
                                        model: grids.model(id, filters: app.savedFilters(for: id), remembersFilters: true))
                        }
                    }
                    .sectionDestinations()
                }
                .sectionNavigation(path: $librariesPath, section: "libraries")
                .id(id)   // its own identity per library, so state can't bleed between them
            }
        case .pinned(let id):
            if let pin = app.pins.first(where: { $0.id == id }),
               let library = libraries.first(where: { $0.id == pin.libraryId }) {
                NavigationStack(path: $librariesPath) {
                    LibraryGrid(library: library,
                                model: grids.model(id.uuidString, filters: pin.filters))
                        .sectionDestinations()
                }
                .sectionNavigation(path: $librariesPath, section: "libraries")
                .id(id)
            }
        case .favorites:
            NavigationStack(path: $favoritesPath) {
                ItemListGridView(title: String(localized: "Favourites"),
                                 eyebrow: String(localized: "Everything you've marked", comment: "Eyebrow above the Favourites title"),
                                 accent: Theme.palette[1],
                                 showDetails: { favoritesPath.append($0) }) {
                    try await $0.favorites()
                }
                .sectionDestinations()
            }
            .sectionNavigation(path: $favoritesPath, section: "favorites")
        case .watchlist:
            NavigationStack(path: $watchlistPath) {
                ItemListGridView(title: String(localized: "Watchlist", comment: "Menu section: the films marked to be watched"),
                                 eyebrow: String(localized: "Films you mean to watch", comment: "Eyebrow above the Watchlist title"),
                                 accent: Theme.palette[2],
                                 showDetails: { watchlistPath.append($0) },
                                 // Films to choose between: their pages say what they are.
                                 opensDetails: true) {
                    try await $0.watchlist()
                }
                .sectionDestinations()
            }
            .sectionNavigation(path: $watchlistPath, section: "watchlist")
        case .collections:
            CollectionsView(path: $collectionsPath)
        case .liveTV:
            LiveTVView(place: liveGuide)
        case .search:
            SearchView(path: $searchPath)
        case .requests:
            RequestsView(requests: app.requests, path: $requestsPath)
        case .together:
            WatchTogetherView()
        case .settings:
            SettingsView(path: $settingsPath)
        case .downloads:
            #if !os(tvOS)
            DownloadsView()
            #else
            EmptyView()
            #endif
        }
    }

    private var backAction: (() -> Void)? {
        if movingRow != nil { return { movingRow = nil } }
        switch selection {
        case .home:
            // Back on Home steps outward: pop a pushed screen, then jump to the
            // top, then open the menu. From the open menu it leaves the app.
            if !homePath.isEmpty { return { pop(&homePath) } }
            if menuFocused { return nil }
            // Whether Home is below its top is asked when back is pressed:
            // kept here as state, every move between the top row and the
            // next redrew the menu and all of Home.
            return { [homeShelves] in
                if homeShelves.scrolledDown {
                    homeScrollRequest += 1
                } else {
                    menuFocusRequest = .home
                }
            }
        case .library(let id):
            return librariesPath.isEmpty ? stepOut(of: grids.existing(id)) : { pop(&librariesPath) }
        case .pinned(let id):
            return librariesPath.isEmpty ? stepOut(of: grids.existing(id.uuidString)) : { pop(&librariesPath) }
        case .librariesOverview:
            return librariesPath.isEmpty ? stepOut() : { pop(&librariesPath) }
        case .favorites:
            return favoritesPath.isEmpty ? stepOut() : { pop(&favoritesPath) }
        case .watchlist:
            return watchlistPath.isEmpty ? stepOut() : { pop(&watchlistPath) }
        case .collections:
            return collectionsPath.isEmpty ? stepOut() : { pop(&collectionsPath) }
        case .search:
            return searchPath.isEmpty ? stepOut() : { pop(&searchPath) }
        case .requests:
            return requestsPath.isEmpty ? stepOut() : { pop(&requestsPath) }
        case .settings:
            return settingsPath.isEmpty ? stepOut() : { pop(&settingsPath) }
        case .liveTV:
            #if os(tvOS)
            // The guide's top first, as a library's is: the first channel
            // and now. From there, or from the menu, as anywhere else.
            if !menuFocused {
                return { [liveGuide] in
                    if liveGuide.isAway() { liveGuide.returns.send() } else { menuFocusRequest = sidebarTarget }
                }
            }
            #endif
            return stepOut()
        case .downloads, .together:
            return stepOut()
        }
    }

    /// Back at a section's own page, as on Home: a library below its top row
    /// goes to its first title; otherwise the menu opens, on this section's
    /// row. From the open menu it goes to Home, the menu still open, and only
    /// from there does back leave the app: out is always by way of Home.
    private func stepOut(of grid: LibraryGridModel? = nil) -> (() -> Void)? {
        if menuFocused {
            return {
                show(.home)
                menuFocusRequest = .home
            }
        }
        return {
            #if os(tvOS)
            if let grid, grid.bandRow > 0, let returnToTop = grid.returnToTop {
                returnToTop()
                return
            }
            #endif
            menuFocusRequest = sidebarTarget
        }
    }

    /// Back swaps the focused screen away, so keep the fallback out of the menu.
    private func pop(_ path: inout NavigationPath) {
        app.holdMenuFocus()
        path.removeLast()
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    /// A letter in a ring in the icon's place: who's watching.
    var monogram: String? = nil
    let selected: Bool
    /// nil hides the disclosure chevron; true/false points it down/right.
    var chevron: Bool? = nil
    var indented: Bool = false
    let expanded: Bool
    let id: MainTabView.SidebarItem
    var focus: FocusState<MainTabView.SidebarItem?>.Binding
    /// When set, long-pressing the row offers renaming and removal (and moving,
    /// with `move` below).
    var onRename: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    /// The menu's row being moved, if any; every other row stands aside meanwhile.
    var moving: Binding<MainTabView.SidebarItem?>? = nil
    /// When set, the row can be moved: shifts it by one place, false at an end.
    var move: ((Int) -> Bool)? = nil
    let action: () -> Void

    private var isMoving: Bool { moving?.wrappedValue == id }
    private var otherRowMoving: Bool { moving?.wrappedValue.map { $0 != id } ?? false }
    /// The menu's scheme, handed down to it: the app's own, not whatever
    /// the section on show is wearing.
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            if isMoving { moving?.wrappedValue = nil } else { action() }
        } label: {
            HStack(spacing: 14) {
                Group {
                    // The sections' own outlines; anything else (a library,
                    // a pinned row, Settings) is a system symbol.
                    if let monogram {
                        // In the theme's colours like the name beside it,
                        // with focus or without.
                        Text(monogram)
                            .font(.app(13, .heavy))
                            .frame(width: CGFloat(26).scaled, height: CGFloat(26).scaled)
                            .overlay(Circle().strokeBorder(lineWidth: 2))
                            .foregroundStyle(Theme.gradient(theme.colors.palette[0], start: .topLeading, end: .bottomTrailing))
                    } else if let glyph = MenuGlyph(rawValue: icon) {
                        MenuGlyphView(glyph: glyph, size: CGFloat(indented ? 20 : 26).scaled)
                    } else {
                        Image(systemName: icon)
                            .font(.app(indented ? 15 : 18, .semibold))
                    }
                }
                .frame(width: CGFloat(26).scaled)
                if expanded {
                    if monogram != nil {
                        // The viewer's name in the theme's colours, as the
                        // app's own name is written, with focus or without.
                        Text(title)
                            .font(.app(21, .semibold))
                            .foregroundStyle(Theme.gradient(theme.colors.palette[0], start: .leading, end: .trailing))
                            .lineLimit(1)
                    } else {
                    Text(title)
                        .font(.app(indented ? 19 : 21, selected ? .bold : .medium))
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isMoving {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.app(14, .bold))
                    } else if let chevron {
                        Image(systemName: "chevron.right")
                            .font(.app(12, .bold))
                            .rotationEffect(.degrees(chevron ? 90 : 0))
                            .opacity(0.55)
                    }
                }
            }
        }
        // The row reads its own focus in its style, so a press up or down the
        // menu redraws the row left and the row reached, not every row.
        .buttonStyle(SidebarRowStyle(selected: selected, indented: indented,
                                     expanded: expanded, isMoving: isMoving))
        .accessibilityLabel(title)
        .focused(focus, equals: id)
        .focusEffectDisabled()   // the white row fill is the focus indicator
        // Other rows can't take focus while one moves, so up and down reach it here.
        .disabled(otherRowMoving)
        .tvMoveCommand { direction in
            guard isMoving, let move else { return }
            switch direction {
            case .up: withAnimation(.easeOut(duration: 0.2)) { _ = move(-1) }
            case .down: withAnimation(.easeOut(duration: 0.2)) { _ = move(1) }
            default: break
            }
        }
        .rowMenu(onMove: move == nil ? nil : { moving?.wrappedValue = id },
                 onRename: onRename, onRemove: onRemove)
        .id(id)   // for the menu's scroll to find while the row moves
        .accessibilityActions {
            if let move {
                Button("Move up") { withAnimation { _ = move(-1) } }
                Button("Move down") { withAnimation { _ = move(1) } }
            }
        }
    }
}

/// A menu row's look. On the Apple TV the white fill is the one highlight, for
/// the row with focus; the screen on show is marked by white words and a small
/// bar in the theme's colours. On iPad, where nothing has focus, the screen on
/// show takes the theme's gradient. No system chrome, no halo.
private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    let indented: Bool
    let expanded: Bool
    let isMoving: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme

    /// Whether the screen on show fills its row, rather than marking it.
    private static var fillsSelected: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private var fill: AnyShapeStyle {
        if focused { return AnyShapeStyle(Color.white) }
        if selected, Self.fillsSelected {
            return AnyShapeStyle(Theme.gradient(theme.colors.palette[0], start: .topLeading, end: .bottomTrailing))
        }
        return AnyShapeStyle(Color.clear)
    }

    func makeBody(configuration: Configuration) -> some View {
        let filled = focused || (selected && Self.fillsSelected)
        configuration.label
            .foregroundStyle(focused ? .black : (selected ? .white : .white.opacity(0.62)))
            .padding(.vertical, CGFloat(indented ? 9 : 12).scaled)
            .padding(.horizontal, CGFloat(expanded ? 16 : 12).scaled)
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            #if !os(tvOS)
            // The whole row takes a tap, not only what's drawn in it. A
            // section's icon is an outline, and a row that isn't the one on
            // show has nothing behind it: a finger on the icon went between
            // its lines to the rail beneath, which opened the menu instead.
            .contentShape(Rectangle())
            #endif
            .background(RoundedRectangle(cornerRadius: 14).fill(fill))
            .pointerWash(cornerRadius: 14)
            .overlay(alignment: .leading) {
                if !Self.fillsSelected {
                    Capsule()
                        .fill(Theme.gradient(theme.colors.palette[0], start: .top, end: .bottom))
                        .frame(width: 4, height: CGFloat(20).scaled)
                        .padding(.leading, expanded ? 3 : 0)
                        .opacity(selected && !focused ? 1 : 0)
                }
            }
            // The colours swap at once as focus comes and goes; only the lift
            // animates. Faded, a row went pale with its words half-gone.
            .transaction(value: focused) { $0.animation = nil }
            // An icon on the bare rail has a picture behind it at times, so it
            // carries a soft shadow of its own.
            .shadow(color: focused ? .black.opacity(0.35)
                        : (filled ? theme.colors.palette[0].0.opacity(0.35) : (expanded ? .clear : .black.opacity(0.5))),
                    radius: focused ? 14 : (filled || expanded ? 10 : 6), y: filled ? 5 : 1)
            .scaleEffect(isMoving ? 1.08 : (focused ? 1.04 : (configuration.isPressed ? 0.96 : 1)))
            .padding(.leading, (expanded && indented) ? CGFloat(36).scaled : 0)
            .animation(.easeOut(duration: 0.1), value: focused)
            .animation(.easeOut(duration: 0.1), value: isMoving)
    }
}

/// The menu as a focus section, or not one (see `SidebarFocusHost`).
private struct MenuRegion: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.focusSection()
        #else
        content
        #endif
    }
}

/// The page as one region to the focus engine, beginning where the open
/// menu ends (see where it's used). While the search keyboard has focus it
/// reaches out to the screen's edge instead, under where the rail stood:
/// the keyboard takes a move to its left by a strip of its own lying just
/// off its leading edge, which is out there.
private struct PageRegion: ViewModifier {
    @ObservedObject var hold: MenuFocusHold
    let overlap: CGFloat
    let rail: CGFloat

    func body(content: Content) -> some View {
        // The same views either way, only laid out to a different edge: the
        // page isn't to be made again for a keyboard taking focus.
        let inset = hold.typing ? -rail : overlap
        content
            .padding(.leading, -inset)
            .tvFocusSection()
            .padding(.leading, inset)
    }
}

/// Holds which menu row has focus, so that moving up and down the menu is
/// news only to the rows. The screen hears when focus enters or leaves the
/// menu, and asks for a row through `request`.
struct SidebarFocusHost<Content: View>: View {
    @Binding var focused: Bool
    @Binding var request: MainTabView.SidebarItem?
    @Binding var moving: MainTabView.SidebarItem?
    /// The row for the screen on show.
    let target: MainTabView.SidebarItem
    /// Set briefly after back, while the page's focus settles.
    @ObservedObject var hold: MenuFocusHold
    @ViewBuilder let content: (FocusState<MainTabView.SidebarItem?>.Binding) -> Content

    @FocusState private var focus: MainTabView.SidebarItem?

    var body: some View {
        Group {
            // Not there at all while the search keyboard has focus. The
            // keyboard is one thing to the focus engine, and moves along
            // its own letters by two strips of its own, one lying just off
            // each end of it: a press toward an end is caught by the strip
            // there and handed back to the keyboard, which moves a letter.
            // The strip off its leading end lies where the rail stands.
            // With the rail's rows able to take focus, a press left went to
            // the menu; with them switched off (and, later, the menu's
            // region taken away as well) it went nowhere on a television,
            // though a simulator let it through: the letters could be gone
            // forward along and not back. So the rail goes, views and all,
            // for as long as the keyboard has focus, and nothing of the
            // app's lies over the strip.
            if !hold.typing {
                content($focus)
                    // One region to the focus engine, so that a press toward
                    // the menu lands in it wherever its rows are.
                    .modifier(MenuRegion())
                    .transition(.opacity)
            }
        }
            .animation(.easeOut(duration: 0.15), value: hold.typing)
            .defaultFocus($focus, target, priority: .userInitiated)
            // That default focus also claims focus whenever the content loses it
            // (e.g. a detail page popping), which popped the menu open on back.
            // And while a row's choice sends focus into the page, it has to
            // let go of it.
            // Nor does it take focus from the search keyboard, whose letters
            // are to the right of it and not the focus engine's to move among.
            .disabled(hold.leaving || hold.typing || (hold.held && !focused))
            .background {
                SidebarFocusWatcher(focus: $focus, focused: $focused, moving: $moving, target: target, hold: hold)
            }
            // Switched off alone, the row in focus keeps it until something
            // asks for focus to move; this asks.
            .onChange(of: hold.leaving) { _, leaving in
                if leaving { focus = nil }
            }
            .onChange(of: request) { _, row in
                guard let row else { return }
                guard hold.holding else {
                    focus = row
                    request = nil
                    return
                }
                // Asked for while it's kept off (from the search keyboard,
                // or just after a long-press menu has closed): switched on
                // again first, and given the focus once it can take it. From
                // the keyboard that is once its rows are back on the screen.
                let rebuilt = hold.typing
                hold.letGo()
                Task {
                    try? await Task.sleep(for: .milliseconds(rebuilt ? 220 : 60))
                    focus = row
                    request = nil
                }
            }
    }
}

/// The one view that reads the focused row, so that it alone redraws with it.
private struct SidebarFocusWatcher: View {
    var focus: FocusState<MainTabView.SidebarItem?>.Binding
    @Binding var focused: Bool
    @Binding var moving: MainTabView.SidebarItem?
    let target: MainTabView.SidebarItem
    let hold: MenuFocusHold

    var body: some View {
        Color.clear
            .onChange(of: focus.wrappedValue) { old, new in
                if focused != (new != nil) { focused = new != nil }
                hold.menuFocused = new != nil
                // Entering the menu lands on the row for the current screen, not
                // the row nearest to where focus came from. Library sub-rows only
                // exist once the menu has expanded, so the hop happens a beat after
                // entry. A row picked to move from its long-press menu keeps focus
                // as the menu closes.
                guard old == nil, let new, new != target, moving == nil else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard moving == nil else { return }
                    focus.wrappedValue = target
                }
            }
    }
}

private extension View {
    @ViewBuilder
    func rowMenu(onMove: (() -> Void)?, onRename: (() -> Void)?, onRemove: (() -> Void)?) -> some View {
        if onMove != nil || onRename != nil || onRemove != nil {
            contextMenu {
                if let onMove {
                    Button("Move", systemImage: "arrow.up.arrow.down", action: onMove)
                }
                if let onRename {
                    Button("Rename", systemImage: "pencil", action: onRename)
                }
                if let onRemove {
                    Button("Remove from menu", systemImage: "pin.slash", role: .destructive, action: onRemove)
                }
            }
        } else {
            self
        }
    }
}

#if os(iOS)
/// Only for the downloads' background session: the system wakes the app to say
/// they've finished, and waits to hear that the app has taken them in.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A finished download's banner, and where choosing it goes.
        UNUserNotificationCenter.current().delegate = DownloadNotices.shared
        // Downloads coming down, on the Lock Screen and in the Dynamic Island.
        MainActor.assumeIsolated { DownloadActivity.shared.start() }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            Downloads.shared.backgroundCompletion = completionHandler
        }
    }
}
#endif

private struct MenuShiftKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far the open menu has slid the page aside: something that should
    /// stay put on screen offsets itself back by this much.
    var menuShift: CGFloat {
        get { self[MenuShiftKey.self] }
        set { self[MenuShiftKey.self] = newValue }
    }
}
