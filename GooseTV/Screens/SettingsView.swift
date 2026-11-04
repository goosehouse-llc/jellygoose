import SwiftUI

struct SettingsView: View {
    @Environment(\.isNarrow) private var narrow
    @EnvironmentObject var app: AppState
    @ObservedObject private var unlock = Unlock.shared
    @ObservedObject private var sync = SettingsSync.shared
    @Binding var path: NavigationPath
    @State private var confirmingSignOut = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case user, playback, signOut }
    @AppStorage(PlaybackPreferences.maxBitrateKey) private var maxBitrate = PlaybackPreferences.autoBitrate
    @AppStorage(PlaybackPreferences.directPlayKey) private var directPlay = true

    var body: some View {
        NavigationStack(path: $path) {
            grid
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .playback: PlaybackSettingsView()
                    case .subtitles: SubtitleSettingsView()
                    case .about: AboutView(path: $path)
                    case .licenses: LicensesView()
                    case .libraries: LibrarySettingsView(path: $path)
                    case .appearance: AppearanceSettingsView()
                    case .requests: RequestsSettingsView(requests: app.requests)
                    case .liveTV: LiveTVSettingsView()
                    case .home: HomeLayoutSettingsView()
                    case .tabBar: TabBarSettingsView()
                    case .sync: SyncSettingsView()
                    case .plugins: PluginSettingsView(path: $path)
                    case .dashboard: DashboardView()
                    case .library(let library): LibraryDetailView(library: library)
                    case .plugin(let id): PluginDetailView(id: id)
                    }
                }
        }
        // Coming in from the menu, land on the first tile rather than whatever
        // happens to line up with the press (which was Sign Out).
        .defaultFocus($focus, .user, priority: .userInitiated)
        .task { await app.loadPreferences() }
        #if DEBUG
        .task {
            // GOOSETV_SETTINGS=plugins, or plugin:<id>, opens that page, to see it.
            guard let page = ProcessInfo.processInfo.environment["GOOSETV_SETTINGS"], path.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if page == "plugins" || page.hasPrefix("plugin:") { path.append(SettingsRoute.plugins) }
            if page == "dashboard" { path.append(SettingsRoute.dashboard) }
            if page.hasPrefix("plugin:") { path.append(SettingsRoute.plugin(String(page.dropFirst("plugin:".count)))) }
        }
        #endif
        .task {
            // Asked for from a Home with nothing on it: straight to the page
            // that says what Home shows. A moment after Settings is on
            // screen, since coming to the section sets it at its first page.
            guard app.homeSettingsWanted else { return }
            app.homeSettingsWanted = false
            try? await Task.sleep(for: .milliseconds(250))
            if path.isEmpty { path.append(SettingsRoute.home) }
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings")
                        .font(.app(26, .bold))
                    Spacer()
                    Button("Sign Out") { confirmingSignOut = true }
                        .buttonStyle(.signOut)
                        .focused($focus, equals: .signOut)
                        // Signing out can't be backed out of, so ask first.
                        .confirmationDialog("Sign out of \(app.serverName ?? String(localized: "this server"))?",
                                            isPresented: $confirmingSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) { app.signOut() }
                            Button("Cancel", role: .cancel) {}
                        }
                }
                // Sign Out is off on its own at the top right; a section keeps a press
                // from the tiles below from having to line up with it.
                .tvFocusSection()

                // One column of tiles on the left, at the width a two-column grid gives them.
                SettingsColumn {
                    userBanner
                    SettingsRow(icon: "play.fill", accent: Theme.palette[0],
                                title: String(localized: "Playback"),
                                subtitle: playbackSubtitle) {
                        path.append(SettingsRoute.playback)
                    }
                    .focused($focus, equals: .playback)
                    SettingsRow(icon: "rectangle.stack.fill", accent: Theme.palette[2],
                                title: String(localized: "Libraries"),
                                subtitle: librariesSubtitle) {
                        path.append(SettingsRoute.libraries)
                    }
                    // What the server is doing, and its plugins: Jellyfin's, for whoever runs it.
                    if app.isAdmin, app.serverFlavor == .jellyfin {
                        SettingsRow(icon: "gauge.with.dots.needle.67percent", accent: Theme.palette[1],
                                    title: String(localized: "Dashboard", comment: "Settings tile and page: what the server is doing, for its administrators"),
                                    subtitle: String(localized: "Who's watching, and what the server is doing", comment: "Settings tile subtitle: the Dashboard page")) {
                            path.append(SettingsRoute.dashboard)
                        }
                    }
                    if app.isAdmin, app.serverFlavor == .jellyfin {
                        SettingsRow(icon: "puzzlepiece.extension.fill", accent: Theme.palette[3],
                                    title: String(localized: "Plugins", comment: "Settings tile and page: the server's plugins"),
                                    subtitle: String(localized: "Add to what your server does", comment: "Settings tile subtitle: the Plugins page")) {
                            path.append(SettingsRoute.plugins)
                        }
                    }
                    SettingsRow(icon: "house.fill", accent: Theme.palette[0],
                                title: String(localized: "Home Screen", comment: "Settings page: which rows Home shows, and their order"),
                                subtitle: String(localized: "Rows and their order", comment: "Settings tile subtitle: the Home Screen page arranges Home's rows")) {
                        path.append(SettingsRoute.home)
                    }
                    // Only where there's a tab bar: a phone, or an iPad app
                    // sharing the screen at a phone's width.
                    if narrow {
                        SettingsRow(icon: "dock.rectangle", accent: Theme.palette[2],
                                    title: String(localized: "Tab Bar", comment: "Settings page: the tabs along the foot of a phone's screen"),
                                    subtitle: tabBarSubtitle) {
                            path.append(SettingsRoute.tabBar)
                        }
                    }
                    SettingsRow(icon: "server.rack", accent: Theme.palette[2],
                                title: String(localized: "Server", comment: "Settings tile for the Jellyfin server this Apple TV is connected to"),
                                subtitle: serverSubtitle) {
                        app.beginServerChange()
                    }
                    SettingsRow(icon: "captions.bubble.fill", accent: Theme.palette[1],
                                title: String(localized: "Subtitles"),
                                subtitle: subtitlesSubtitle) {
                        path.append(SettingsRoute.subtitles)
                    }
                    // Only where the server has television to show: the
                    // tile is how the menu's row is brought back, so it stays
                    // while the row is off.
                    if app.hasLiveTV {
                        SettingsRow(icon: "antenna.radiowaves.left.and.right", accent: Theme.palette[2],
                                    title: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                                    subtitle: app.showsLiveTV ? LiveTVView.count(app.liveChannelCount)
                                                              : String(localized: "Hidden from the menu", comment: "Settings tile subtitle: Live TV is turned off on this device")) {
                            path.append(SettingsRoute.liveTV)
                        }
                    }
                    // Seerr signs the viewer in by Quick Connect, which only
                    // Jellyfin has.
                    if app.serverFlavor.supportsQuickConnect || app.requests.client != nil {
                        SettingsRow(icon: "plus.rectangle.on.rectangle.fill", accent: Theme.palette[0],
                                    title: String(localized: "Requests", comment: "Menu section and settings page: asking for titles through Seerr"),
                                    subtitle: app.requests.client.map { String(localized: "Connected to \($0.base.host ?? $0.base.absoluteString)", comment: "The placeholder is the address of the Seerr the app is connected to") }
                                        ?? String(localized: "Connect to Seerr", comment: "Settings tile subtitle when no Seerr is connected")) {
                            path.append(SettingsRoute.requests)
                        }
                    }
                    SettingsRow(icon: "paintpalette.fill", accent: Theme.palette[3],
                                title: String(localized: "Appearance"),
                                subtitle: app.theme.label) {
                        path.append(SettingsRoute.appearance)
                    }
                    SettingsRow(icon: sync.isOn ? "icloud.fill" : "icloud.slash.fill", accent: Theme.palette[3],
                                title: SettingsSync.title,
                                subtitle: sync.isOn ? String(localized: "Settings shared with your other devices", comment: "Settings tile subtitle: iCloud Sync is on")
                                                    : String(localized: "Off", comment: "Settings tile subtitle: iCloud Sync is off")) {
                        path.append(SettingsRoute.sync)
                    }
                    SettingsRow(icon: unlock.state == .unlocked ? "checkmark.seal.fill" : "lock.open.fill", accent: Theme.palette[1],
                                title: String(localized: "JellyGoose Unlock", comment: "Settings tile: the free trial and the one-time unlock"),
                                subtitle: unlockSubtitle) {
                        UnlockStage.shared.show()
                    }
                    SettingsRow(icon: "info.circle.fill", accent: Theme.palette[3],
                                title: String(localized: "About", comment: "Settings tile for app and server information"),
                                subtitle: "JellyGoose \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")") {
                        path.append(SettingsRoute.about)
                    }
                }
            }
            .padding(.horizontal, narrow ? 20 : 40)
            .padding(.vertical, 48)
        }
        .pageSides()
    }

    private var tabBarSubtitle: String {
        let choices = app.tabChoices()
        return app.tabBar.compactMap { id in choices.first { $0.id == id }?.title }.joined(separator: " · ")
    }

    private var unlockSubtitle: String {
        switch unlock.state {
        case .unlocked, .checking: String(localized: "Unlocked", comment: "Settings tile subtitle: JellyGoose is bought or was had before it was sold")
        case .trial: String(localized: "Free trial, days left: \(unlock.daysLeft ?? 1)", comment: "Settings tile subtitle during the trial. The placeholder is a number of days, 1 to 7")
        case .trialEnded: String(localized: "Free trial ended", comment: "Settings tile subtitle after the trial, before buying")
        case .notStarted: String(localized: "Free for \(Unlock.trialDays) days, then a one-time unlock", comment: "Settings tile subtitle before the trial. The placeholder is the number of days, 7")
        }
    }

    private var playbackSubtitle: String {
        var parts = [maxBitrate == PlaybackPreferences.autoBitrate ? String(localized: "Auto quality")
                                                                   : PlaybackPreferences.bitrateLabel(maxBitrate)]
        parts.append(directPlay ? String(localized: "Direct play on") : String(localized: "Always transcode"))
        if let preferences = app.preferences {
            parts.append(preferences.autoPlayNextEpisode ? String(localized: "Auto next episode on") : String(localized: "Auto next episode off"))
        }
        return parts.joined(separator: " · ")
    }

    private var subtitlesSubtitle: String {
        guard let preferences = app.preferences else { return String(localized: "Loading…") }
        if preferences.subtitleMode == .none { return String(localized: "Off", comment: "Subtitles are turned off") }
        return "\(preferences.subtitleLanguageName) · \(preferences.subtitleMode.label)"
    }

    /// Who's signed in: the same banner as before, at the width of the tiles below it.
    private var userBanner: some View {
        HStack(spacing: narrow ? 14 : 24) {
            Text(String(app.userName?.prefix(1) ?? "?").uppercased())
                .font(.app(30, .heavy))
                .frame(width: CGFloat(72).scaled, height: CGFloat(72).scaled)
                .background(.white.opacity(0.22), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.userName ?? "—")
                    .font(.app(24, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(app.serverName ?? app.serverFlavor.label) · connected")
                    .font(.app(16))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Switch User") { app.beginSwitchUser() }
                .buttonStyle(.ghost)
                .fixedSize()
                .focused($focus, equals: .user)
        }
        .padding(.horizontal, CGFloat(narrow ? 18 : 30).scaled)
        .padding(.vertical, CGFloat(24).scaled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing)
                // Ghosted poster fan, echoing the collage cards
                HStack(spacing: -26) {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.18))
                        .frame(width: 80, height: 120).rotationEffect(.degrees(-10))
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12))
                        .frame(width: 80, height: 120).rotationEffect(.degrees(4))
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                        .frame(width: 80, height: 120).rotationEffect(.degrees(16))
                }
                .offset(x: -100, y: -30)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
        )
    }

    private var librariesSubtitle: String {
        let libraries = app.libraries
        guard !libraries.isEmpty else { return String(localized: "Add, remove, and scan", comment: "Libraries settings tile subtitle when there are no libraries") }
        return libraries.map(\.displayTitle).joined(separator: " · ")
    }

    private var serverSubtitle: String {
        let host = app.client?.baseURL.absoluteString ?? "—"
        if let name = app.serverName { return "\(name) · \(host)" }
        return host
    }
}

struct SettingsRow: View {
    let icon: String
    let accent: (Color, Color)
    let title: String
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.app(19, .semibold))
                    .foregroundStyle(.white)
                    .frame(width: CGFloat(46).scaled, height: CGFloat(46).scaled)
                    .background(Theme.gradient(accent, start: .topLeading, end: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.app(20, .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.app(14))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.app(14, .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, CGFloat(22).scaled)
            .padding(.vertical, CGFloat(18).scaled)
        }
        .buttonStyle(SettingsRowStyle())
    }
}

struct SettingsRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.white.opacity(focused ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(focused ? 0.35 : 0), lineWidth: 2))
            .scaleEffect(focused ? 1.015 : (configuration.isPressed ? 0.99 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
            .pointerHover()
    }
}

