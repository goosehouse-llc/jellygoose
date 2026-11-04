import SwiftUI

/// Pages pushed from the Settings grid.
enum SettingsRoute: Hashable {
    case playback, subtitles, about, libraries, appearance, licenses, requests, liveTV, home, tabBar, sync, plugins, dashboard
    case library(VirtualFolder)
    /// One plugin, by its id (PluginKey).
    case plugin(String)
}

// MARK: - Playback

struct PlaybackSettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage(PlaybackPreferences.maxBitrateKey) private var maxBitrate = PlaybackPreferences.autoBitrate
    @AppStorage(PlaybackPreferences.directPlayKey) private var directPlay = true
    @AppStorage(PlaybackPreferences.alwaysVLCKey) private var alwaysVLC = false
    @AppStorage(PlaybackPreferences.vlcForMKVKey) private var vlcForMKV = false
    @AppStorage(PlaybackPreferences.sdrInHDRKey) private var sdrInHDR = false
    @AppStorage(RemoteControl.allowedKey) private var remoteAllowed = true
    @AppStorage(DeviceName.key) private var deviceName = ""
    @AppStorage(PlaybackPreferences.autoSkipIntrosKey) private var autoSkipIntros = false
    #if !os(tvOS)
    @AppStorage(NewEpisodes.enabledKey) private var newEpisodeAlerts = false
    /// Turned on, and the device said no to notifications.
    @State private var alertsRefused = false
    #endif
    @AppStorage(PlaybackPreferences.autoSkipCreditsKey) private var autoSkipCredits = false
    @AppStorage(PlaybackPreferences.autoSkipCommercialsKey) private var autoSkipCommercials = false
    @AppStorage(PlaybackPreferences.autoSkipRecapsKey) private var autoSkipRecaps = false
    @AppStorage(PlaybackPreferences.remembersTracksKey) private var remembersTracks = true
    @AppStorage(ThemeMusic.key) private var themeMusic = true
    #if os(iOS)
    @AppStorage(PlaybackPreferences.downloadsWiFiOnlyKey) private var downloadsWiFiOnly = true
    #endif
    @State private var saveFailed = false
    @State private var preferencesFailed = false

    var body: some View {
        SettingsPage(title: String(localized: "Playback"), accent: Theme.palette[0]) {
            SettingGroup(title: String(localized: "Streaming quality"),
                         detail: {
                            #if os(tvOS)
                            String(localized: "The most this Apple TV will stream. Lower it if playback stutters; the server transcodes anything above it.")
                            #else
                            String(localized: "The most this device will stream. Lower it if playback stutters; the server transcodes anything above it.")
                            #endif
                         }()) {
                ForEach(PlaybackPreferences.bitrateChoices, id: \.bitsPerSecond) { choice in
                    Button(choice.label) { maxBitrate = choice.bitsPerSecond }
                        .buttonStyle(.pill(selected: maxBitrate == choice.bitsPerSecond))
                }
            }

            SettingGroup(title: String(localized: "Direct play"),
                         detail: {
                            #if os(tvOS)
                            String(localized: "Plays files as they are when the Apple TV supports them. Turn off to always stream a transcode instead.")
                            #else
                            String(localized: "Plays files as they are when this device supports them. Turn off to always stream a transcode instead.")
                            #endif
                         }()) {
                OnOffPills(value: directPlay) { directPlay = $0 }
            }

            SettingGroup(title: String(localized: "Video player"),
                         detail: {
                            #if os(tvOS)
                            String(localized: "Automatic plays MKV films straight from the file on the Apple TV, so they start at once and keep Dolby Vision, HDR and Atmos, and plays AV1, VP9, MPEG-2 and other formats the Apple TV can't decode in VLC. VLC for MKV plays MKV files in VLC instead, apart from Dolby Vision. Always VLC uses it for everything.")
                            #else
                            String(localized: "Automatic plays AV1, VP9, MPEG-2 and other formats this device can't decode in VLC, straight from the file. VLC for MKV also plays MKV files there, which starts them sooner; Dolby Vision stays with the system player. Always VLC uses it for everything.")
                            #endif
                         }()) {
                Button("Automatic") { alwaysVLC = false; vlcForMKV = false }
                    .buttonStyle(.pill(selected: !alwaysVLC && !vlcForMKV))
                Button("VLC for MKV") { alwaysVLC = false; vlcForMKV = true }
                    .buttonStyle(.pill(selected: !alwaysVLC && vlcForMKV))
                Button("Always VLC") { alwaysVLC = true; vlcForMKV = false }
                    .buttonStyle(.pill(selected: alwaysVLC))
            }

            #if os(tvOS)
            SettingGroup(title: String(localized: "SDR video in HDR", comment: "Setting: keep the TV in HDR for films and episodes that aren't HDR"),
                         detail: String(localized: "Keeps the TV in HDR for films and episodes that aren't HDR, at their own frame rate, instead of switching it to SDR. Most TVs show HDR much brighter.", comment: "Under the setting for showing standard-range (SDR) video with the TV in HDR")) {
                OnOffPills(value: sdrInHDR) { sdrInHDR = $0 }
            }

            SettingGroup(title: String(localized: "Play on TV", comment: "Title of the list of TVs a film can be played on from the phone, and the button that opens it"),
                         detail: String(localized: "Lets a phone or tablet signed in to your account play films here, and pause, move through or stop them. They list this Apple TV by the name beside the switch.", comment: "Settings, Playback, on the Apple TV: under Play on TV")) {
                OnOffPills(value: remoteAllowed) { on in
                    remoteAllowed = on
                    Task { await RemoteControl.shared.apply() }
                }
                TextField("", text: $deviceName, prompt: Text(verbatim: DeviceName.fallback))
                    .autocorrectionDisabled()
                    .onSubmit { Task { await RemoteControl.shared.apply() } }
                    .frame(width: CGFloat(420).scaled)
                    .accessibilityLabel(String(localized: "This Apple TV's name", comment: "Settings, Play on TV: the field for the name phones list the TV by"))
            }
            #endif

            #if os(iOS)
            SettingGroup(title: String(localized: "Downloads on Wi-Fi only"),
                         detail: String(localized: "Downloads wait for Wi-Fi instead of using mobile data. A change applies to downloads started after it.")) {
                OnOffPills(value: downloadsWiFiOnly) { downloadsWiFiOnly = $0 }
            }
            #endif

            #if !os(tvOS)
            SettingGroup(title: String(localized: "New episode alerts", comment: "Setting: a notification when a show you watch has a new episode"),
                         detail: alertsRefused
                            ? String(localized: "Notifications are turned off for JellyGoose. Turn them on in your device's settings, then here.", comment: "Settings, New episode alerts: the device refused notifications")
                            : String(localized: "A notification when a new episode of a show you watch reaches your server.", comment: "Settings, New episode alerts: what the setting does")) {
                OnOffPills(value: newEpisodeAlerts) { on in
                    if on {
                        Task { alertsRefused = !(await NewEpisodes.shared.turnOn()) }
                    } else {
                        NewEpisodes.shared.turnOff()
                    }
                }
            }
            #endif

            SettingGroup(title: String(localized: "Auto-play next episode"),
                         detail: String(localized: "Starts the next episode when one ends. Saved to your \(app.serverFlavor.label) account.", comment: "The placeholder is the server software's name, Jellyfin or Emby")) {
                if let preferences = app.preferences {
                    OnOffPills(value: preferences.autoPlayNextEpisode) { on in
                        save { $0.autoPlayNextEpisode = on }
                    }
                } else if preferencesFailed {
                    PreferencesRetry(failed: $preferencesFailed)
                } else {
                    ProgressView()
                }
            }

            SettingGroup(title: String(localized: "Skip intros automatically"),
                         detail: String(localized: "Jumps past an intro as it starts, where the server or an episode's chapters mark one. Off, you're offered Skip Intro instead.")) {
                OnOffPills(value: autoSkipIntros) { autoSkipIntros = $0 }
            }

            SettingGroup(title: String(localized: "Skip credits automatically"),
                         detail: String(localized: "Goes straight on as the credits start: to the next episode, or past them to the end. Credits the app has only guessed at are still offered instead.")) {
                OnOffPills(value: autoSkipCredits) { autoSkipCredits = $0 }
            }

            SettingGroup(title: String(localized: "Skip commercials automatically", comment: "Setting: jump past commercial breaks in recordings without being asked"),
                         detail: String(localized: "Jumps past the breaks in a recording, where your server marks them: it needs something that finds commercials, such as a Comskip plugin. Off, you're offered Skip Commercials instead.", comment: "Under the setting for skipping commercials automatically")) {
                OnOffPills(value: autoSkipCommercials) { autoSkipCommercials = $0 }
            }

            SettingGroup(title: String(localized: "Skip recaps and previews automatically", comment: "Setting: jump past an episode's \"previously on\" and its look at the next episode without being asked"),
                         detail: String(localized: "Jumps past an episode's \"previously on\" recap, and its preview of the next episode, where your server marks them. Off, you're offered Skip Recap and Skip Preview instead.", comment: "Under the setting for skipping recaps and previews automatically")) {
                OnOffPills(value: autoSkipRecaps) { autoSkipRecaps = $0 }
            }

            SettingGroup(title: String(localized: "Remember audio and subtitles for each show", comment: "Setting: the tracks chosen in a show are used for its other episodes"),
                         detail: String(localized: "Change the audio or subtitles in an episode and the show's other episodes start that way too. Off, each starts with your account's settings.", comment: "Under the setting for remembering a show's audio and subtitles")) {
                OnOffPills(value: remembersTracks) { remembersTracks = $0 }
            }

            SettingGroup(title: String(localized: "Theme music", comment: "Setting: play a show's or film's theme song quietly on its page"),
                         detail: String(localized: "Plays a show's or film's theme song quietly on its page, where your server keeps one. Jellyfin's Theme Songs plugin finds them.", comment: "Under the theme music setting")) {
                OnOffPills(value: themeMusic) { on in
                    themeMusic = on
                    if !on { ThemeMusic.shared.stop() }
                }
            }

            if saveFailed { SaveFailedNote() }
        }
        .task { preferencesFailed = !(await app.loadPreferencesIfNeeded()) }
    }

    private func save(_ change: @escaping (inout UserPreferences) -> Void) {
        Task { saveFailed = !(await app.updatePreferences(change)) }
    }
}

// MARK: - Subtitles

struct SubtitleSettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var saveFailed = false
    @State private var preferencesFailed = false
    @AppStorage(SubtitleAppearance.sizeKey) private var size = SubtitleAppearance.Size.medium.rawValue
    @AppStorage(SubtitleAppearance.tintKey) private var tint = SubtitleAppearance.Tint.white.rawValue
    @AppStorage(SubtitleAppearance.backingKey) private var backing = SubtitleAppearance.Backing.none.rawValue
    @AppStorage(SubtitleAppearance.placeKey) private var place = SubtitleAppearance.Place.standard.rawValue

    var body: some View {
        SettingsPage(title: String(localized: "Subtitles"), accent: Theme.palette[1]) {
            // The foot of the screen as the player will draw it, kept in
            // sight over the four choices that change it.
            SubtitlePreview(size: SubtitleAppearance.Size(rawValue: size) ?? .medium,
                            tint: SubtitleAppearance.Tint(rawValue: tint) ?? .white,
                            backing: SubtitleAppearance.Backing(rawValue: backing) ?? .none,
                            place: SubtitleAppearance.Place(rawValue: place) ?? .standard)
        } content: {
            SettingGroup(title: String(localized: "Size", comment: "Subtitle text size setting"),
                         detail: {
                            #if os(tvOS)
                            String(localized: "Films that play straight from the file use your Apple TV's caption style instead, under Accessibility.")
                            #else
                            String(localized: "Films that play straight from the file use the system caption style instead, under Accessibility.")
                            #endif
                         }()) {
                ForEach(SubtitleAppearance.Size.allCases, id: \.self) { choice in
                    Button(choice.label) { size = choice.rawValue }
                        .buttonStyle(.pill(selected: size == choice.rawValue))
                }
            }

            SettingGroup(title: String(localized: "Colour", comment: "Subtitle colour setting"),
                         detail: String(localized: "Grey is easier on the eyes in a dark room.", comment: "Under the subtitle colour choices")) {
                ForEach(SubtitleAppearance.Tint.allCases, id: \.self) { choice in
                    Button(choice.label) { tint = choice.rawValue }
                        .buttonStyle(.pill(selected: tint == choice.rawValue))
                }
            }

            SettingGroup(title: String(localized: "Background", comment: "Subtitle background setting"),
                         detail: String(localized: "A dark plate behind the lines, for pictures they get lost in.", comment: "Under the subtitle background choices")) {
                ForEach(SubtitleAppearance.Backing.allCases, id: \.self) { choice in
                    Button(choice.label) { backing = choice.rawValue }
                        .buttonStyle(.pill(selected: backing == choice.rawValue))
                }
            }

            SettingGroup(title: String(localized: "Position", comment: "Subtitle position setting"),
                         detail: String(localized: "Lower sits in the black bar under a wide film. Higher clears a soundbar.", comment: "Under the subtitle position choices")) {
                ForEach(SubtitleAppearance.Place.allCases, id: \.self) { choice in
                    Button(choice.label) { place = choice.rawValue }
                        .buttonStyle(.pill(selected: place == choice.rawValue))
                }
            }

            if let preferences = app.preferences {
                SettingGroup(title: String(localized: "Show subtitles"), detail: preferences.subtitleMode.explanation) {
                    ForEach(UserPreferences.SubtitleMode.allCases, id: \.self) { mode in
                        Button(mode.label) { save { $0.subtitleMode = mode } }
                            .buttonStyle(.pill(selected: preferences.subtitleMode == mode))
                    }
                }

                SettingGroup(title: String(localized: "Language", comment: "Preferred subtitle language setting"),
                             detail: String(localized: "Which subtitle track to pick when there's a choice.")) {
                    ForEach(SubtitleLanguage.all, id: \.code) { language in
                        Button(language.name) { save { $0.subtitleLanguage = language.code } }
                            .buttonStyle(.pill(selected: preferences.subtitleLanguage == language.code))
                    }
                }

                Text("Saved to your \(app.serverFlavor.label) account, so your other \(app.serverFlavor.label) apps use them too. You can always change tracks during playback.",
                 comment: "Both placeholders are the server software's name, Jellyfin or Emby")
                    .font(.app(15))
                    .foregroundStyle(Theme.textSecondary)

                if saveFailed { SaveFailedNote() }
            } else if preferencesFailed {
                PreferencesRetry(failed: $preferencesFailed)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .focusable()   // somewhere for focus (and back) to land while loading
            }
        }
        .task { preferencesFailed = !(await app.loadPreferencesIfNeeded()) }
    }

    private func save(_ change: @escaping (inout UserPreferences) -> Void) {
        Task { saveFailed = !(await app.updatePreferences(change)) }
    }
}

// MARK: - About

struct AboutView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath
    @State private var server: PublicSystemInfo?

    var body: some View {
        SettingsPage(title: String(localized: "About", comment: "Page with app and server information"), accent: Theme.palette[3]) {
            HStack(spacing: 18) {
                Image(systemName: "play.fill")
                    .font(.app(26, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Theme.primary.0.opacity(0.5), radius: 14, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    GooseWordmark(size: 34)
                    Text(tagline)
                        .font(.app(16))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.bottom, 8)

            // One column on the left, like the Settings tiles: app, then server, then account.
            SettingsColumn(focusSection: false) {
                AboutRow(label: String(localized: "App version", comment: "Shown in capitals"), value: appVersion)
                AboutRow(label: UIDevice.current.systemName, value: UIDevice.current.systemVersion)
                AboutRow(label: String(localized: "Server", comment: "Server name; shown in capitals"), value: server?.serverName ?? app.serverName ?? "—")
                AboutRow(label: String(localized: "Server version", comment: "Shown in capitals"), value: server?.version.map { "\(app.serverFlavor.label) \($0)" } ?? "—")
                AboutRow(label: String(localized: "Address", comment: "Server URL; shown in capitals"), value: app.client?.baseURL.absoluteString ?? "—")
                AboutRow(label: String(localized: "Signed in as", comment: "Followed by the user name; shown in capitals"), value: app.userName ?? "—")
                Button { path.append(SettingsRoute.licenses) } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LICENCES", comment: "Heading shown in capitals")
                                .font(.app(12, .heavy)).kerning(1.4)
                                .foregroundStyle(Theme.palette[3].1)
                            Text(verbatim: LicensesView.Component.allCases.map(\.title).joined(separator: ", "))
                                .font(.app(20, .semibold))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.app(13, .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .buttonStyle(SettingsRowStyle())
            }
        }
        .task { server = try? await app.client?.publicInfo() }
    }

    private var tagline: String {
        #if os(tvOS)
        String(localized: "A Jellyfin client for Apple TV")
        #else
        String(localized: "A Jellyfin client for iPhone, iPad and Apple TV")
        #endif
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// An info tile. Focusable, so the page has somewhere for focus (and back) to land.
private struct AboutRow: View {
    let label: String
    let value: String

    var body: some View {
        Button {} label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.app(12, .heavy))
                    .kerning(1.4)
                    .foregroundStyle(Theme.palette[3].1)
                Text(value)
                    .font(.app(20, .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .buttonStyle(SettingsRowStyle())
    }
}

// MARK: - Shared pieces

/// A Settings sub-page: the shelf-style header over a column of groups.
struct SettingsPage<Pinned: View, Content: View>: View {
    @Environment(\.isNarrow) private var narrow
    @Environment(\.verticalSizeClass) private var height
    let title: String
    let accent: (Color, Color)
    /// Kept in sight under the title while the rest scrolls: a preview of
    /// what the choices below it change.
    let pinned: Pinned?
    @ViewBuilder let content: Content

    init(title: String, accent: (Color, Color), @ViewBuilder content: () -> Content) where Pinned == EmptyView {
        self.title = title
        self.accent = accent
        pinned = nil
        self.content = content()
    }

    init(title: String, accent: (Color, Color), @ViewBuilder pinned: () -> Pinned, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.pinned = pinned()
        self.content = content()
    }

    private var header: some View {
        ShelfHeader(title: title, eyebrow: String(localized: "Settings", comment: "Eyebrow heading above a settings page title, shown in capitals"), accent: accent)
    }

    var body: some View {
        // Pinned where there's the height for it. On a phone held sideways
        // the title and the preview together are the screen, and the choices
        // under them had no room left to be seen in: there it all scrolls.
        if let pinned, height != .compact {
            VStack(alignment: .leading, spacing: 24) {
                header
                pinned
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { content }
                        .padding(.bottom, 48)
                }
            }
            .padding(.horizontal, narrow ? 20 : 40)
            .padding(.top, 48)
            .pageSides()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let pinned { pinned }
                    content
                }
                // The Settings grid's own margins, so a phone's narrow screen
                // isn't given up to them.
                .padding(.horizontal, narrow ? 20 : 40)
                .padding(.vertical, 48)
            }
            .pageSides()
        }
    }
}

/// A column of tiles on the left, at the width a two-column grid gives them,
/// with the other half left empty. A phone uses the whole width.
struct SettingsColumn<Content: View>: View {
    @Environment(\.isNarrow) private var narrow
    let alignment: HorizontalAlignment
    /// Up and down into the column land on it, not on whichever tile lines up.
    let focusSection: Bool
    @ViewBuilder let content: Content
    /// The room there is, measured: an iPad held upright has too little for
    /// the tiles at half of it (the name on the profile's tile shrank to a dash).
    @State private var width: CGFloat = 0

    init(alignment: HorizontalAlignment = .center, focusSection: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.focusSection = focusSection
        self.content = content()
    }

    /// Whether the tiles take the whole width rather than half of it.
    private var fullWidth: Bool {
        #if !os(tvOS)
        narrow || (width > 0 && width < 900)
        #else
        narrow
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            let column = VStack(alignment: alignment, spacing: 24) { content }
                .frame(maxWidth: .infinity)
            if focusSection {
                column.tvFocusSection()
            } else {
                column
            }
            if !fullWidth { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
        }
        #if !os(tvOS)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #endif
    }
}

/// One setting: its name and what it does, over a row of choices.
private struct SettingGroup<Options: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(21, .semibold))
            Text(detail)
                .font(.app(15))
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) { options }
                    .padding(.vertical, 14)   // room for the focused pill's lift
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        // Up/down between groups lands on the group, not the pill that happens to line up.
        .tvFocusSection()
    }
}

private struct OnOffPills: View {
    let value: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button("On") { set(true) }.buttonStyle(.pill(selected: value))
        Button("Off") { set(false) }.buttonStyle(.pill(selected: !value))
    }
}

// MARK: - Tab Bar

/// The tabs along the foot of a phone's screen: which, up to four, and in
/// what order. Menu follows them always, with everything in it.
struct TabBarSettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let choices = app.tabChoices()
        let chosen = app.tabBar.compactMap { id in choices.first { $0.id == id } }
        let rest = choices.filter { !app.tabBar.contains($0.id) }
        let full = app.tabBar.count >= AppState.mostTabs
        SettingsPage(title: String(localized: "Tab Bar", comment: "Settings page: the tabs along the foot of a phone's screen"),
                     accent: Theme.palette[2]) {
            Text("The tabs along the foot of the screen: up to four, in the order you want them. Menu always comes last, with everything in it.",
                 comment: "Settings, Tab Bar: what the page is for")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)
            ForEach(Array(chosen.enumerated()), id: \.element.id) { place, choice in
                row(choice) {
                    Button { app.moveTab(choice.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.pill(selected: false))
                        .disabled(place == 0)
                        .opacity(place == 0 ? 0.35 : 1)
                        .accessibilityLabel(Text("Move Up", comment: "Settings, Home Screen: moves a row of Home earlier"))
                    Button { app.moveTab(choice.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.pill(selected: false))
                        .disabled(place == chosen.count - 1)
                        .opacity(place == chosen.count - 1 ? 0.35 : 1)
                        .accessibilityLabel(Text("Move Down", comment: "Settings, Home Screen: moves a row of Home later"))
                    OnOffPills(value: true) { app.setTab(choice.id, shown: $0) }
                }
            }
            if full {
                Text("Four is the most. Turn one off to add another.", comment: "Settings, Tab Bar: shown when four tabs are already on")
                    .font(.app(15))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(rest) { choice in
                row(choice) {
                    OnOffPills(value: false) { app.setTab(choice.id, shown: $0) }
                        .disabled(full)
                        .opacity(full ? 0.4 : 1)
                }
            }
        }
    }

    private func row(_ choice: AppState.TabChoice, @ViewBuilder controls: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let glyph = MenuGlyph(rawValue: choice.icon) {
                        MenuGlyphView(glyph: glyph, size: 22)
                    } else {
                        Image(systemName: choice.icon).font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 26)
                Text(choice.title).font(.app(19, .semibold)).lineLimit(1)
            }
            HStack(spacing: 14) { controls() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Home Screen

/// Which rows Home shows and the order they stand in: each with a switch and
/// a way up and down the list. The rows are the ones Home can have: a row
/// with nothing in it at the moment (nothing part-watched, say) is listed
/// here all the same, for when there is.
struct HomeLayoutSettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrow
    /// The arrow in focus, by its row and which way it points.
    @FocusState private var arrow: String?

    private struct Row: Identifiable {
        let id: String
        let name: String
        let detail: String?
    }

    /// Home's rows in the order Home has them (see `HomeLayout.usualOrder`).
    private var rows: [Row] {
        var all = [Row(id: HomeLayout.resume, name: String(localized: "Continue Watching"), detail: nil),
                   Row(id: HomeLayout.nextUp, name: String(localized: "Next Up"), detail: nil)]
        if app.hasLiveTV, app.showsLiveTV {
            all.append(Row(id: HomeLayout.onNow, name: String(localized: "On Now", comment: "Home row: what's on the television channels at this moment"),
                           detail: String(localized: "Live TV", comment: "Menu section: the server's television channels")))
        }
        let libraries = HomeLayout.shelfLibraries(app.libraries)
        for library in libraries {
            all.append(Row(id: HomeLayout.latest(library), name: library.displayTitle, detail: String(localized: "Recently added")))
        }
        all.append(Row(id: HomeLayout.upcoming, name: HomeLayout.upcomingTitle, detail: String(localized: "Your shows")))
        if app.libraries.contains(where: \.holdsBooks) {
            all.append(Row(id: HomeLayout.listening, name: HomeLayout.listeningTitle, detail: HomeLayout.listeningEyebrow))
        }
        if app.libraries.contains(where: \.holdsMusic) {
            all.append(Row(id: HomeLayout.musicRecent, name: HomeLayout.musicRecentTitle, detail: HomeLayout.musicEyebrow))
            all.append(Row(id: HomeLayout.musicTop, name: HomeLayout.musicTopTitle, detail: HomeLayout.musicEyebrow))
        }
        // The views pinned from a library's filters: a row each, listed
        // switched off too, to be switched on again here.
        for pin in app.pins {
            all.append(Row(id: HomeLayout.pinned(pin.id), name: pin.title,
                           detail: String(localized: "Pinned from \(pin.libraryName)", comment: "Settings, Home Screen: a row made from a library's saved filters; the placeholder is the library's name")))
        }
        let usual = HomeLayout.usualOrder(latest: libraries.map(HomeLayout.latest), pinned: app.pins.map { HomeLayout.pinned($0.id) })
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return HomeLayout.arranged(usual.filter { byId[$0] != nil }, by: app.homeOrder).compactMap { byId[$0] }
    }

    /// Every row there is to order, listed on this page or not: what's on
    /// now has its place whether or not Live TV is in the menu just now.
    private func everyRow(with listed: [String]) -> [String] {
        let usual = HomeLayout.usualOrder(latest: listed.filter { $0.hasPrefix("latest-") },
                                          pinned: listed.filter { $0.hasPrefix("pin-") })
        let known = usual + app.homeOrder.filter { !usual.contains($0) }
        return HomeLayout.arranged(known, by: app.homeOrder)
    }

    var body: some View {
        let rows = rows
        let ids = rows.map(\.id)
        SettingsPage(title: String(localized: "Home Screen", comment: "Settings page: which rows Home shows, and their order"),
                     accent: Theme.palette[0]) {
            Text("Which rows Home shows, and the order they come in.",
                 comment: "Settings, Home Screen: what the page is for")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)
            ForEach(Array(rows.enumerated()), id: \.element.id) { place, row in
                // A phone hasn't the width for the name beside its controls.
                let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                    : AnyLayout(HStackLayout(spacing: 14))
                layout {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.app(21, .semibold)).lineLimit(1)
                        if let detail = row.detail {
                            Text(detail).font(.app(15)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    .opacity(app.homeShows(row.id) ? 1 : 0.5)
                    if !narrow { Spacer(minLength: 8) }
                    HStack(spacing: 14) {
                        Button { move(row.id, by: -1, among: ids) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.pill(selected: false))
                            .disabled(place == 0)
                            .opacity(place == 0 ? 0.35 : 1)
                            .focused($arrow, equals: "up-" + row.id)
                            .accessibilityLabel(Text("Move Up", comment: "Settings, Home Screen: moves a row of Home earlier"))
                        Button { move(row.id, by: 1, among: ids) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.pill(selected: false))
                            .disabled(place == rows.count - 1)
                            .opacity(place == rows.count - 1 ? 0.35 : 1)
                            .focused($arrow, equals: "down-" + row.id)
                            .accessibilityLabel(Text("Move Down", comment: "Settings, Home Screen: moves a row of Home later"))
                        OnOffPills(value: app.homeShows(row.id)) { app.setHome(row.id, shown: $0) }
                    }
                    .padding(.vertical, narrow ? 8 : 14)   // room for the focused pill's lift
                }
                .padding(.horizontal, 24)
                .padding(.vertical, narrow ? 8 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                // Up/down between rows lands on the row, not the pill that happens to line up.
                .tvFocusSection()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-row-" + row.id)
            }
        }
        // The first row can't go up: come in on the arrow that does something.
        .defaultFocus($arrow, ids.first.map { "down-" + $0 })
        .task { await app.loadLibraries() }
    }

    /// Up or down one place among the rows as they stand, which becomes the
    /// order kept: until something is moved there's none, and the rows
    /// stand as Home has always had them. Focus goes with the row; where
    /// that was its last step that way, to the arrow back.
    private func move(_ id: String, by step: Int, among ids: [String]) {
        guard let at = ids.firstIndex(of: id), ids.indices.contains(at + step) else { return }
        // Changed places with its neighbour on this page, among all the rows
        // there are: one that isn't listed here now (what's on, with Live TV
        // out of the menu; another server's libraries) keeps the place it
        // had. Written from the page's rows alone, it went to the end.
        var order = everyRow(with: ids)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: ids[at + step]) else { return }
        order.swapAt(from, to)
        app.homeOrder = order
        #if os(tvOS)
        if at + step == 0 { arrow = "down-" + id }
        if at + step == ids.count - 1 { arrow = "up-" + id }
        #endif
    }
}

// MARK: - Live TV

/// Whether the menu has a Live TV row on this device. The server decides
/// whether there's any television to watch; this is for a household that has
/// it and a screen that doesn't want it (a child's, one that's only for films).
// MARK: - iCloud Sync

struct SyncSettingsView: View {
    @ObservedObject private var sync = SettingsSync.shared

    var body: some View {
        SettingsPage(title: SettingsSync.title, accent: Theme.palette[3]) {
            SettingGroup(title: String(localized: "Share settings through iCloud", comment: "Settings, iCloud Sync: the switch"),
                         detail: String(localized: "Your iPhone, iPad and Apple TV signed in to the same iCloud account keep the same settings: each show's audio and subtitles, Audio Sync, pinned views, the menu's and Home's rows and order, library filters, skipping and subtitle style.",
                                        comment: "Settings, iCloud Sync: what is shared")) {
                OnOffPills(value: sync.isOn) { sync.isOn = $0 }
            }
            if sync.isOn {
                SettingGroup(title: String(localized: "Share pinned views", comment: "Settings, iCloud Sync: whether pinned views are shared with the other devices too"),
                             detail: String(localized: "Off: this device keeps its own pinned views, and those pinned on other devices don't come here.",
                                            comment: "Settings, iCloud Sync: what turning off the sharing of pinned views does")) {
                    OnOffPills(value: sync.sharesPins) { sync.sharesPins = $0 }
                }
            }
            Text("Each device keeps its own colour scheme, quality, players, downloads, Live TV switches, Dialogue Boost, and who's signed in.",
                 comment: "Settings, iCloud Sync: what is not shared")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

struct LiveTVSettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SettingsPage(title: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                     accent: Theme.palette[2]) {
            Text("Television from your server's tuner: \(LiveTVView.count(app.liveChannelCount)).",
                 comment: "Settings, Live TV. The placeholder is a count, like 42 channels")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)
            SettingGroup(title: String(localized: "Live TV in the menu"),
                         detail: {
                            #if os(tvOS)
                            String(localized: "Off, this Apple TV's menu has no Live TV. Nothing changes on the server or on other devices.")
                            #else
                            String(localized: "Off, the menu here has no Live TV. Nothing changes on the server or on other devices.")
                            #endif
                         }()) {
                OnOffPills(value: app.showsLiveTV) { app.showsLiveTV = $0 }
            }
            SettingGroup(title: String(localized: "On Now on Home", comment: "Settings, Live TV: the switch for Home's row of what's on the channels now"),
                         detail: String(localized: "A row on Home of what's on your channels now. Off, Home has no such row; Live TV stays in the menu.",
                                        comment: "Settings, Live TV: what the On Now switch does")) {
                OnOffPills(value: app.showsOnNow) { app.showsOnNow = $0 }
            }
            // The row is of Live TV: with that off here, there's none to
            // switch.
            .disabled(!app.showsLiveTV)
            .opacity(app.showsLiveTV ? 1 : 0.4)
            SettingGroup(title: String(localized: "Pause and Rewind", comment: "Settings, Live TV: the switch for keeping the channel being watched on the device, so it can be paused and gone back through"),
                         detail: String(localized: "Keeps the channel you're watching on this device as it comes, up to half an hour of it, so that it can be paused and gone back through. Off, nothing is kept.",
                                        comment: "Settings, Live TV: what the Pause and Rewind switch does")) {
                OnOffPills(value: app.keepsLiveTV) { app.keepsLiveTV = $0 }
            }
            .disabled(!app.showsLiveTV)
            .opacity(app.showsLiveTV ? 1 : 0.4)
        }
    }
}

extension AppState {
    /// The account's preferences, fetched unless they're here already (the
    /// Settings grid and the player fetch them too). False if they still aren't.
    func loadPreferencesIfNeeded() async -> Bool {
        if preferences == nil { await loadPreferences() }
        return preferences != nil
    }
}

/// In place of preferences that couldn't be fetched: a spinner there never
/// stopped.
private struct PreferencesRetry: View {
    @EnvironmentObject var app: AppState
    @Binding var failed: Bool
    @State private var trying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsNote(String(localized: "Couldn't load this from the server.",
                                comment: "Shown where a page or a setting couldn't be fetched, above a Try Again button"),
                         tint: Theme.palette[1].0)
            Button(String(localized: "Try Again")) {
                guard !trying else { return }
                trying = true
                Task {
                    failed = !(await app.loadPreferencesIfNeeded())
                    trying = false
                }
            }
            .buttonStyle(.pill(selected: false))
        }
    }
}

private struct SaveFailedNote: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SettingsNote(String(localized: "Couldn't save to your \(app.serverFlavor.label) account. Your server may not allow this account to change its settings.",
                                    comment: "The placeholder is the server software's name, Jellyfin or Emby"), tint: Theme.palette[1].0)
    }
}

// MARK: - Appearance

/// Picks the app's colour scheme and its icon on the Home screen.
struct AppearanceSettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrow

    private var iconHint: String {
        #if os(tvOS)
        String(localized: "The icon on the Apple TV Home screen. It changes as soon as you pick one.")
        #elseif os(macOS)
        String(localized: "The icon in the Dock while JellyGoose is open. It changes as soon as you pick one; Finder and Launchpad keep the usual one.",
               comment: "Settings, Appearance, on a Mac: what the app icon choice changes")
        #else
        String(localized: "The icon on your Home Screen. It changes as soon as you pick one.")
        #endif
    }
    @State private var icon: AppIcon = .movieNight
    @State private var iconProblem: String?

    var body: some View {
        SettingsPage(title: String(localized: "Appearance"), accent: Theme.palette[3]) {
            Text("Changes the colours everywhere: the menu, buttons, shelf headings and the wallpaper.")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)

            // Colour schemes on the left, the app icon beside them: two
            // choices about how the app looks, side by side.
            let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 32))
                                : AnyLayout(HStackLayout(alignment: .top, spacing: 48))
            layout {
                // Close together: six of them stand as tall as the icons
                // beside them, and leave the rest of the page on the screen.
                VStack(spacing: 14) {
                    ForEach(AppTheme.allCases) { theme in
                        Button { app.theme = theme } label: {
                            ThemeRowLabel(theme: theme, selected: app.theme == theme)
                        }
                        .buttonStyle(SettingsRowStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .tvFocusSection()

                VStack(alignment: .leading, spacing: 10) {
                    Text("APP ICON", comment: "Heading shown in capitals")
                        .font(.app(12, .heavy))
                        .kerning(1.4)
                        .foregroundStyle(Theme.palette[3].1)
                    Text(iconHint)
                        .font(.app(17))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: AppIconTile.width, maximum: AppIconTile.width),
                                                 spacing: 20, alignment: .leading)],
                              alignment: .leading, spacing: 20) {
                        ForEach(AppIcon.allCases) { option in
                            AppIconTile(icon: option, selected: icon == option) {
                                // Mark it chosen straight away: tvOS takes a moment to
                                // swap the icon, and a tick that waits for it reads as a
                                // press that did nothing.
                                icon = option
                                iconProblem = nil
                                Task {
                                    let problem = await AppIcon.use(option)
                                    // What the system shows is the answer: iOS can
                                    // report a failure for a change it went on to
                                    // make (its notice interrupts the request).
                                    let now = AppIcon.current
                                    icon = now
                                    iconProblem = now == option ? nil : problem
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
            }

            if let iconProblem {
                SettingsNote(iconProblem, tint: Theme.palette[1].0)
            }

            #if os(tvOS)
            SettingGroup(title: String(localized: "On the Apple TV Home screen"),
                         detail: String(localized: "Shows Continue Watching and Next Up above JellyGoose when it sits in the top row. The Home screen keeps what it last read for a while, so a change can take a few minutes to show.")) {
                OnOffPills(value: app.showsOnHomeScreen) { app.showsOnHomeScreen = $0 }
            }
            #endif
        }
        .onAppear { icon = AppIcon.current }
    }
}

/// Artwork above, name and description below. Only the artwork is the button:
/// a card lifts and scales what it holds, and with the text inside, focusing a
/// tile dragged its own words out of line and printed them over its neighbours'.
private struct AppIconTile: View {
    let icon: AppIcon
    let selected: Bool
    let choose: () -> Void

    /// Three to a row beside the colour schemes.
    static let width = CGFloat(220).scaled
    private var width: CGFloat { Self.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: choose) {
                Image(icon.preview)
                    .resizable()
                    .aspectRatio(400.0 / 240.0, contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(selected ? Theme.accent : .white.opacity(0.12),
                                          lineWidth: selected ? 3 : 1)
                    }
            }
            .buttonStyle(.tvCard)
            // The button is artwork alone, so it needs a name of its own.
            .accessibilityLabel(icon.label)
            .accessibilityHint(icon.blurb)
            .accessibilityAddTraits(selected ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(icon.label)
                        .font(.app(19, .semibold))
                        .lineLimit(1)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.app(16, .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                // A fixed height for two lines, so every description in the row
                // starts on the same line whether it needs one line or two.
                Text(icon.blurb)
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: CGFloat(38).scaled, alignment: .topLeading)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct ThemeRowLabel: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        HStack(spacing: 18) {
            // The scheme's own four gradients, as a swatch.
            VStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<2, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.gradient(theme.colors.palette[row * 2 + column],
                                                     start: .topLeading, end: .bottomTrailing))
                        }
                    }
                }
            }
            .frame(width: CGFloat(46).scaled, height: CGFloat(46).scaled)
            .background(theme.colors.background, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(theme.label).font(.app(20, .semibold))
                Text(theme.blurb)
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .font(.app(15, .semibold))
                    .foregroundStyle(theme.colors.accent)
            }
        }
        .padding(.horizontal, CGFloat(22).scaled)
        .padding(.vertical, CGFloat(13).scaled)
    }
}
